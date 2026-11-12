//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.islandHiddenTabs) private var hiddenTabs
    @Default(.boringShelf) private var shelfEnabled
    @Namespace var animation

    /// The header has room on both sides of the notch; tabs fill the left side first.
    enum Part {
        case leading, trailing
    }

    var part: Part = .leading
    static let leadingCapacity = 5

    private var tabs: [NotchViews] {
        let all = NotchViews.allCases.filter { $0.isVisible(hidden: hiddenTabs, shelfEnabled: shelfEnabled) }
        guard all.count > 1 else { return [] }
        return part == .leading ? Array(all.prefix(Self.leadingCapacity)) : Array(all.dropFirst(Self.leadingCapacity))
    }

    var body: some View {
        if !tabs.isEmpty {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    TabButton(label: tab.title, icon: tab.icon, selected: coordinator.currentView == tab) {
                        withAnimation(IslandMotion.tab) {
                            coordinator.currentView = tab
                        }
                    }
                    .help(tab.title)
                    .frame(height: 26)
                    .foregroundStyle(tab == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab == coordinator.currentView {
                            Capsule()
                                .fill(Color(nsColor: .secondarySystemFill))
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        }
                    }
                }
            }
            .clipShape(Capsule())
        }
    }
}
