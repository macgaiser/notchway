//
//  HoverLabel.swift
//  boringNotch
//
//  A name tag that appears at once while the pointer is over a control, like the labels in the Dock.
//

import SwiftUI

struct HoverLabel: ViewModifier {
    let text: String
    /// Side of the control the tag appears on.
    var edge: VerticalEdge = .bottom

    @State private var hovering = false
    /// Text line plus padding plus the pointer.
    private static let tagHeight: CGFloat = 32

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                if hovering {
                    tag
                        .fixedSize()
                        .frame(height: Self.tagHeight)
                        // Move the tag fully outside the control, so it never covers the icon.
                        .offset(y: (Self.tagHeight + 4) * (edge == .bottom ? 1 : -1))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .zIndex(hovering ? 100 : 0)
            .accessibilityLabel(text)
    }

    private var tag: some View {
        VStack(spacing: 0) {
            if edge == .bottom { pointer.rotationEffect(.degrees(180)) }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
            if edge == .top { pointer }
        }
    }

    private var pointer: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 12, y: 0))
            path.addLine(to: CGPoint(x: 6, y: 6))
            path.closeSubpath()
        }
        .fill(.regularMaterial)
        .frame(width: 12, height: 6)
    }
}

extension View {
    func hoverLabel(_ text: String, edge: VerticalEdge = .bottom) -> some View {
        modifier(HoverLabel(text: text, edge: edge))
    }
}

/// Icon-only button that names itself on hover.
struct IconActionButton: View {
    let title: String
    let icon: String
    var prominent = false
    var edge: VerticalEdge = .bottom
    let action: () -> Void

    var body: some View {
        Group {
            if prominent {
                Button(action: action) { symbol }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { symbol }.buttonStyle(.bordered)
            }
        }
        .hoverLabel(title, edge: edge)
    }

    private var symbol: some View {
        Image(systemName: icon)
            .font(.system(size: 14))
            .frame(width: 22, height: 20)
    }
}

/// A small "i" that opens an explanation over the view it belongs to.
struct IslandInfoButton: View {
    @Binding var isShown: Bool

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: isShown ? "info.circle.fill" : "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Hinweis"))
    }
}

extension View {
    /// Covers the view with an explanation while `isShown` is set. A click anywhere closes it.
    /// Drawn inside the island, since a popover would count as leaving it.
    func islandInfo(isShown: Binding<Bool>, title: String, points: [String]) -> some View {
        overlay {
            if isShown.wrappedValue {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(title, systemImage: "info.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(point)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.11)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { isShown.wrappedValue = false }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isShown.wrappedValue)
    }
}
