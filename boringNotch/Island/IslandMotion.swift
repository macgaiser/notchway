//
//  IslandMotion.swift
//  boringNotch
//
//  Single source of truth for how the island moves. Tune values here only.
//

import SwiftUI

enum IslandMotion {
    /// Shape growing from the notch: quick, with a small overshoot.
    static let open = Animation.spring(duration: 0.5, bounce: 0.26)

    /// Shape collapsing back: no bounce, so it settles cleanly into the notch.
    static let close = Animation.spring(duration: 0.38, bounce: 0)

    /// Hover feedback and finger-driven movement.
    static let interactive = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.82, blendDuration: 0)

    /// Switching between tabs inside the open island.
    static let tab = Animation.spring(duration: 0.35, bounce: 0.15)

    /// Content appears slightly after the shape starts growing and leaves before it collapses.
    static let contentTransition = AnyTransition.asymmetric(
        insertion: .modifier(
            active: ContentPhase(opacity: 0, scale: 0.86, blur: 10),
            identity: ContentPhase(opacity: 1, scale: 1, blur: 0)
        )
        .animation(.spring(duration: 0.45, bounce: 0.18).delay(0.07)),
        removal: .modifier(
            active: ContentPhase(opacity: 0, scale: 0.92, blur: 8),
            identity: ContentPhase(opacity: 1, scale: 1, blur: 0)
        )
        .animation(.easeOut(duration: 0.14))
    )
}

private struct ContentPhase: ViewModifier {
    let opacity: Double
    let scale: CGFloat
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale, anchor: .top)
            .blur(radius: blur)
    }
}
