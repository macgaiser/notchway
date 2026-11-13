//
//  GoogleAuth.swift
//  boringNotch
//
//  Sign-in with the user's own Google OAuth client (desktop type, PKCE, loopback redirect).
//  Only the Google Tasks scope is requested.
//

import AppKit
import CryptoKit
import Defaults
import Foundation
import Network
import Security

extension Defaults.Keys {
    static let islandGoogleClientID = Key<String>("islandGoogleClientID", default: "")
}

/// Secrets live in the login keychain, not in the preferences file.
enum IslandKeychain {
    private static let service = "island.google"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String?, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

enum GoogleAuthError: LocalizedError {
    case notConfigured
    case notConnected
    case cancelled
    case denied(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "Client-ID und Client-Schlüssel fehlen.")
        case .notConnected: String(localized: "Kein Google-Konto verbunden.")
        case .cancelled: String(localized: "Die Anmeldung wurde nicht abgeschlossen.")
        case .denied(let reason): String(localized: "Google hat die Anmeldung abgelehnt: \(reason)")
        case .server(let reason): String(localized: "Fehler bei Google: \(reason)")
        }
    }
}

@MainActor
final class GoogleAuth: ObservableObject {
    static let shared = GoogleAuth()

    @Published private(set) var isConnected: Bool
    @Published private(set) var isWorking = false
    @Published var message: String?

    private static let scope = "https://www.googleapis.com/auth/tasks"
    private var accessToken: String?
    private var activeReceiver: LoopbackReceiver?
    private var accessTokenExpiry = Date.distantPast

    private init() {
        isConnected = IslandKeychain.read("refreshToken") != nil
    }

    var hasClientSecret: Bool { IslandKeychain.read("clientSecret") != nil }

    // MARK: - Connect / disconnect

    func connect(clientSecret: String) async {
        let clientID = Defaults[.islandGoogleClientID].trimmingCharacters(in: .whitespacesAndNewlines)
        let typedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedSecret.isEmpty { IslandKeychain.write(typedSecret, for: "clientSecret") }
        guard !clientID.isEmpty, let secret = IslandKeychain.read("clientSecret") else {
            message = GoogleAuthError.notConfigured.errorDescription
            return
        }

        isWorking = true
        message = String(localized: "Warte auf die Anmeldung im Browser …")
        defer { isWorking = false }

        do {
            let verifier = Self.randomString()
            let state = Self.randomString()
            let receiver = LoopbackReceiver()
            activeReceiver = receiver
            defer { activeReceiver = nil }
            let port = try await receiver.start()
            let redirect = "http://127.0.0.1:\(port)"

            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                .init(name: "client_id", value: clientID),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: Self.scope),
                .init(name: "code_challenge", value: Self.challenge(for: verifier)),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
            ]
            NSWorkspace.shared.open(components.url!)

            let answer = try await receiver.waitForRedirect()
            guard answer["state"] == state else { throw GoogleAuthError.cancelled }
            if let error = answer["error"] { throw GoogleAuthError.denied(error) }
            guard let code = answer["code"] else { throw GoogleAuthError.cancelled }

            let token = try await requestToken([
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirect,
                "client_id": clientID,
                "client_secret": secret,
            ])
            guard let refresh = token.refresh_token else {
                throw GoogleAuthError.server(String(localized: "Google hat keinen dauerhaften Zugang ausgestellt."))
            }
            guard IslandKeychain.write(refresh, for: "refreshToken") else {
                throw GoogleAuthError.server(String(localized: "Der Zugang konnte nicht im Schlüsselbund gespeichert werden."))
            }
            store(token)
            isConnected = true
            message = String(localized: "Verbunden.")
        } catch {
            message = error.localizedDescription
        }
    }

    /// Stops a sign-in that is still waiting for the browser.
    func cancelConnect() {
        activeReceiver?.cancel()
    }

    func disconnect() {
        IslandKeychain.write(nil, for: "refreshToken")
        accessToken = nil
        accessTokenExpiry = .distantPast
        isConnected = false
        message = String(localized: "Verbindung getrennt. Den Zugriff kannst du zusätzlich in deinem Google-Konto unter „Sicherheit“ widerrufen.")
    }

    // MARK: - Tokens

    func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = IslandKeychain.read("refreshToken") else {
            isConnected = false
            throw GoogleAuthError.notConnected
        }
        guard let secret = IslandKeychain.read("clientSecret") else { throw GoogleAuthError.notConfigured }
        do {
            let token = try await requestToken([
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": Defaults[.islandGoogleClientID],
                "client_secret": secret,
            ])
            store(token)
            return token.access_token
        } catch GoogleAuthError.denied(let reason) {
            // The grant was revoked or expired: a new sign-in is needed.
            IslandKeychain.write(nil, for: "refreshToken")
            isConnected = false
            throw GoogleAuthError.denied(reason)
        }
    }

    private func store(_ token: TokenResponse) {
        accessToken = token.access_token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3000))
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
    }

    private struct TokenFailure: Decodable {
        let error: String
        let error_description: String?
    }

    private func requestToken(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 200 {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        }
        if let failure = try? JSONDecoder().decode(TokenFailure.self, from: data) {
            throw GoogleAuthError.denied(failure.error_description ?? failure.error)
        }
        throw GoogleAuthError.server(String(localized: "Antwort \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
    }

    // MARK: - PKCE helpers

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Listens once on 127.0.0.1 for the browser coming back from Google.
final class LoopbackReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "island.google.loopback")
    private var redirect: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: GoogleAuthError.cancelled)
                    }
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Gives up after five minutes, so an abandoned sign-in does not hang forever.
    func waitForRedirect() async throws -> [String: String] {
        queue.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.finish(.failure(GoogleAuthError.cancelled))
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pending {
                    continuation.resume(with: pending)
                } else {
                    self.redirect = continuation
                }
            }
        }
    }

    func cancel() {
        finish(.failure(GoogleAuthError.cancelled))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
            let answer = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })

            // Browsers also ask for /favicon.ico; only the real redirect carries these.
            let isRedirect = answer["code"] != nil || answer["error"] != nil
            let text = answer["code"] != nil
                ? String(localized: "Anmeldung abgeschlossen. Du kannst dieses Fenster schließen.")
                : String(localized: "Die Anmeldung wurde nicht abgeschlossen.")
            let body = "<!doctype html><meta charset=\"utf-8\"><title>Island</title><body style=\"font:16px -apple-system;padding:3em;text-align:center\">\(text)</body>"
            let response = "HTTP/1.1 \(isRedirect ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if isRedirect { self?.finish(.success(answer)) }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        queue.async {
            guard self.pending == nil else { return }
            self.pending = result
            self.listener?.cancel()
            self.listener = nil
            self.redirect?.resume(with: result)
            self.redirect = nil
        }
    }
}
