//
//  PhoneStreams.swift
//  boringNotch
//
//  Phone screens on the Mac: the whole phone ("mirror") or single apps, each in its own window,
//  with mouse and keyboard input sent back.
//
//  The phone streams standard WebRTC video; signalling travels as JSON over the daemon's control
//  socket (services 1, 15, 16 and 17 of the Smart Connect protocol, see the daemon's
//  docs/protocol/mirroring.md and app-streaming.md). A WKWebView per window answers the phone's
//  offer and decodes the video.
//

import AppKit
import Defaults
import SwiftUI
import WebKit

extension Defaults.Keys {
    /// On: apps open on a wide, tablet-sized display. Off: in the phone's own portrait shape.
    static let islandPhoneAppsLandscape = Key<Bool>("islandPhoneAppsLandscape", default: true)
    /// Apps pinned to the left of the app grid, in the order the user arranged them.
    static let islandPhoneFavorites = Key<[PhoneApp]>("islandPhoneFavorites", default: [])
}

struct PhoneApp: Identifiable, Hashable, Codable, Defaults.Serializable {
    let pkg: String
    let name: String
    let userId: Int
    let cmp: String
    let iconName: String

    var id: String { "\(userId)/\(pkg)/\(cmp)" }
}

/// One stream and its window.
@MainActor
final class PhoneStreamWindow: NSObject, ObservableObject, WKScriptMessageHandler, NSWindowDelegate {
    enum State: Equatable {
        case starting
        case streaming
        case failed(String)
    }

    static let mirrorPackage = "mirror"

    let pkg: String
    let title: String
    @Published var state: State = .starting

    /// 64-bit and never handed to JavaScript, where it would lose precision.
    var sessionID: Int64?
    var displayID: Int?
    var capabilityRequested = false
    let createdAt = Date()

    private(set) var window: NSWindow?
    private var webView: WKWebView?
    private var pageReady = false
    private var pendingOffer: String?
    private unowned let host: PhoneStreams

    var isMirror: Bool { pkg == Self.mirrorPackage }

    init(pkg: String, title: String, host: PhoneStreams) {
        self.pkg = pkg
        self.title = title
        self.host = host
        super.init()
        open()
    }

    private func open() {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "mirror")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 390, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: PhoneStreamContent(stream: self, webView: webView))
        window.center()
        let offset = CGFloat(host.openCount % 6) * 28
        window.setFrameOrigin(CGPoint(x: window.frame.minX + offset, y: window.frame.minY - offset))
        window.delegate = self
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        webView.loadHTMLString(PhoneStreams.page, baseURL: nil)
    }

    func raise() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the window without telling the phone (it already knows, or was told).
    func dismantle() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mirror")
        webView = nil
        if let window {
            self.window = nil
            window.delegate = nil
            window.close()
        }
    }

    /// Fits the window to the picture, keeping its place on screen.
    private func fit(toVideo size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let bar = PhoneStreamContent.barHeight
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let scale = min((visible.height * 0.86 - bar) / size.height, (visible.width * 0.8) / size.width, 1)
        let content = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded() + bar)
        let top = window.frame.maxY
        window.setContentSize(content)
        window.setFrameTopLeftPoint(CGPoint(x: window.frame.minX, y: top))
    }

    // MARK: Page bridge

    func deliver(offer: String) {
        if pageReady { call("acceptOffer", offer) } else { pendingOffer = offer }
    }

    func add(candidate: String) {
        call("addCandidate", candidate)
    }

    /// Calls a function of the page with one string argument, safely quoted.
    private func call(_ function: String, _ argument: String) {
        guard let quoted = try? JSONSerialization.data(withJSONObject: [argument]),
              let list = String(data: quoted, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("\(function)(...\(list))")
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }
            switch body["type"] as? String {
            case "ready":
                self.pageReady = true
                if let offer = self.pendingOffer {
                    self.pendingOffer = nil
                    self.call("acceptOffer", offer)
                }
            case "size":
                if let width = body["width"] as? Double, let height = body["height"] as? Double {
                    self.fit(toVideo: CGSize(width: width, height: height))
                }
            default:
                self.host.pageMessage(body, from: self)
            }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard self.window != nil else { return }
            self.window = nil
            self.host.userClosed(self)
        }
    }
}

