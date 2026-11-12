//
//  PhoneLink.swift
//  boringNotch
//
//  Runs the bundled Smart Connect daemon and talks to it over its local control socket.
//  The daemon opens a network port, so it only runs on networks the user marked as trusted.
//

import AppKit
import Defaults
import Network
import SystemConfiguration

struct PhoneNotification: Codable, Identifiable, Hashable {
    let key: String
    let app: String
    let pkg: String
    let title: String
    let body: String
    let replyable: Bool

    var id: String { key }
}

struct PhoneStatus: Codable, Equatable {
    var connected = false
    var paired = false
    var name: String?
    var model: String?
    var battery: Int?
    var charging = false
    var wifiSignal: Int?
    var cellSignal: Int?
    var unread: Int?
    var pairingQr: String?
    /// This Mac's address on the phone's network; the phone's video stream is sent there.
    var pcAddress: String?
    var notifications: [PhoneNotification] = []
}

extension Defaults.Keys {
    /// Network id → label shown in settings. Only on these networks does the phone service run.
    static let islandTrustedNetworks = Key<[String: String]>("islandTrustedNetworks", default: [:])
    static let islandPhoneClipboardSend = Key<Bool>("islandPhoneClipboardSend", default: true)
    static let islandPhoneClipboardReceive = Key<Bool>("islandPhoneClipboardReceive", default: true)
}

/// Identifies the current network by its router, which needs no location permission.
enum NetworkIdentity {
    struct Current: Equatable {
        let id: String
        let label: String
    }

    static func current() -> Current? {
        guard let store = SCDynamicStoreCreate(nil, "island.network" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let service = global["PrimaryService"] as? String,
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any]
        else { return nil }

        let router = (ipv4["Router"] as? String) ?? (global["Router"] as? String) ?? "?"
        // The signature includes the router's hardware address, so two networks that both use
        // 192.168.1.1 are still told apart.
        guard let signature = ipv4["NetworkSignature"] as? String, signature.contains("RouterHardwareAddress") else { return nil }
        let interface = (ipv4["InterfaceName"] as? String) ?? ""
        return Current(id: signature, label: "Router \(router)" + (interface.isEmpty ? "" : " (\(interface))"))
    }
}

/// Blocking helpers for a Unix stream socket carrying one JSON document per line.
enum LineSocket {
    static func open(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func write(_ line: String, to fd: Int32) -> Bool {
        let data = Array((line + "\n").utf8)
        return data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) } == data.count
    }

    /// Calls `onLine` for every complete line until the other side closes or `onLine` returns false.
    static func readLines(from fd: Int32, onLine: (Data) -> Bool) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                if !line.isEmpty, !onLine(line) { return }
            }
        }
    }
}

@MainActor
final class PhoneLink: ObservableObject {
    static let shared = PhoneLink()

    @Published private(set) var status = PhoneStatus()
    @Published private(set) var daemonRunning = false
    @Published private(set) var network: NetworkIdentity.Current?
    @Published private(set) var networkTrusted = false
    @Published var message: String?

    private var process: Process?
    private var subscriber: Thread?
    private var subscriberGeneration = 0
    private let monitor = NWPathMonitor()
    private var started = false
    /// Serial, so messages reach the phone in the order they were sent (pointer moves, then clicks).
    private let sendQueue = DispatchQueue(label: "island.phone.send")

    /// Short on purpose: Unix socket paths are limited to 104 bytes, and the sandbox container is long.
    private let socketDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("sc", isDirectory: true)
    var controlSocketPath: String { controlSocket }
    private var controlSocket: String { socketDirectory.appendingPathComponent("control.sock").path }

