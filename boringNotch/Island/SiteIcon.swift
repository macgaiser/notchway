//
//  SiteIcon.swift
//  boringNotch
//
//  Finds the largest icon a website offers and keeps it on disk.
//

import AppKit
import SwiftUI

@MainActor
final class SiteIconLoader: ObservableObject {
    @Published var image: NSImage?

    private static var memory: [String: NSImage] = [:]
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func load(_ address: String) async {
        guard let pageURL = URL(string: address), let hostName = pageURL.host, let scheme = pageURL.scheme else { return }
        // Scheme and port belong to the site: a NAS service on :9091 is not the one on :80.
        let origin = scheme + "://" + hostName + (pageURL.port.map { ":\($0)" } ?? "")
        let host = hostName + (pageURL.port.map { "_\($0)" } ?? "")
        if let cached = Self.memory[host] {
            image = cached
            return
        }
        let file = Self.cacheFile(for: host)
        if let data = try? Data(contentsOf: file), let cached = NSImage(data: data) {
            Self.memory[host] = cached
            image = cached
            return
        }

        var candidates = await Self.iconLinks(on: pageURL)
        candidates.append(URL(string: "\(origin)/apple-touch-icon.png"))
        candidates.append(URL(string: "\(origin)/favicon.ico"))

        for case let url? in candidates {
            guard let data = await Self.fetch(url), let found = NSImage(data: data), found.size.width > 0 else { continue }
            try? data.write(to: file, options: .atomic)
            Self.memory[host] = found
            image = found
            return
        }
    }

    /// Fetches icons ahead of time, so they are there when the island opens.
    static func preload(_ addresses: [String]) {
        for address in addresses {
            Task { await SiteIconLoader().load(address) }
        }
    }

    private static func cacheFile(for host: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("IslandSiteIcons-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(host)
    }

    /// No cookies: with them, some sites answer with a consent page instead of their own.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private static func fetch(_ url: URL, requireSameHost: Bool = false) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        if requireSameHost, http.url?.host != url.host { return nil }
        return data
    }

    /// Icon links declared in the page, largest first.
    private static func iconLinks(on pageURL: URL) async -> [URL?] {
        guard let data = await fetch(pageURL, requireSameHost: true) else { return [] }
        let html = String(decoding: data.prefix(400_000), as: UTF8.self)

        var found: [(size: Int, url: URL)] = []
        for tag in html.matches(of: /<link\b[^>]*>/.ignoresCase()) {
            let text = String(tag.output)
            guard let rel = attribute("rel", in: text)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: text),
                  let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  !url.pathExtension.lowercased().hasPrefix("svg") else { continue }
            let declared = attribute("sizes", in: text).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") }
            found.append((declared ?? (rel.contains("apple-touch") ? 180 : 16), url))
        }
        return found.sorted { $0.size > $1.size }.map(\.url)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? Regex("\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase(),
              let match = tag.firstMatch(of: regex), match.output.count > 1,
              let value = match.output[1].substring else { return nil }
        return String(value).replacingOccurrences(of: "&amp;", with: "&")
    }
}

struct SiteIconView: View {
    let address: String
    @StateObject private var loader = SiteIconLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .task(id: address) { await loader.load(address) }
    }
}
