//
//  PhoneAudio.swift
//  boringNotch
//
//  Sound of the phone on the Mac. The Smart Connect link streams video only, so the sound takes
//  another road: Android's wireless debugging (ADB) and the small server of the scrcpy project
//  (Apache-2.0), which captures what the phone plays and sends it as raw PCM. Both are shipped
//  inside the app; the user pairs the phone once with the code from its developer options.
//

import AppKit
import AVFoundation
import Defaults
import Foundation

extension Defaults.Keys {
    /// Play the sound of streamed phone apps on the Mac.
    static let islandPhoneAudio = Key<Bool>("islandPhoneAudio", default: false)
    /// Keep playing on the phone as well. Off: the phone is silent while its sound is on the Mac.
    static let islandPhoneAudioOnPhone = Key<Bool>("islandPhoneAudioOnPhone", default: false)
}

@MainActor
final class PhoneAudio: NSObject, ObservableObject {
    static let shared = PhoneAudio()

    /// The scrcpy server we ship; it refuses to start under any other version string.
    nonisolated static let serverVersion = "5.0.1"
    /// Our own ADB server port, so a developer's own adb on 5037 is left alone.
    nonisolated static let adbPort = "5038"

    @Published private(set) var pairingAvailable = false
    @Published private(set) var connected = false
    @Published private(set) var playing = false
    @Published var message: String?

    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []
    private var connectEndpoint: String?
    private var pairingEndpoint: String?
    private var streamCount = 0
    private var stopWork: DispatchWorkItem?
    private var session: AudioSession?
    private var observing = false

    private var phoneAddress: String? { PhoneLink.shared.status.phoneAddress }

    // MARK: - Switching on and off

    /// Called whenever a setting changed or the app started.
    func configure() {
        Self.log("configure enabled=\(Defaults[.islandPhoneAudio]) installed=\(Self.isInstalled)")
        if Defaults[.islandPhoneAudio] {
            startDiscovery()
            observeTermination()
        } else {
            stopSession()
            stopDiscovery()
            connected = false
            message = nil
            Task.detached { _ = Self.adb(["kill-server"]) }
        }
    }