@MainActor
final class PhoneStreams: ObservableObject {
    static let shared = PhoneStreams()

    @Published private(set) var apps: [PhoneApp] = []
    @Published var message: String?

    private var streams: [PhoneStreamWindow] = [] {
        didSet { PhoneAudio.shared.streamsChanged(count: streams.count) }
    }
    private var watching = false
    private var watchGeneration = 0
    private var heartbeat: Timer?
    /// Must stay the same for as long as the app runs, or the phone closes every stream.
    private let instanceID = Int64(Date().timeIntervalSince1970 * 1000)

    private var link: PhoneLink { PhoneLink.shared }
    var openCount: Int { streams.count }

    // MARK: - Starting

    /// The whole phone screen.
    func startMirror() {
        if let existing = streams.first(where: \.isMirror) {
            existing.raise()
            return
        }
        guard begin() else { return }
        streams.append(PhoneStreamWindow(pkg: PhoneStreamWindow.mirrorPackage, title: link.status.model ?? String(localized: "Handy"), host: self))
        send(service: 1, ["ver": "1.0.0", "cmd": 1, "view": 1, "reply": 0, "drawerMode": false])
        armTimeout()
    }

    /// One app in its own window, running on its own virtual display on the phone.
    func start(_ app: PhoneApp) {
        if let existing = streams.first(where: { $0.pkg == app.pkg }) {
            existing.raise()
            return
        }
        guard begin() else { return }
        streams.append(PhoneStreamWindow(pkg: app.pkg, title: app.name, host: self))
        // source 1 marks a start the phone itself asked for, which it accepts without the
        // "allow" prompt. Starts from the Mac normally carry 0 and get the prompt every time.
        send(service: 15, ["ver": "1", "cmd": 1, "data": appStartData(pkg: app.pkg, cmp: app.cmp, userId: app.userId, source: 1)])
        armTimeout()
    }

    /// The phone handles one start at a time.
    private func begin() -> Bool {
        guard link.status.connected else {
            message = String(localized: "Das Handy ist nicht verbunden.")
            return false
        }
        if streams.contains(where: { $0.state == .starting && Date().timeIntervalSince($0.createdAt) < 20 }) {
            message = String(localized: "Es startet gerade schon ein Fenster. Bitte einen Moment warten.")
            return false
        }
        message = nil
        ensureWatching()
        return true
    }

