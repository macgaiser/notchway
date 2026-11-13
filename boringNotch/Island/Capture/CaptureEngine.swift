//
//  CaptureEngine.swift
//  boringNotch
//
//  Takes screenshots and records video through ScreenCaptureKit.
//

import AppKit
import AVFoundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noPermission
    case displayNotFound
    case windowNotFound
    case needsNewerSystem
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPermission:
            String(localized: "Die Berechtigung „Bildschirmaufnahme“ fehlt. Bitte in den Systemeinstellungen unter Datenschutz & Sicherheit erlauben und die App danach neu starten.")
        case .displayNotFound: String(localized: "Der Bildschirm wurde nicht gefunden.")
        case .windowNotFound: String(localized: "Das Fenster ist nicht mehr vorhanden.")
        case .needsNewerSystem: String(localized: "Videoaufnahmen brauchen macOS 15 oder neuer.")
        case .failed(let reason): reason
        }
    }
}

struct CapturedImage {
    let image: CGImage
    /// Pixels per point, so the editor can show the shot at its on-screen size.
    let scale: CGFloat
}

enum CaptureEngine {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noPermission
        }
    }

    /// The whole display without this app's floating helpers (island, selection overlay, recording
    /// control). Its ordinary windows, such as phone streams and the editor, stay in the picture.
    static func displayFilter(for displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Ordinary windows sit on layer 0; the helpers float on higher layers.
        let helpers = content.windows.filter { $0.owningApplication?.processID == ownPID && $0.windowLayer != 0 }
        return SCContentFilter(display: display, excludingWindows: helpers)
    }

    /// `rect` is in points of that display, measured from its top-left corner.
    static func configuration(for rect: CGRect, filter: SCContentFilter) -> SCStreamConfiguration {
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        // Even pixel sizes, as video encoders require.
        configuration.width = max(2, Int(rect.width * scale) / 2 * 2)
        configuration.height = max(2, Int(rect.height * scale) / 2 * 2)
        return configuration
    }

    static func image(of rect: CGRect, on displayID: CGDirectDisplayID) async throws -> CapturedImage {
        let filter = try await displayFilter(for: displayID)
        let configuration = configuration(for: rect, filter: filter)
        configuration.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CapturedImage(image: image, scale: CGFloat(filter.pointPixelScale))
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
    }

    static func image(ofWindow windowID: CGWindowID) async throws -> CapturedImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(filter.contentRect.width * scale))
        configuration.height = max(2, Int(filter.contentRect.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CapturedImage(image: image, scale: scale)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
    }
}

/// Records one area of a display into an MP4 file.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?

    private var stream: SCStream?
    private var recordingOutput: AnyObject?
    private var outputURL: URL?
    private var didFinishWriting = false
    private var failure: String?

    /// `rect` nil records the whole display.
    func start(rect: CGRect?, on displayID: CGDirectDisplayID, systemAudio: Bool, microphone: Bool) async throws {
        guard #available(macOS 15.0, *) else { throw CaptureError.needsNewerSystem }
        guard !isRecording else { return }

        let filter = try await CaptureEngine.displayFilter(for: displayID)
        let area = rect ?? CGRect(origin: .zero, size: filter.contentRect.size)
        let configuration = CaptureEngine.configuration(for: area, filter: filter)
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.capturesAudio = systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = microphone

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bildschirmvideo \(formatter.string(from: Date())).mp4")
        try? FileManager.default.removeItem(at: url)

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = url
        outputConfiguration.videoCodecType = .h264
        outputConfiguration.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }

        self.stream = stream
        recordingOutput = output
        outputURL = url
        didFinishWriting = false
        failure = nil
        startedAt = Date()
        isRecording = true
    }

    /// Stops and returns the finished file.
    func stop() async throws -> URL {
        guard isRecording, let stream, let outputURL else { throw CaptureError.failed(String(localized: "Es läuft keine Aufnahme.")) }
        isRecording = false
        startedAt = nil
        try? await stream.stopCapture()

        // The file is complete only once the output reports it; give it a few seconds.
        for _ in 0..<50 where !didFinishWriting && failure == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        self.stream = nil
        recordingOutput = nil
        self.outputURL = nil

        if let failure { throw CaptureError.failed(failure) }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CaptureError.failed(String(localized: "Die Videodatei wurde nicht geschrieben."))
        }
        return outputURL
    }
}

@available(macOS 15.0, *)
extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.didFinishWriting = true }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let reason = error.localizedDescription
        Task { @MainActor in self.failure = reason }
    }
}
