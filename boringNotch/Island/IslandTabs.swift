//
//  IslandTabs.swift
//  boringNotch
//
//  Titles, icons and visibility of the views inside the open island.
//

import Defaults
import Foundation

extension NotchViews {
    var title: String {
        switch self {
        case .home: "Player & Kalender"
        case .shelf: "Ablage"
        case .quickLaunch: "Schnellstart"
        case .clipboard: "Zwischenablage"
        case .notes: "Notizen"
        case .pomodoro: "Pomodoro"
        case .tasks: "Aufgaben"
        case .capture: "Aufnahme"
        case .phone: "Handy"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .shelf: "tray.fill"
        case .quickLaunch: "square.grid.2x2.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .notes: "note.text"
        case .pomodoro: "timer"
        case .tasks: "checklist"
        case .capture: "camera.viewfinder"
        case .phone: "smartphone"
        }
    }

    /// Views with their own vertical scrolling: there, a swipe up must scroll, not close the island.
    var scrollsVertically: Bool { self == .tasks || self == .notes || self == .phone }

    /// Home is always available; the shelf keeps its own upstream switch.
    var canBeHidden: Bool { self != .home && self != .shelf }

    func isVisible(hidden: [String], shelfEnabled: Bool) -> Bool {
        switch self {
        case .home: true
        case .shelf: shelfEnabled
        default: !hidden.contains(rawValue)
        }
    }

    var isVisible: Bool {
        isVisible(hidden: Defaults[.islandHiddenTabs], shelfEnabled: Defaults[.boringShelf])
    }
}

extension Defaults.Keys {
    static let islandHiddenTabs = Key<[String]>("islandHiddenTabs", default: [])
}

/// The notch panel normally refuses keyboard focus. Views that need typing switch this on while visible.
enum IslandFocus {
    nonisolated(unsafe) static var allowsKey = false
}

/// Small JSON files in the app's Application Support folder.
enum IslandStore {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Island", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name + ".json")) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
    }
}