    private func armTimeout() {
        guard let stream = streams.last else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak stream] in
            Task { @MainActor in
                guard let stream, stream.state == .starting else { return }
                stream.state = .failed(String(localized: "Das Handy hat nicht geantwortet. Ist es entsperrt?"))
            }
        }
    }

    private func peerStartData(pkg: String, cmp: Any?, userId: Int, source: Int) -> [String: Any] {
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
        // Booleans must be real booleans; the phone silently drops the request otherwise.
        return [
            "pkg": pkg, "cmp": cmp ?? NSNull(), "shortcutId": NSNull(),
            "userId": userId, "source": source,
            "width": 1920, "height": 1080,
            "phyWidth": 344, "phyHeight": 194,
            "displayWidth": Int(size.width), "displayHeight": Int(size.height),
            "displayDensity": 160, "displayScale": 1.0,
            "align": 0,
            "instanceId": instanceID,
            "port": 0,
            "supportedMediaFormat": 1,
            "supportWebRTC": 1,
            "supportCustomDisplay": false,
            "vrSupportUnfolded": false,
        ]
    }

    /// Start data for an app. In landscape mode the phone creates a display of exactly the size
    /// named here instead of one shaped like its own screen.
    private func appStartData(pkg: String, cmp: Any?, userId: Int, source: Int) -> [String: Any] {
        var data = peerStartData(pkg: pkg, cmp: cmp, userId: userId, source: source)
        if Defaults[.islandPhoneAppsLandscape] {
            data["supportCustomDisplay"] = true
            data["displayWidth"] = 1600
            data["displayHeight"] = 900
            data["displayDensity"] = 160
        }
        return data
    }

    // MARK: - App list

    /// Asks the phone for its app list; the answer arrives through the watch connection.
    func requestApps() {
        guard link.status.connected else { return }
        ensureWatching()
        send(service: 17, ["ver": "1", "cmd": 2])
    }

    /// Icons are downloaded by the daemon into the app's cache folder.
    static func iconURL(for app: PhoneApp) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartConnect/app-icons", isDirectory: true)
            .appendingPathComponent(app.iconName)
    }

    // MARK: - Closing

    func userClosed(_ stream: PhoneStreamWindow) {
        if let sessionID = stream.sessionID {
            send(service: 15, ["ver": "1", "cmd": 7, "data": ["sessionId": sessionID, "error": 0]])
        }
        if stream.isMirror {
            send(service: 1, ["ver": "1.0.0", "cmd": 5])
        }
        remove(stream)
    }

    private func remove(_ stream: PhoneStreamWindow) {
        stream.dismantle()
        streams.removeAll { $0 === stream }
        if streams.isEmpty {
            heartbeat?.invalidate()
            heartbeat = nil
            let othersOpen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            if !othersOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// The service stopped or the phone went away: nothing is left to stream.
    func closeAll() {
        for stream in streams { stream.dismantle() }
        streams = []
        heartbeat?.invalidate()
        heartbeat = nil
        watchGeneration += 1
        watching = false
    }

    // MARK: - Control socket

    private func send(service: Int, _ data: [String: Any]) {
        link.send(service: service, data: data)
    }

    /// One long-lived connection on which the daemon relays what the phone says on our services.
    private func ensureWatching() {
        guard !watching else { return }
        watching = true
        watchGeneration += 1
        let generation = watchGeneration
        let path = link.controlSocketPath
        let thread = Thread { [weak self] in
            while true {
                let active = DispatchQueue.main.sync { MainActor.assumeIsolated { self?.watchGeneration == generation } }
                guard active else { return }
                if let fd = LineSocket.open(path) {
                    if LineSocket.write(#"{"cmd":"watch","services":[1,15,16,17]}"#, to: fd) {
                        LineSocket.readLines(from: fd) { line in
                            guard let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                                  let service = frame["service"] as? Int,
                                  let data = frame["data"] as? [String: Any] else { return true }
                            return DispatchQueue.main.sync {
                                MainActor.assumeIsolated {
                                    guard let self, self.watchGeneration == generation else { return false }
                                    self.handle(service: service, data)
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
        thread.name = "island.phone.streams"
        thread.start()
    }

    private func stream(session: Any?) -> PhoneStreamWindow? {
        guard let id = (session as? NSNumber)?.int64Value else { return nil }
        return streams.first { $0.sessionID == id }
    }

    private func handle(service: Int, _ message: [String: Any]) {
        let command = message["cmd"] as? Int
        let data = message["data"] as? [String: Any] ?? [:]

        // Research on phone audio: what does the phone say about sound, and does its offer carry audio?
        if service == 15, command == 21 {
            let text = (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            link.logAudio("svc 15 cmd 21: \(text.prefix(700))")
        }
        if service == 15, command == 3, let offer = data["webRTCData"] as? String, offer.contains("sdp") {
            let sdp = ((try? JSONSerialization.jsonObject(with: Data(offer.utf8))) as? [String: Any])?["sdp"] as? String ?? ""
            let lines = sdp.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter {
                $0.hasPrefix("m=") || $0.hasPrefix("a=sendrecv") || $0.hasPrefix("a=recvonly") || $0.hasPrefix("a=sendonly")
                    || $0.hasPrefix("a=inactive") || $0.hasPrefix("a=mid") || $0.hasPrefix("a=group") || $0.contains("opus")
            }
            link.logAudio("offer pkg=\(data["pkg"] as? String ?? "?"): \(lines.joined(separator: " | "))")
        }

        switch (service, command) {
        case (17, 1):
            let listed = (message["apps"] as? [[String: Any]] ?? []) + (message["wpApps"] as? [[String: Any]] ?? [])
            apps = listed.compactMap { entry in
                guard let pkg = entry["pkg"] as? String else { return nil }
                return PhoneApp(
                    pkg: pkg, name: entry["name"] as? String ?? pkg, userId: entry["userId"] as? Int ?? 0,
                    cmp: entry["cmp"] as? String ?? "", iconName: entry["iconName"] as? String ?? ""
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        case (1, 11):
            if let mirror = streams.first(where: \.isMirror) {
                mirror.state = .failed(Self.errorText(message["errorCode"] as? Int))
            }
        case (1, 5):
            if let mirror = streams.first(where: \.isMirror) { remove(mirror) }

        case (15, 2):
            // The phone sets up a stream: for the mirror we asked for, or one started on the phone.
            let pkg = data["pkg"] as? String ?? PhoneStreamWindow.mirrorPackage
            if !streams.contains(where: { $0.pkg == pkg && $0.sessionID == nil }) {
                guard !streams.contains(where: { $0.pkg == pkg }) else { return }
                let title = data["pkgName"] as? String ?? apps.first { $0.pkg == pkg }?.name ?? pkg
                streams.append(PhoneStreamWindow(pkg: pkg, title: title, host: self))
                armTimeout()
            }
            let userId = data["userId"] as? Int ?? 0
            let source = data["source"] as? Int ?? 0
            var reply = pkg == PhoneStreamWindow.mirrorPackage
                ? peerStartData(pkg: pkg, cmp: data["cmp"], userId: userId, source: source)
                : appStartData(pkg: pkg, cmp: data["cmp"], userId: userId, source: source)
            if let shortcut = data["shortcutId"] { reply["shortcutId"] = shortcut }
            send(service: 15, ["ver": "1", "cmd": 1, "data": reply])

        case (15, 3):
            let pkg = data["pkg"] as? String
            // The first cmd 3 names the session; match it to the window still waiting for that app.
            let target = stream(session: data["sessionId"])
                ?? streams.first { $0.sessionID == nil && ($0.pkg == pkg || pkg == nil) }
                ?? streams.first { $0.sessionID == nil }
            guard let target else { return }
            if let id = (data["sessionId"] as? NSNumber)?.int64Value { target.sessionID = id }
            if let display = data["displayId"] as? Int, display >= 0 { useDisplay(display, for: target) }
            if let offer = data["webRTCData"] as? String, !offer.isEmpty {
                target.deliver(offer: offer)
                startHeartbeat()
            }

        case (15, 20):
            if let candidate = data["data"] as? String { stream(session: data["sessionId"])?.add(candidate: candidate) }

        case (15, 8):
            guard let target = stream(session: data["sessionId"])
                    ?? streams.first(where: { $0.sessionID == nil && $0.pkg == data["pkg"] as? String }) else { return }
            switch data["state"] as? Int {
            case 1:
                if let display = data["displayId"] as? Int, display >= 0 { useDisplay(display, for: target) }
                target.state = .streaming
            case 0:
                if let reason = data["reason"] as? Int, target.state == .starting {
                    target.sessionID = nil
                    target.state = .failed(Self.errorText(reason))
                } else {
                    remove(target)
                }
            default:
                break
            }

        case (15, 12), (15, 14):
            // The app already has a window (or was merged into one): bring it forward.
            if let display = data["displayId"] as? Int {
                streams.first { $0.displayID == display }?.raise()
            }
            // A window opened for an app that turned out to be running already is not needed.
            for waiting in streams where waiting.sessionID == nil && !waiting.isMirror && waiting.state == .starting {
                if Date().timeIntervalSince(waiting.createdAt) < 20 { remove(waiting) }
            }

        default:
            break
        }
    }

    private func useDisplay(_ display: Int, for stream: PhoneStreamWindow) {
        stream.displayID = display
        guard !stream.capabilityRequested else { return }
        stream.capabilityRequested = true
        // Creates the virtual keyboard and mouse for this display; required before any input.
        send(service: 16, ["cmd": 1, "data": ["ver": 1, "displayId": display, "caps": 3], "messageId": 0, "instanceId": 0])
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        // One heartbeat covers every stream; the phone drops them all after 35 s of silence.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(service: 15, ["ver": "1", "cmd": 9]) }
        }
    }

    private static func errorText(_ code: Int?) -> String {
        switch code {
        case 145: String(localized: "Am Handy abgelehnt oder nicht erlaubt.")
        case 147: String(localized: "Die Bestätigung am Handy kam nicht rechtzeitig.")
        case 293, 3858: String(localized: "Das Handy überträgt bereits an ein anderes Gerät.")
        case 296, 3859: String(localized: "Das Handy hat keinen freien Video-Encoder. Schließe ein anderes Handy-Fenster.")
        case 3861: String(localized: "Ein anderes Fenster hat den Video-Encoder übernommen.")
        case 3860: String(localized: "Diese App gibt es auf dem Handy nicht.")
        case 3857: String(localized: "Die App wurde am Handy beendet.")
        case 305: String(localized: "Die Übertragung ist am Handy deaktiviert oder eine andere läuft bereits.")
        case 306: String(localized: "Die Übertragung ist auf dem Handy durch eine Richtlinie gesperrt.")
        default: String(localized: "Das Handy hat die Übertragung beendet") + (code.map { String(localized: " (Code \($0)).") } ?? ".")
        }
    }

    // MARK: - Messages from a window's page

    func pageMessage(_ body: [String: Any], from stream: PhoneStreamWindow) {
        switch body["type"] as? String {
        case "answer":
            guard let sessionID = stream.sessionID, let sdp = body["sdp"] as? String,
                  let answer = jsonString(["type": "answer", "sdp": sdp]) else { return }
            send(service: 15, ["ver": "1", "cmd": 4, "data": [
                "sessionId": sessionID, "error": 0, "isWebRTC": 1, "resize": 0, "userId": 0, "webRTCData": answer,
            ] as [String: Any]])

        case "candidate":
            guard let sessionID = stream.sessionID, var candidate = body["candidate"] as? String, !candidate.isEmpty else { return }
            // WebKit hides the local address behind a random ".local" name the phone cannot resolve.
            // The phone reached us on pcAddress, so that is the address to offer.
            if let address = link.status.pcAddress {
                candidate = candidate.replacingOccurrences(of: #"[0-9a-fA-F-]{36}\.local"#, with: address, options: .regularExpression)
            }
            guard !candidate.contains(".local"),
                  let payload = jsonString([
                      "type": "candidate",
                      "label": body["index"] as? Int ?? 0,
                      "id": body["mid"] as? String ?? "0",
                      "candidate": candidate,
                  ]) else { return }
            send(service: 15, ["ver": "1", "cmd": 20, "data": [
                "sessionId": sessionID, "type": "candidate", "pkg": stream.pkg, "userId": 0, "data": payload,
            ] as [String: Any]])

        case "move":
            input(4, ["x": body["x"] as? Int ?? 0, "y": body["y"] as? Int ?? 0], on: stream)
        case "button":
            input(5, [
                "key": body["key"] as? Int ?? 1,
                "x": body["x"] as? Int ?? 0, "y": body["y"] as? Int ?? 0,
                "down": body["down"] as? Bool ?? false,
            ], on: stream)
        case "key":
            key(body["code"] as? Int ?? 0, flags: body["flags"] as? Int ?? 0, down: body["down"] as? Bool ?? false, on: stream)
        case "text":
            if let text = body["text"] as? String { input(7, ["text": text], on: stream) }

        case "error":
            stream.state = .failed(String(localized: "Die Bildübertragung kam nicht zustande: \(body["message"] as? String ?? "unbekannter Fehler")"))

        default:
            break
        }
    }

    private func jsonString(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func input(_ command: Int, _ fields: [String: Any], on stream: PhoneStreamWindow) {
        guard let displayID = stream.displayID, stream.state == .streaming else { return }
        var data = fields
        data["displayId"] = displayID
        send(service: 16, ["cmd": command, "data": data, "messageId": 0, "instanceId": 0])
    }

    private func key(_ code: Int, flags: Int, down: Bool, on stream: PhoneStreamWindow) {
        input(3, ["flags": flags, "key": code, "down": down, "metaState": 0], on: stream)
    }

    /// Android's own keys (Back 4, Home 3, Recents 187), sent as key code with the 0x1000 flag.
    func pressAndroidKey(_ keyCode: Int, on stream: PhoneStreamWindow) {
        key(keyCode, flags: 0x1000, down: true, on: stream)
        key(keyCode, flags: 0x1000, down: false, on: stream)
    }

    // MARK: - Page

    /// Answers the phone's WebRTC offer, shows the video and reports pointer and key events.
    static let page = #"""
    <!doctype html>
    <html><head><meta charset="utf-8">
    <style>
      html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
      video { width: 100%; height: 100%; object-fit: contain; display: block; outline: none; cursor: default; }
    </style></head>
    <body><video id="v" autoplay muted playsinline tabindex="0"></video>
    <script>
      const post = (m) => window.webkit.messageHandlers.mirror.postMessage(m);
      const video = document.getElementById('v');
      let pc = null;
      let queued = [];

      async function acceptOffer(raw) {
        try {
          const offer = JSON.parse(raw);
          if (pc) { pc.close(); }
          pc = new RTCPeerConnection({ iceServers: [], bundlePolicy: 'max-bundle', rtcpMuxPolicy: 'require' });
          pc.ontrack = (e) => { video.srcObject = e.streams[0] || new MediaStream([e.track]); video.play().catch(() => {}); };
          pc.onicecandidate = (e) => {
            if (e.candidate && e.candidate.candidate) {
              post({ type: 'candidate', candidate: e.candidate.candidate, mid: e.candidate.sdpMid, index: e.candidate.sdpMLineIndex });
            }
          };
          pc.onconnectionstatechange = () => { if (pc.connectionState === 'failed') post({ type: 'error', message: 'Verbindung fehlgeschlagen' }); };
          await pc.setRemoteDescription({ type: 'offer', sdp: offer.sdp });
          const answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          post({ type: 'answer', sdp: pc.localDescription.sdp });
          for (const c of queued) { await addCandidate(c); }
          queued = [];
        } catch (err) {
          post({ type: 'error', message: String(err) });
        }
      }

      async function addCandidate(raw) {
        if (!pc || !pc.remoteDescription) { queued.push(raw); return; }
        try {
          const c = JSON.parse(raw);
          await pc.addIceCandidate({ candidate: c.candidate, sdpMid: String(c.id), sdpMLineIndex: c.label });
        } catch (err) { /* a candidate we cannot use is not fatal */ }
      }

      video.addEventListener('resize', () => post({ type: 'size', width: video.videoWidth, height: video.videoHeight }));

      // Pointer position in pixels of the video frame, which is what the phone expects.
      function point(e) {
        const r = video.getBoundingClientRect();
        const vw = video.videoWidth, vh = video.videoHeight;
        if (!vw || !vh) return null;
        const scale = Math.min(r.width / vw, r.height / vh);
        const x = (e.clientX - r.left - (r.width - vw * scale) / 2) / scale;
        const y = (e.clientY - r.top - (r.height - vh * scale) / 2) / scale;
        return { x: Math.round(Math.max(0, Math.min(vw - 1, x))), y: Math.round(Math.max(0, Math.min(vh - 1, y))) };
      }

      let lastMove = 0;
      video.addEventListener('mousemove', (e) => {
        const now = performance.now();
        if (now - lastMove < 12) return;
        lastMove = now;
        const p = point(e); if (p) post({ type: 'move', x: p.x, y: p.y });
      });
      const buttons = { 0: 1, 1: 2, 2: 3 };
      for (const [name, down] of [['mousedown', true], ['mouseup', false]]) {
        video.addEventListener(name, (e) => {
          video.focus();
          const p = point(e); if (!p) return;
          post({ type: 'move', x: p.x, y: p.y });
          post({ type: 'button', key: buttons[e.button] || 1, x: p.x, y: p.y, down });
          e.preventDefault();
        });
      }
      video.addEventListener('contextmenu', (e) => e.preventDefault());

      // One wheel message is one notch on the phone; trackpads send many tiny deltas.
      let wheel = 0;
      video.addEventListener('wheel', (e) => {
        e.preventDefault();
        const p = point(e); if (!p) return;
        wheel += e.deltaY;
        while (Math.abs(wheel) >= 30) {
          const down = wheel > 0;
          post({ type: 'button', key: 4, x: p.x, y: p.y, down });
          wheel += down ? -30 : 30;
        }
      }, { passive: false });

      // Special keys as PC scancodes (0x100 marks the extended ones); everything printable as text,
      // so umlauts and other layouts arrive as typed.
      const keys = {
        Enter: [28, 0], Backspace: [14, 0], Tab: [15, 0], Escape: [1, 0],
        ArrowUp: [72, 0x100], ArrowDown: [80, 0x100], ArrowLeft: [75, 0x100], ArrowRight: [77, 0x100],
        Delete: [83, 0x100], Home: [71, 0x100], End: [79, 0x100], PageUp: [73, 0x100], PageDown: [81, 0x100]
      };
      for (const [name, down] of [['keydown', true], ['keyup', false]]) {
        window.addEventListener(name, (e) => {
          if (e.metaKey) return;
          const special = keys[e.key];
          if (special) {
            post({ type: 'key', code: special[0], flags: special[1], down });
          } else if (down && e.key.length === 1 && !e.ctrlKey) {
            post({ type: 'text', text: e.key });
          } else {
            return;
          }
          e.preventDefault();
        });
      }

      post({ type: 'ready' });
    </script></body></html>
    """#
}

private struct StreamWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PhoneStreamContent: View {
    static let barHeight: CGFloat = 40

    @ObservedObject var stream: PhoneStreamWindow
    let webView: WKWebView

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                StreamWebView(webView: webView)
                if stream.state == .starting {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text(stream.isMirror ? String(localized: "Verbinde mit dem Handy …") : String(localized: "Starte \(stream.title) …"))
                        Text(String(localized: "Falls das Handy gesperrt ist, bitte entsperren."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                } else if case .failed(let text) = stream.state {
                    Text(text)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            HStack(spacing: 28) {
                navigation(String(localized: "Zurück"), icon: "chevron.backward", key: 4)
                // Home and Recents belong to the whole phone, not to a single app's window.
                if stream.isMirror {
                    navigation(String(localized: "Startbildschirm"), icon: "circle", key: 3)
                    navigation(String(localized: "Letzte Apps"), icon: "square", key: 187)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.barHeight)
            .background(Color.black)
        }
    }

    private func navigation(_ title: String, icon: String, key: Int) -> some View {
        Button {
            PhoneStreams.shared.pressAndroidKey(key, on: stream)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLabel(title, edge: .top)
        .disabled(stream.state != .streaming)
    }
}
