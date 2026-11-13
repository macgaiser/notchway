//
//  IslandTabs.swift
//  boringNotch
//
//  Titles, icons and visibility of the views inside the open island.
//

import Defaults
import Foundation
import SwiftUI

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
    /// Tab symbols left and right of the notch, each in display order from left to right.
    static let islandTabsLeading = Key<[String]>("islandTabsLeading", default: ["home", "shelf", "quickLaunch", "clipboard", "notes"])
    static let islandTabsTrailing = Key<[String]>("islandTabsTrailing", default: ["pomodoro", "tasks", "capture", "phone"])
}

/// Which tab symbol sits on which side of the notch.
enum IslandTabLayout {
    /// Symbols that fit beside the notch; the right side shares its room with the settings button.
    static let leadingCapacity = 5
    static let trailingCapacity = 4

    /// Every view exactly once: stored order first, views the stored lists do not know go to the right.
    static func arranged(leading: [String], trailing: [String]) -> (leading: [NotchViews], trailing: [NotchViews]) {
        var seen = Set<NotchViews>()
        var left: [NotchViews] = []
        var right: [NotchViews] = []
        for raw in leading {
            if let tab = NotchViews(rawValue: raw), seen.insert(tab).inserted { left.append(tab) }
        }
        for raw in trailing {
            if let tab = NotchViews(rawValue: raw), seen.insert(tab).inserted { right.append(tab) }
        }
        for tab in NotchViews.allCases where !seen.contains(tab) {
            right.append(tab)
        }
        return (left, right)
    }

    /// The symbols actually shown. What does not fit on the left moves over to the right.
    static func visible(leading: [String], trailing: [String], hidden: [String], shelfEnabled: Bool) -> (leading: [NotchViews], trailing: [NotchViews]) {
        let all = arranged(leading: leading, trailing: trailing)
        let left = all.leading.filter { $0.isVisible(hidden: hidden, shelfEnabled: shelfEnabled) }
        let right = all.trailing.filter { $0.isVisible(hidden: hidden, shelfEnabled: shelfEnabled) }
        return (Array(left.prefix(leadingCapacity)), Array(left.dropFirst(leadingCapacity)) + right)
    }
}

/// Dragging a tab symbol along the header of the open island, also across the notch.
@MainActor
final class IslandTabDrag: ObservableObject {
    static let shared = IslandTabDrag()
    static let space = "islandHeader"

    @Published var dragged: NotchViews?
    @Published var location: CGPoint = .zero
    /// Where each symbol sits in the header, and how wide the header is.
    var frames: [NotchViews: CGRect] = [:]
    var headerWidth: CGFloat = 0

    private var shown: (leading: [NotchViews], trailing: [NotchViews]) {
        IslandTabLayout.visible(
            leading: Defaults[.islandTabsLeading], trailing: Defaults[.islandTabsTrailing],
            hidden: Defaults[.islandHiddenTabs], shelfEnabled: Defaults[.boringShelf])
    }

    /// Side and slot under the pointer; `neighbours` are the symbols of that side without the dragged one.
    private var target: (leading: Bool, index: Int, neighbours: [NotchViews])? {
        guard let dragged, headerWidth > 0 else { return nil }
        let leading = location.x < headerWidth / 2
        let neighbours = (leading ? shown.leading : shown.trailing).filter { $0 != dragged }
        let index = neighbours.filter { (frames[$0]?.midX ?? 0) < location.x }.count
        return (leading, index, neighbours)
    }

    /// Horizontal position of the line that shows where the symbol will land.
    var markerX: CGFloat? {
        guard let target else { return nil }
        if target.index < target.neighbours.count, let frame = frames[target.neighbours[target.index]] {
            return frame.minX
        }
        if let last = target.neighbours.last, let frame = frames[last] {
            return frame.maxX
        }
        return target.leading ? 14 : headerWidth - 52
    }

    func end() {
        defer { dragged = nil }
        guard let dragged, let target else { return }
        var all = IslandTabLayout.arranged(leading: Defaults[.islandTabsLeading], trailing: Defaults[.islandTabsTrailing])
        all.leading.removeAll { $0 == dragged }
        all.trailing.removeAll { $0 == dragged }
        var side = target.leading ? all.leading : all.trailing

        let position: Int
        if target.index < target.neighbours.count, let at = side.firstIndex(of: target.neighbours[target.index]) {
            position = at
        } else if let last = target.neighbours.last, let at = side.firstIndex(of: last) {
            position = at + 1
        } else {
            position = target.leading ? side.count : 0
        }
        side.insert(dragged, at: position)

        withAnimation(IslandMotion.tab) {
            Defaults[.islandTabsLeading] = (target.leading ? side : all.leading).map(\.rawValue)
            Defaults[.islandTabsTrailing] = (target.leading ? all.trailing : side).map(\.rawValue)
        }
    }
}

extension BoringViewModel {
    /// Grows the open island downwards, or brings it back to its normal height.
    func setIslandExpanded(_ expanded: Bool) {
        guard notchState == .open else { return }
        let height = expanded ? expandedNotchHeight : openNotchSize.height
        guard notchSize.height != height else { return }
        withAnimation(IslandMotion.open) {
            notchSize = CGSize(width: openNotchSize.width, height: height)
        }
    }
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
