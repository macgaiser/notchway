//
//  QuickLaunch.swift
//  boringNotch
//
//  Pinned apps, websites, files and folders that open with one click.
//

import AppKit
import Defaults
import SwiftUI

struct QuickLaunchItem: Codable, Identifiable, Hashable, Defaults.Serializable {
    var id = UUID()
    var name: String
    /// Web address, or a file path for apps, files and folders.
    var target: String
    /// Security-scoped bookmark, needed to reopen files outside the app's sandbox.
    var bookmark: Data?
    /// Path of the browser that opens a web address; nil uses the default browser.
    var browser: String?

    var isWeb: Bool { !target.hasPrefix("/") }

    static let youtubeMusic: QuickLaunchItem = {
        var item = QuickLaunchItem(name: "YouTube Music", target: "https://music.youtube.com")
        // Fixed id, so the default entry stays the same entry across launches.
        item.id = UUID(uuidString: "0A51A0D0-0000-4000-8000-000000000001")!
        return item
    }()

    init(name: String, target: String, bookmark: Data? = nil) {
        self.name = name
        self.target = target
        self.bookmark = bookmark
    }

    init(fileURL: URL) {
        name = FileManager.default.displayName(atPath: fileURL.path).replacingOccurrences(of: ".app", with: "")
        target = fileURL.path
        bookmark = try? fileURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Returns false when the target could not be opened.
    @MainActor @discardableResult
    func open() -> Bool {
        if isWeb {
            guard let url = URL(string: target) else { return false }
            if let browser, FileManager.default.fileExists(atPath: browser) {
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: browser), configuration: NSWorkspace.OpenConfiguration())
                return true
            }
            return NSWorkspace.shared.open(url)
        }

        var stale = false
        if let bookmark,
           let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return NSWorkspace.shared.open(url)
        }
        return NSWorkspace.shared.open(URL(fileURLWithPath: target))
    }
}

extension Defaults.Keys {
    static let islandQuickLaunch = Key<[QuickLaunchItem]>("islandQuickLaunch", default: [.youtubeMusic])
}

struct QuickLaunchIcon: View {
    let item: QuickLaunchItem

    var body: some View {
        if item.isWeb {
            SiteIconView(address: item.target)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.target))
                .resizable()
                .scaledToFit()
        }
    }
}

struct QuickLaunchView: View {
    @EnvironmentObject var vm: BoringViewModel
    @Default(.islandQuickLaunch) private var items
    @State private var failedID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(items) { item in
                    tile(for: item)
                }
                addTile
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func tile(for item: QuickLaunchItem) -> some View {
        Button {
            if item.open() {
                vm.close()
            } else {
                failedID = item.id
            }
        } label: {
            VStack(spacing: 6) {
                QuickLaunchIcon(item: item)
                    .frame(width: 46, height: 46)
                Text(failedID == item.id ? "Nicht gefunden" : item.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(failedID == item.id ? .red : .white)
            }
            .frame(width: 78, height: 96)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(IslandTileStyle())
        .help(item.target)
    }

    private var addTile: some View {
        Button {
            SettingsWindowController.shared.showWindow()
            vm.close()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 46, height: 46)
                Text("Bearbeiten")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 78, height: 96)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(IslandTileStyle())
        .help("Einträge in den Einstellungen unter „Ansichten“ verwalten")
    }
}

/// Shared press and hover feedback for tiles inside the island.
struct IslandTileStyle: ButtonStyle {
    /// Radius of the highlight; 0 where the tile is one segment of a larger shape.
    var cornerRadius: CGFloat = 12
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(IslandMotion.interactive, value: configuration.isPressed)
            .animation(IslandMotion.interactive, value: hovering)
            .onHover { hovering = $0 }
    }
}
