//
//  MusicLauncherButton.swift
//  boringNotch
//
//  Shown in the player while nothing is playing: opens the chosen music app or site.
//

import Defaults
import SwiftUI

extension Defaults.Keys {
    /// nil hides the button.
    static let islandMusicLauncher = Key<QuickLaunchItem?>("islandMusicLauncher", default: .youtubeMusic)
}

struct MusicLauncherButton: View {
    @EnvironmentObject var vm: BoringViewModel
    @Default(.islandMusicLauncher) private var item

    var body: some View {
        if let item {
            Button {
                if item.open() { vm.close() }
            } label: {
                HStack(spacing: 5) {
                    QuickLaunchIcon(item: item)
                        .frame(width: 14, height: 14)
                    Text(item.name)
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.vertical, 4)
                .padding(.horizontal, 9)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(String(localized: "\(item.name) öffnen"))
        }
    }
}
