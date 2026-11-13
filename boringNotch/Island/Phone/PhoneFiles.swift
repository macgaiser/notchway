//
//  PhoneFiles.swift
//  boringNotch
//
//  Sends files to the phone and receives the ones it sends, over Smart Connect's file transfer.
//  The transfer itself runs in the bundled helper `smartconnect-fex`; this class starts it,
//  tells the phone where to fetch from and puts received files into Downloads.
//

import AppKit
import UserNotifications

@MainActor
final class PhoneFiles: ObservableObject {
    static let shared = PhoneFiles()

    /// What is going on, for the phone view. `nil` when idle.
    @Published private(set) var activity: String?
    @Published private(set) var isSending = false

    private let link = PhoneLink.shared
    private var generation = 0
    /// Port of the transfer we are offering, so the phone's answers to it are not taken for offers.
    private var sendPort: Int?
    private var pulling: Set<Int> = []

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/smartconnect-fex")
    }

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    // MARK: - Log

    /// Everything the transfer does, for the diagnosis. Kept short.
    func log(_ text: String) {
        let url = link.fileLogURL
        let line = "\(Self.stamp.string(from: Date())) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 400_000 { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func show(_ text: String?, clearAfter seconds: Double? = nil) {
        activity = text
        guard let seconds, let text else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.activity == text { self?.activity = nil }
        }
    }

    // MARK: - Watching the phone

    /// Listens for transfer offers from the phone until `stop()` or the next `start()`.
    func start() {
        generation += 1
        let current = generation
        let path = link.controlSocketPath
        let thread = Thread { [weak self] in
            while true {
                let active = DispatchQueue.main.sync { MainActor.assumeIsolated { self?.generation == current } }
                guard active else { return }
                if let fd = LineSocket.open(path) {
                    // 2: file transfer offers. 24: drag and drop, which announces transfers too.
                    if LineSocket.write(#"{"cmd":"watch","services":[2,24]}"#, to: fd) {
                        LineSocket.readLines(from: fd) { line in
                            guard let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                                  let service = frame["service"] as? Int else { return true }
                            let raw = String(decoding: line, as: UTF8.self)
                            return DispatchQueue.main.sync {
                                MainActor.assumeIsolated {
                                    guard let self, self.generation == current else { return false }
                                    self.log("phone -> svc \(service): \(raw)")
                                    if let data = frame["data"] as? [String: Any] { self.received(data) }
                                    return true
                                }
                            }
                        }
                    }
                    close(fd)
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
        thread.name = "island.phone.files"
        thread.start()
    }

    func stop() {
        generation += 1
    }

    // MARK: - Receiving

    /// An offer names the port and certificate of the server the phone started for this transfer.
    private func received(_ data: [String: Any]) {
        guard let port = (data["port"] as? NSNumber)?.intValue, port > 0,
              let fingerprint = data["fingerprint"] as? String, !fingerprint.isEmpty else { return }
        guard let host = link.status.phoneAddress else {
            log("offer ignored: the phone's address is unknown")
            return
        }
        guard isAvailable, port != sendPort, !pulling.contains(port) else { return }
        pulling.insert(port)
        let token = data["token"] as? String ?? ""
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-receive-\(UUID().uuidString)", isDirectory: true)
        show(String(localized: "Empfange Datei vom Handy …"))

        var arguments = ["pull", "--host", host, "--port", String(port), "--fingerprint", fingerprint, "--out", folder.path]
        if !token.isEmpty { arguments += ["--token", token] }
        run(arguments) { _ in } completion: { [weak self] status, errors in
            guard let self else { return }
            self.pulling.remove(port)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard status == 0, !files.isEmpty else {
                self.log("pull failed (\(status)): \(errors)")
                self.show(String(localized: "Die Datei vom Handy kam nicht an."), clearAfter: 8)
                try? FileManager.default.removeItem(at: folder)
                return
            }
            let saved = self.moveToDownloads(files)
            try? FileManager.default.removeItem(at: folder)
            self.log("received \(saved.count) file(s)")
            self.show(saved.count == 1 ? String(localized: "Empfangen: \(saved[0].lastPathComponent)") : String(localized: "\(saved.count) Dateien empfangen"), clearAfter: 8)
            self.announce(saved)
        }
    }

    private func moveToDownloads(_ files: [URL]) -> [URL] {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return [] }
        return files.compactMap { file in
            var target = downloads.appendingPathComponent(file.lastPathComponent)
            let stem = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            var counter = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = downloads.appendingPathComponent(ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
                counter += 1
            }
            do {
                try FileManager.default.moveItem(at: file, to: target)
                return target
            } catch {
                log("could not move \(file.lastPathComponent) to Downloads: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private func announce(_ files: [URL]) {
        guard let first = files.first else { return }
        let content = UNMutableNotificationContent()
        content.title = files.count == 1 ? String(localized: "Datei vom Handy empfangen") : String(localized: "\(files.count) Dateien vom Handy empfangen")
        content.body = files.count == 1 ? String(localized: "\(first.lastPathComponent) liegt im Ordner Downloads.") : String(localized: "Sie liegen im Ordner Downloads.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "island.phone.file.\(UUID().uuidString)", content: content, trigger: nil))
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// The phone stores a received file without saying so, so the Mac confirms it.
    private func announceSent(_ label: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "An das Handy gesendet")
        content.body = String(localized: "\(label) liegt auf dem Handy im Ordner Download.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "island.phone.sent.\(UUID().uuidString)", content: content, trigger: nil))
    }

    // MARK: - Sending

    /// Name of the phone as a target in the shelf's share area.
    static let shareProviderID = "Handy"

    /// A white phone symbol for the share area, which shows providers by image.
    static var shareProviderImage: Data? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        return NSImage(systemSymbolName: "smartphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?.tiffRepresentation
    }

    func send(_ urls: [URL]) {
        guard isAvailable else {
            show(String(localized: "Die Dateiübertragung fehlt in dieser App-Version."), clearAfter: 8)
            return
        }
        guard link.status.connected else {
            show(String(localized: "Das Handy ist nicht verbunden."), clearAfter: 6)
            return
        }
        guard !isSending else {
            show(String(localized: "Es läuft bereits eine Übertragung."), clearAfter: 5)
            return
        }

        // The helper runs in the app's sandbox without access to files the user picked,
        // so it gets its own copies.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-send-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copies: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let copy = folder.appendingPathComponent("\(copies.count)", isDirectory: true).appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { copies.append(copy) }
        }
        guard !copies.isEmpty else {
            show(String(localized: "Ordner lassen sich noch nicht senden, nur einzelne Dateien."), clearAfter: 8)
            try? FileManager.default.removeItem(at: folder)
            return
        }

        isSending = true
        let label = copies.count == 1 ? copies[0].lastPathComponent : String(localized: "\(copies.count) Dateien")
        show(String(localized: "Sende \(label) …"))
        log("send \(copies.count) file(s)")

        var contacted = false
        let name = Host.current().localizedName ?? "Mac"
        run(["send", "--name", name, "--wait", "30"] + copies.map(\.path)) { [weak self] event in
            guard let self else { return }
            switch event["event"] as? String {
            case "ready":
                self.advertise(event, contacted: { contacted })
            case "connection":
                contacted = true
                self.log("helper: the phone connected")
            case "done":
                break
            default:
                self.log("helper: \(Self.compact(event))")
            }
        } completion: { [weak self] status, errors in
            guard let self else { return }
            self.isSending = false
            self.sendPort = nil
            try? FileManager.default.removeItem(at: folder)
            if status == 0 {
                self.log("send finished")
                self.show(String(localized: "Gesendet: \(label)"), clearAfter: 8)
                self.announceSent(label)
            } else {
                self.log("send failed (\(status)): \(errors)")
                self.show(contacted ? String(localized: "Die Übertragung wurde abgebrochen.") : String(localized: "Das Handy hat die Datei nicht abgeholt."), clearAfter: 10)
            }
        }
    }

    /// Tells the phone where the transfer waits: service 2, `cmd` 1, with the port, certificate
    /// fingerprint and token of our server and this Mac's address (verified with a razr 60 ultra:
    /// the phone then connects and downloads). `cmd` 2 is what the phone itself sends when it is
    /// the sender; it goes out as a fallback in case another phone expects that form.
    private func advertise(_ ready: [String: Any], contacted: @escaping () -> Bool) {
        guard let port = ready["port"] as? Int, let fingerprint = ready["fingerprint"] as? String,
              let token = ready["token"] as? String else { return }
        sendPort = port
        var data: [String: Any] = [
            "ver": "1.0.0", "port": port, "fingerprint": fingerprint, "token": token,
            "serviceId": 0, "autoDownload": false, "specifiedPath": false, "errorcode": 0,
        ]
        if let address = link.status.pcAddress { data["ip"] = address }
        for (index, command) in [1, 2].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 8) { [weak self] in
                guard let self, self.isSending, self.sendPort == port, !contacted() else { return }
                data["cmd"] = command
                self.log("announce: cmd \(command)")
                self.link.send(service: 2, data: data)
            }
        }
    }

    private static func compact(_ event: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helper process

    /// Runs the helper; `onEvent` gets each JSON line it prints, `completion` its exit status and
    /// what it wrote to its error stream.
    private func run(_ arguments: [String], onEvent: @escaping @MainActor ([String: Any]) -> Void,
                     completion: @escaping @MainActor (Int32, String) -> Void) {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        var pending = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(event) } }
                }
            }
        }
        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // After the last output lines have been delivered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { completion(finished.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
        do {
            try process.run()
        } catch {
            completion(-1, error.localizedDescription)
        }
    }
}
