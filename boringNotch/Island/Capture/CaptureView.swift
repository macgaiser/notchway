//
//  CaptureView.swift
//  boringNotch
//
//  The "Aufnahme" view in the island and the flow from button to editor window.
//

import AVFoundation
import Defaults
import SwiftUI

extension Defaults.Keys {
    /// Off: the video records the whole screen right away.
    static let islandVideoSelectArea = Key<Bool>("islandVideoSelectArea", default: false)
    static let islandVideoSystemAudio = Key<Bool>("islandVideoSystemAudio", default: true)
    static let islandVideoMicrophone = Key<Bool>("islandVideoMicrophone", default: false)
}

@MainActor
final class CaptureCoordinator: ObservableObject {
    static let shared = CaptureCoordinator()

    @Published var message: String?
    private var stopPanel: NSPanel?

    /// False (with a message) when macOS has not granted screen recording yet.
    private func ensurePermission() -> Bool {
        if CaptureEngine.hasPermission { return true }
        CGRequestScreenCaptureAccess()
        message = CaptureError.noPermission.errorDescription
        return false
    }

    func captureArea() {
        guard ensurePermission() else { return }
        select(.area, hint: String(localized: "Rahmen aufziehen · Esc bricht ab")) { selection in
            guard case .area(let rect, let displayID) = selection else { return }
            let capture = try await CaptureEngine.image(of: rect, on: displayID)
            self.finish(capture)
        }
    }

    func captureWindow() {
        guard ensurePermission() else { return }
        select(.window, hint: String(localized: "Fenster anklicken · Esc bricht ab")) { selection in
            guard case .window(let windowID) = selection else { return }
            let capture = try await CaptureEngine.image(ofWindow: windowID)
            self.finish(capture)
        }
    }

    func recordVideo() {
        guard ensurePermission() else { return }
        if Defaults[.islandVideoSelectArea] {
            select(.area, hint: String(localized: "Bereich für das Video aufziehen · Esc bricht ab")) { selection in
                guard case .area(let rect, let displayID) = selection else { return }
                try await self.startRecording(rect: rect, on: displayID)
            }
            return
        }

        // Whole screen: the one the pointer is on, which is where the island was just clicked.
        message = nil
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            do {
                try await startRecording(rect: nil, on: displayID)
            } catch {
                report(error)
            }
        }
    }

    private func startRecording(rect: CGRect?, on displayID: CGDirectDisplayID) async throws {
        var microphone = Defaults[.islandVideoMicrophone]
        if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            microphone = false
            message = String(localized: "Kein Zugriff aufs Mikrofon – das Video wird ohne Mikrofon aufgenommen.")
        }
        try await ScreenRecorder.shared.start(
            rect: rect, on: displayID,
            systemAudio: Defaults[.islandVideoSystemAudio], microphone: microphone
        )
        showStopPanel()
    }

    func stopRecording() {
        hideStopPanel()
        Task {
            do {
                let url = try await ScreenRecorder.shared.stop()
                CaptureWindows.shared.show(video: url)
            } catch {
                report(error)
            }
        }
    }

    private func select(_ mode: SelectionOverlay.Mode, hint: String, then work: @escaping (CaptureSelection) async throws -> Void) {
        message = nil
        // Wait for the island to finish closing, so it is not in the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            SelectionOverlay.shared.begin(mode, hint: hint) { selection in
                guard let selection else { return }
                Task {
                    do {
                        try await work(selection)
                    } catch {
                        self.report(error)
                    }
                }
            }
        }
    }

    private func finish(_ capture: CapturedImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let size = CGSize(width: CGFloat(capture.image.width) / capture.scale, height: CGFloat(capture.image.height) / capture.scale)
        pasteboard.writeObjects([NSImage(cgImage: capture.image, size: size)])
        CaptureWindows.shared.show(capture)
    }

    private func report(_ error: Error) {
        message = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = String(localized: "Aufnahme fehlgeschlagen")
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Stop control while recording

    private func showStopPanel() {
        hideStopPanel()
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 190, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: RecordingStopControl { [weak self] in self?.stopRecording() })
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.midX - 95, y: frame.minY + 28))
        }
        panel.orderFrontRegardless()
        stopPanel = panel
    }

    private func hideStopPanel() {
        stopPanel?.orderOut(nil)
        stopPanel = nil
    }
}

private struct RecordingTime: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { timeline in
            let seconds = max(0, Int(timeline.date.timeIntervalSince(since)))
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .monospacedDigit()
        }
    }
}

/// Small floating control. It belongs to this app, so it does not show up in the video.
private struct RecordingStopControl: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                Text(String(localized: "Stopp"))
                    .fontWeight(.semibold)
                if let since = recorder.startedAt {
                    RecordingTime(since: since)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(width: 190, height: 44)
            .background(Capsule().fill(Color.black.opacity(0.86)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Aufnahme beenden und Video öffnen"))
    }
}

struct CaptureView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var coordinator = CaptureCoordinator.shared
    @ObservedObject private var recorder = ScreenRecorder.shared
    @Default(.islandVideoSelectArea) private var videoSelectArea
    @Default(.islandVideoSystemAudio) private var videoSystemAudio
    @Default(.islandVideoMicrophone) private var videoMicrophone

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                tile(String(localized: "Rahmen"), detail: String(localized: "Bereich aufziehen"), icon: "rectangle.dashed") {
                    coordinator.captureArea()
                }
                tile(String(localized: "Fenster"), detail: String(localized: "Fenster anklicken"), icon: "macwindow") {
                    coordinator.captureWindow()
                }
                videoTile
            }

            if let message = coordinator.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Top three quarters start (or stop) the recording; the bottom row holds its three options.
    private var videoTile: some View {
        VStack(spacing: 1) {
            Button {
                if recorder.isRecording {
                    coordinator.stopRecording()
                } else {
                    coordinator.recordVideo()
                    if coordinator.message == nil { vm.close() }
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(recorder.isRecording ? .red : .white)
                        .frame(height: 28)
                    Text(recorder.isRecording ? String(localized: "Stopp") : String(localized: "Video"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(recorder.isRecording ? String(localized: "Aufnahme läuft") : videoSelectArea ? String(localized: "Bereich aufziehen") : String(localized: "Ganzer Bildschirm"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.07))
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandTileStyle(cornerRadius: 0))

            HStack(spacing: 1) {
                videoOption(String(localized: "Ton"), icon: "speaker.wave.2.fill", isOn: $videoSystemAudio,
                            help: String(localized: "Nimmt auf, was der Mac gerade abspielt"))
                videoOption(String(localized: "Mikro"), icon: "mic.fill", isOn: $videoMicrophone,
                            help: String(localized: "Nimmt zusätzlich deine Stimme auf"))
                videoOption(String(localized: "Bereich"), icon: "rectangle.dashed", isOn: $videoSelectArea,
                            help: String(localized: "An: vorher einen Bereich aufziehen. Aus: ganzer Bildschirm."))
            }
            .frame(height: 25)
            .disabled(recorder.isRecording)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func videoOption(_ title: String, icon: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn.wrappedValue ? .white : .secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isOn.wrappedValue ? Color.accentColor : Color.white.opacity(0.07))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(IslandMotion.interactive, value: isOn.wrappedValue)
        .help(help)
    }

    private func tile(_ title: String, detail: String, icon: String, tint: Color = .white, closes: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            action()
            // Keep the island open when there is a message to read.
            if closes, coordinator.message == nil { vm.close() }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(height: 32)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(IslandTileStyle())
    }
}
