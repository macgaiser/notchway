//
//  SelectionOverlay.swift
//  boringNotch
//
//  Dims the screens and lets the user drag a frame or pick a window.
//

import AppKit

enum CaptureSelection {
    /// Rect in points of the display, measured from its top-left corner.
    case area(CGRect, CGDirectDisplayID)
    case window(CGWindowID)
}

@MainActor
final class SelectionOverlay {
    enum Mode {
        case area
        case window
    }

    static let shared = SelectionOverlay()

    private var windows: [OverlayWindow] = []
    private var completion: ((CaptureSelection?) -> Void)?

    func begin(_ mode: Mode, hint: String, completion: @escaping (CaptureSelection?) -> Void) {
        finish(nil)
        self.completion = completion

        let candidates = mode == .window ? Self.visibleWindows() : []
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false

            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.mode = mode
            view.hint = hint
            view.screenOrigin = Self.topLeftOrigin(of: screen)
            view.displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            view.candidates = candidates
            view.onFinish = { [weak self] selection in self?.finish(selection) }
            window.contentView = view
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        // Keyboard (Esc) goes to the screen the pointer is on.
        let pointer = NSEvent.mouseLocation
        let key = windows.first { $0.frame.contains(pointer) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.contentView)
    }

    private func finish(_ selection: CaptureSelection?) {
        guard !windows.isEmpty || completion != nil else { return }
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        let completion = self.completion
        self.completion = nil
        NSCursor.arrow.set()
        // Let the overlay leave the screen before anything is captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            completion?(selection)
        }
    }

    /// Quartz window coordinates start at the top-left of the primary display.
    private static func topLeftOrigin(of screen: NSScreen) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    }

    /// Normal app windows, front to back, in Quartz coordinates.
    private static func visibleWindows() -> [(id: CGWindowID, bounds: CGRect)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width > 60, bounds.height > 40 else { return nil }
            return (id, bounds)
        }
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    var mode: SelectionOverlay.Mode = .area
    var hint = ""
    var screenOrigin: CGPoint = .zero
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var candidates: [(id: CGWindowID, bounds: CGRect)] = []
    var onFinish: ((CaptureSelection?) -> Void)?

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hovered: (id: CGWindowID, rect: CGRect)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .area ? .crosshair : .pointingHand)
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        let point = location(of: event)
        let global = CGPoint(x: point.x + screenOrigin.x, y: point.y + screenOrigin.y)
        if let match = candidates.first(where: { $0.bounds.contains(global) }) {
            hovered = (match.id, match.bounds.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y))
        } else {
            hovered = nil
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .window {
            mouseMoved(with: event)
            if let hovered { onFinish?(.window(hovered.id)) }
            return
        }
        dragStart = location(of: event)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let dragStart else { return }
        let point = location(of: event)
        selection = CGRect(
            x: min(dragStart.x, point.x), y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x), height: abs(point.y - dragStart.y)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        defer { dragStart = nil }
        guard let selection, selection.width >= 8, selection.height >= 8 else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onFinish?(.area(selection.integral, displayID))
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(mode == .area ? 0.32 : 0.22).setFill()
        bounds.fill()

        if let rect = mode == .area ? selection : hovered?.rect {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            if mode == .window {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                rect.fill(using: .sourceOver)
            }
            let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = mode == .window ? 3 : 1.5
            (mode == .window ? NSColor.controlAccentColor : NSColor.white).setStroke()
            border.stroke()

            if mode == .area {
                drawLabel("\(Int(rect.width)) × \(Int(rect.height))", at: CGPoint(x: rect.minX, y: rect.maxY + 6), small: true)
            }
        }

        if selection == nil {
            drawLabel(hint, at: CGPoint(x: bounds.midX, y: 64), small: false, centered: true)
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint, small: Bool, centered: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: small ? 12 : 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var origin = point
        if centered { origin.x -= size.width / 2 }
        origin.x = min(max(8, origin.x), bounds.maxX - size.width - 20)
        origin.y = min(origin.y, bounds.maxY - size.height - 14)
        let background = CGRect(origin: origin, size: size).insetBy(dx: -9, dy: -5)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()
        text.draw(at: origin, withAttributes: attributes)
    }
}