    private var stateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartConnect", isDirectory: true)
    }

    private var daemonURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/smartconnectd")
    }

    var daemonAvailable: Bool { FileManager.default.isExecutableFile(atPath: daemonURL.path) }

    // MARK: - Lifecycle

    /// Call once at launch. Starts or stops the service as networks and settings change.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] _ in
            // The system network state settles a moment after the path changes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { @MainActor in self?.evaluate() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "island.phone.network"))
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopDaemon() }
        }
        evaluate()
    }

    /// Decides whether the service may run right now.
    func evaluate() {
        network = NetworkIdentity.current()
        networkTrusted = network.map { Defaults[.islandTrustedNetworks][$0.id] != nil } ?? false
        let wanted = networkTrusted && NotchViews.phone.isVisible && daemonAvailable
        if wanted, !daemonRunning {
            startDaemon()
        } else if !wanted, daemonRunning {
            stopDaemon()
        }
    }

    /// Settings the service reads only at start take effect after a restart; the phone reconnects by itself.
    func restartService() {
        guard daemonRunning else { return }
        stopDaemon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task { @MainActor in self?.evaluate() }
        }
    }

    func trustCurrentNetwork() {
        guard let network else { return }
        Defaults[.islandTrustedNetworks][network.id] = network.label
        evaluate()
    }

    func forget(networkID: String) {
        Defaults[.islandTrustedNetworks][networkID] = nil
        evaluate()
    }

    // MARK: - Daemon

    private func startDaemon() {
        try? FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = daemonURL
        process.arguments = [
            "--state-dir", stateDirectory.path,
            // Off: the legacy Bluetooth pairing service. On (by default): the Bluetooth wake, which
            // lets the Mac reconnect while Smart Connect sleeps in the background on the phone.
            "--no-ble",
            "--token-ttl", "600",
            "--name", Host.current().localizedName ?? "Mac",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SMARTCONNECT_SOCKET_DIR"] = socketDirectory.path
        // The daemon exits by itself when this app is gone, even after a crash.
        environment["SMARTCONNECT_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        // More detail about notifications, so the diagnosis shows what arrived and what was dropped.
        environment["RUST_LOG"] = "info,smartconnect::notifications_macos=debug"
        environment["SMARTCONNECT_CLIPBOARD_SEND"] = Defaults[.islandPhoneClipboardSend] ? "1" : "0"
        environment["SMARTCONNECT_CLIPBOARD_RECEIVE"] = Defaults[.islandPhoneClipboardReceive] ? "1" : "0"
        process.environment = environment
        let log = stateDirectory.appendingPathComponent("daemon.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.process = nil
                self.daemonRunning = false
                self.status = PhoneStatus()
            }
        }
        do {
            try process.run()
            self.process = process
            daemonRunning = true
            message = nil
            startSubscriber()
            PhoneNotifier.shared.start(socketPath: socketDirectory.appendingPathComponent("notifications.sock").path)
        } catch {
            message = "Der Handy-Dienst ließ sich nicht starten: \(error.localizedDescription)"
        }
    }

    private func stopDaemon() {
        subscriberGeneration += 1
        PhoneNotifier.shared.stop()
        PhoneStreams.shared.closeAll()
        process?.terminate()
        process = nil
        daemonRunning = false
        status = PhoneStatus()
    }

    // MARK: - Control socket

    /// Keeps one connection open on which the daemon pushes every status change.
    private func startSubscriber() {
        subscriberGeneration += 1
        let generation = subscriberGeneration
        let path = controlSocket
        let thread = Thread { [weak self] in
            let decoder = JSONDecoder()
            while true {
                let current = DispatchQueue.main.sync { MainActor.assumeIsolated { self?.subscriberGeneration } }
                guard current == generation else { return }
                if let fd = LineSocket.open(path) {
                    if LineSocket.write("subscribe", to: fd) {
                        LineSocket.readLines(from: fd) { line in
                            guard let status = try? decoder.decode(PhoneStatus.self, from: line) else { return true }
                            return DispatchQueue.main.sync {
                                MainActor.assumeIsolated {
                                    guard let self, self.subscriberGeneration == generation else { return false }
                                    if self.status != status { self.status = status }
                                    return true
                                }
                            }
                        }
                    }
                    close(fd)
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
        thread.name = "island.phone.subscribe"
        thread.start()
        subscriber = thread
    }

    /// Sends one command and returns the daemon's one-line JSON answer.
    private func request(_ line: String, timeout: TimeInterval = 15) async -> [String: Any]? {
        let path = controlSocket
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let fd = LineSocket.open(path) else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { close(fd) }
                var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                var answer: [String: Any]?
                if LineSocket.write(line, to: fd) {
                    LineSocket.readLines(from: fd) { data in
                        answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        return false
                    }
                }
                continuation.resume(returning: answer)
            }
        }
    }

    private func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Forwards one message to the phone on the given protocol service, without waiting for an answer.
    func send(service: Int, data: [String: Any]) {
        let line = json(["cmd": "send", "service": service, "data": data])
        let path = controlSocket
        sendQueue.async {
            guard let fd = LineSocket.open(path) else { return }
            defer { close(fd) }
            _ = LineSocket.write(line, to: fd)
            // Wait for the daemon's one-line reply, so the message is accepted before closing.
            LineSocket.readLines(from: fd) { _ in false }
        }
    }

    // MARK: - Diagnosis

    /// The tail of the service log, stripped of anything secret, for pasting into a bug report.
    func copyDiagnosis() {
        let log = stateDirectory.appendingPathComponent("daemon.log")
        var lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        lines = lines
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
            // QR block characters and the constant file-exchange polling carry no information.
            .filter { !$0.contains("█") && !$0.contains("▀") && !$0.contains("▄") && !$0.contains("svc 168") }
            // Keys, tokens and fingerprints are long runs of base64 characters.
            .map { $0.replacingOccurrences(of: "[A-Za-z0-9+/=_-]{32,}", with: "<verborgen>", options: .regularExpression) }
        let header = "daemon=\(daemonRunning) trusted=\(networkTrusted) connected=\(status.connected) paired=\(status.paired) notifications=\(status.notifications.count) unread=\(status.unread ?? -1)"
        let text = ([header] + lines.suffix(120)).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Diagnose kopiert. Füge sie in den Chat ein."
    }

    // MARK: - Actions

    /// Creates a fresh pairing code and returns the path of its image.
    func newPairingCode() async -> URL? {
        guard let answer = await request("pair"), answer["ok"] as? Bool == true, let path = answer["qr"] as? String else {
            message = "Es konnte kein Kopplungs-Code erzeugt werden."
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    func connect() async {
        message = "Verbinde …"
        let answer = await request("connect", timeout: 75)
        message = answer?["ok"] as? Bool == true ? nil : (answer?["message"] as? String ?? "Das Handy antwortet nicht. Öffne Smart Connect auf dem Handy.")
    }

    func disconnect() async {
        _ = await request("disconnect")
    }

    func reply(to notification: PhoneNotification, text: String) async -> Bool {
        await reply(key: notification.key, text: text)
    }

    func reply(key: String, text: String) async -> Bool {
        let answer = await request(json(["cmd": "reply", "key": key, "text": text]))
        let ok = answer?["ok"] as? Bool == true
        if !ok { message = answer?["message"] as? String ?? "Antwort konnte nicht gesendet werden." }
        return ok
    }
}