    private func observeTermination() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            _ = Self.adb(["kill-server"], timeout: 3)
        }
    }

    /// Phone app windows opened or closed: sound runs exactly as long as one is open.
    func streamsChanged(count: Int) {
        streamCount = count
        Self.log("streams=\(count) enabled=\(Defaults[.islandPhoneAudio]) connected=\(connected) session=\(session != nil)")
        guard Defaults[.islandPhoneAudio] else { return }
        if count > 0 {
            stopWork?.cancel()
            stopWork = nil
            if !connected {
                message = String(localized: "Kein Ton: Am Handy ist „Drahtloses Debugging“ aus. Einschalten, dann verbindet sich der Mac von selbst.")
                connect()
            }
            startSession()
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.stopSession() }
            }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    // MARK: - Finding the phone (Bonjour)

    private func startDiscovery() {
        guard browsers.isEmpty else { return }
        for type in ["_adb-tls-connect._tcp.", "_adb-tls-pairing._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    private func stopDiscovery() {
        browsers.forEach { $0.stop() }
        browsers = []
        resolving.forEach { $0.stop() }
        resolving = []
        connectEndpoint = nil
        pairingEndpoint = nil
        pairingAvailable = false
    }

    private func endpoint(of service: NetService) -> String? {
        for data in service.addresses ?? [] {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return -1 }
                return getnameinfo(base, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
            let text = String(cString: host)
            // IPv4 only: that is what the phone link uses, too.
            if result == 0, !text.contains(":") { return "\(text):\(service.port)" }
        }
        return nil
    }

    private func isPhone(_ endpoint: String) -> Bool {
        guard let phoneAddress, !phoneAddress.isEmpty else { return true }
        return endpoint.hasPrefix(phoneAddress + ":")
    }

    fileprivate func resolved(_ service: NetService) {
        let found = endpoint(of: service)
        Self.log("found \(service.type) \(found ?? "no address") phone=\(phoneAddress ?? "?")")
        guard let endpoint = found, isPhone(endpoint) else { return }
        if service.type.contains("pairing") {
            pairingEndpoint = endpoint
            pairingAvailable = true
        } else {
            connectEndpoint = endpoint
            connect()
        }
    }

    fileprivate func removed(_ service: NetService) {
        if service.type.contains("pairing") {
            pairingEndpoint = nil
            pairingAvailable = false
        }
    }

    // MARK: - Pairing and connecting

    func pair(code: String) {
        guard let pairingEndpoint else {
            message = String(localized: "Am Handy zuerst „Mit Kopplungscode koppeln“ öffnen.")
            return
        }
        message = String(localized: "Koppele …")
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        Task {
            let result = await Task.detached { Self.adb(["pair", pairingEndpoint, trimmed], timeout: 25) }.value
            Self.log("pair -> \(result.status) \(result.output.prefix(160))")
            if result.status == 0, result.output.contains("Successfully paired") {
                message = String(localized: "Gekoppelt.")
                pairingAvailable = false
                connect()
            } else {
                message = String(localized: "Kopplung fehlgeschlagen. Code und Fenster am Handy prüfen.")
            }
        }
    }

    /// Connects to the phone's wireless debugging port, which changes whenever the phone switches it on.
    func connect() {
        guard Defaults[.islandPhoneAudio], let connectEndpoint else { return }
        Task {
            let result = await Task.detached { Self.adb(["connect", connectEndpoint], timeout: 15) }.value
            Self.log("connect \(connectEndpoint) -> \(result.status) \(result.output.prefix(160))")
            let ok = result.output.contains("connected to") || result.output.contains("already connected")
            connected = ok
            if !ok {
                message = String(localized: "Handy nicht gekoppelt. Kopplungscode am Handy öffnen und hier eingeben.")
            } else if message == String(localized: "Handy nicht gekoppelt. Kopplungscode am Handy öffnen und hier eingeben.") {
                message = nil
            }
            if ok, streamCount > 0 { startSession() }
        }
    }

    // MARK: - Sound session

    private func startSession() {
        guard session == nil, connected, let connectEndpoint else { return }
        let keep = Defaults[.islandPhoneAudioOnPhone]
        let session = AudioSession(serial: connectEndpoint, keepOnPhone: keep)
        self.session = session
        session.onEnd = { [weak self] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.session === session else { return }
                    self.session = nil
                    self.playing = false
                    if let reason { self.message = reason }
                }
            }
        }
        session.onPlaying = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.playing = true; self?.message = nil } }
        }
        session.start()
    }

    private func stopSession() {
        session?.stop()
        session = nil
        playing = false
    }

    // MARK: - adb

    /// Written to the audio log, which "Diagnose kopieren" includes.
    nonisolated static func log(_ text: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { PhoneLink.shared.logAudio("adb: " + text) } }
    }

    nonisolated static var adbURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/adb")
    }

    nonisolated static var serverURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scrcpy-server.jar")
    }

    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: adbURL.path) && FileManager.default.fileExists(atPath: serverURL.path)
    }

    nonisolated static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // adb's own mDNS code crashes on current macOS; the app finds the phone itself.
        env["ADB_MDNS"] = "0"
        env["ADB_MDNS_AUTO_CONNECT"] = "0"
        return env
    }

    @discardableResult
    nonisolated static func adb(_ arguments: [String], timeout: TimeInterval = 20) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = adbURL
        process.arguments = ["-P", adbPort] + arguments
        process.environment = environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return (-2, "timeout")
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension PhoneAudio: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            resolving.append(service)
            service.resolve(withTimeout: 8)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated { removed(service) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated { resolved(sender) }
    }
}

// MARK: - One run of the sound stream

/// Starts the scrcpy server on the phone, reads its raw PCM stream and plays it.
private final class AudioSession: @unchecked Sendable {
    private let serial: String
    private let keepOnPhone: Bool
    /// The server reads it as a signed 31 bit hex number.
    private let scid = String(format: "%08x", UInt32.random(in: 1..<0x7FFF_FFFF))
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    private var socketFD: Int32 = -1
    private var forwardPort: String?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var pending = 0

    var onEnd: (String?) -> Void = { _ in }
    var onPlaying: () -> Void = {}

    init(serial: String, keepOnPhone: Bool) {
        self.serial = serial
        self.keepOnPhone = keepOnPhone
    }

