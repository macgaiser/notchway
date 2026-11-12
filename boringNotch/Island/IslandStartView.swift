//
//  IslandStartView.swift
//  boringNotch
//
//  Which view the island shows when it is opened.
//

import Defaults
import SwiftUI

enum IslandStartView: String, CaseIterable, Identifiable, Defaults.Serializable {
    case home
    case shelf
    case shelfWhenFilled
    case lastUsed
    case quickLaunch
    case clipboard
    case notes
    case pomodoro
    case tasks
    case capture
    case phone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shelfWhenFilled: "Ablage, wenn Dateien darin liegen"
        case .lastUsed: "Zuletzt genutzte Ansicht"
        default: fixedView?.title ?? rawValue
        }
    }

    private var fixedView: NotchViews? {
        switch self {
        case .shelfWhenFilled, .lastUsed: nil
        default: NotchViews(rawValue: rawValue)
        }
    }

    /// The view to prepare for the next opening, decided when the island closes.
    @MainActor
    func resolve(current: NotchViews) -> NotchViews {
        let wanted: NotchViews
        switch self {
        case .shelfWhenFilled:
            wanted = ShelfStateViewModel.shared.isEmpty ? .home : .shelf
        case .lastUsed:
            wanted = current
        default:
            wanted = fixedView ?? .home
        }
        return wanted.isVisible ? wanted : .home
    }
}

extension Defaults.Keys {
    static let islandStartView = Key<IslandStartView>("islandStartView", default: .home)
}
