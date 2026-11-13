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
    @ObservedObject private var drag = IslandTabDrag.shared
    @Default(.islandTabsLeading) private var leadingTabs
    @Default(.islandTabsTrailing) private var trailingTabs

    private var tabs: [NotchViews] {
        let sides = IslandTabLayout.visible(leading: leadingTabs, trailing: trailingTabs, hidden: hiddenTabs, shelfEnabled: shelfEnabled)
        guard sides.leading.count + sides.trailing.count > 1 else { return [] }
        return part == .leading ? sides.leading : sides.trailing
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
                    .opacity(drag.dragged == tab ? 0.3 : 1)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(IslandTabDrag.space))
                    } action: { frame in
                        drag.frames[tab] = frame
                    }
                    // Symbols can be dragged to another slot, also to the other side of the notch.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .named(IslandTabDrag.space))
                            .onChanged { value in
                                drag.dragged = tab
                                drag.location = value.location
                            }
                            .onEnded { _ in drag.end() }
                    )
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