    func start() {
        Thread.detachNewThread { [self] in run() }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = socketFD
        socketFD = -1
        let process = self.process
        let port = forwardPort
        lock.unlock()
        if fd >= 0 { close(fd) }
        process?.terminate()
        if player.engine != nil { player.stop() }
        if engine.isRunning { engine.stop() }
        if let port {
            DispatchQueue.global().async { _ = PhoneAudio.adb(["-s", self.serial, "forward", "--remove", "tcp:\(port)"], timeout: 5) }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        let adb = { (args: [String]) in PhoneAudio.adb(["-s", self.serial] + args, timeout: 20) }
        let remote = "/data/local/tmp/notchway-scrcpy-server.jar"
        let pushed = adb(["push", PhoneAudio.serverURL.path, remote])
        PhoneAudio.log("push -> \(pushed.status) \(pushed.output.prefix(160))")
        guard pushed.status == 0 else { return finish(String(localized: "Der Ton-Dienst konnte nicht auf das Handy kopiert werden.")) }

        let command = "CLASSPATH=\(remote) app_process / com.genymobile.scrcpy.Server \(PhoneAudio.serverVersion) "
            + "scid=\(scid) log_level=info video=false audio=true control=false audio_source=playback audio_codec=raw "
            + "audio_dup=\(keepOnPhone) tunnel_forward=true cleanup=false send_device_meta=false send_dummy_byte=false"
        let server = Process()
        server.executableURL = PhoneAudio.adbURL
        server.arguments = ["-P", PhoneAudio.adbPort, "-s", serial, "shell", command]
        server.environment = PhoneAudio.environment()
        let output = Pipe()
        server.standardOutput = output
        server.standardError = output
        do { try server.run() } catch { PhoneAudio.log("server start failed: \(error)"); return finish(error.localizedDescription) }
        lock.lock(); process = server; lock.unlock()
        var serverLog = ""
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { serverLog += String(decoding: chunk, as: UTF8.self) }
        }

        let forward = adb(["forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
        PhoneAudio.log("forward -> \(forward.status) \(forward.output.prefix(80))")
        guard forward.status == 0, let port = Int(forward.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return finish(String(localized: "Verbindung zum Ton-Dienst fehlgeschlagen."))
        }
        lock.lock(); forwardPort = String(port); lock.unlock()

        var header = [UInt8](repeating: 0, count: 4)
        var connected = false
        for _ in 0..<25 where !isStopped {
            let fd = Self.connectLocal(port: UInt16(port))
            if fd >= 0 {
                lock.lock(); socketFD = fd; lock.unlock()
                if Self.readExactly(fd, &header, 4) { connected = true; break }
                lock.lock(); socketFD = -1; lock.unlock()
                close(fd)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        PhoneAudio.log("socket connected=\(connected) header=\(header) server log: \(serverLog.prefix(300))")
        guard connected, !isStopped else { return finish(isStopped ? nil : String(localized: "Der Ton-Dienst auf dem Handy startet nicht. Läuft das Drahtlose Debugging noch?")) }
        // The stream starts with the codec: "raw" means plain 16 bit PCM, 48 kHz, two channels.
        guard header == [0x00, 0x72, 0x61, 0x77] else {
            return finish(String(localized: "Das Handy sendet den Ton in einem unbekannten Format."))
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return finish(error.localizedDescription) }
        player.play()
        PhoneAudio.log("playing")
        onPlaying()

        let fd = socketFD
        var packetHeader = [UInt8](repeating: 0, count: 12)
        var payload = [UInt8](repeating: 0, count: 1 << 16)
        while !isStopped, Self.readExactly(fd, &packetHeader, 12) {
            let size = Int(UInt32(packetHeader[8]) << 24 | UInt32(packetHeader[9]) << 16 | UInt32(packetHeader[10]) << 8 | UInt32(packetHeader[11]))
            if size > payload.count { payload = [UInt8](repeating: 0, count: size) }
            guard size >= 0, Self.readExactly(fd, &payload, size) else { break }
            schedule(payload, count: size, format: format)
        }
        finish(isStopped ? nil : String(localized: "Der Ton vom Handy wurde beendet."))
    }

    /// Plays one packet. When the Mac falls behind, packets are dropped so the sound does not lag.
    private func schedule(_ bytes: [UInt8], count: Int, format: AVAudioFormat) {
        let frames = count / 4
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1] else { return }
        lock.lock()
        let behind = pending > 24
        if !behind { pending += 1 }
        lock.unlock()
        if behind { return }
        bytes.withUnsafeBufferPointer { raw in
            raw.baseAddress!.withMemoryRebound(to: Int16.self, capacity: frames * 2) { samples in
                for index in 0..<frames {
                    left[index] = Float(Int16(littleEndian: samples[index * 2])) / 32768
                    right[index] = Float(Int16(littleEndian: samples[index * 2 + 1])) / 32768
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        player.scheduleBuffer(buffer) { [weak self] in
            self?.lock.lock()
            self?.pending -= 1
            self?.lock.unlock()
        }
    }

    private func finish(_ reason: String?) {
        PhoneAudio.log("session ended: \(reason ?? "stopped")")
        stop()
        onEnd(reason)
    }

    private static func connectLocal(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }

    private static func readExactly(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let got = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: done), count - done, 0) }
            if got <= 0 { return false }
            done += got
        }
        return true
    }
}
