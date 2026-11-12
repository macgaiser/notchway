//
//  PhoneView.swift
//  boringNotch
//
//  The "Handy" view: connection state, pairing and the phone's notifications.
//

import Defaults
import SwiftUI

struct PhoneView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var link = PhoneLink.shared
    @State private var replyingTo: PhoneNotification?
    @State private var replyText = ""
    @State private var showingApps = false
    @State private var appSearch = ""
    @ObservedObject private var streams = PhoneStreams.shared

    var body: some View {
        Group {
            if !link.daemonAvailable {
                hint(icon: "exclamationmark.triangle", text: "Der Handy-Dienst fehlt in dieser App-Version. Bitte mit island-build.sh bauen.")
            } else if !link.networkTrusted {
                untrustedNetwork
            } else if !link.status.paired {
                unpaired
            } else {
                HStack(alignment: .top, spacing: 12) {
                    device
                    Divider().overlay(Color.white.opacity(0.12))
                    notifications
                }
            }
        }
        .onAppear {
            IslandFocus.allowsKey = true
            link.evaluate()
        }
        .onDisappear {
            IslandFocus.allowsKey = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    // MARK: - States

    private func hint(icon: String, text: String) -> some View {
        IslandEmptyState(icon: icon, text: text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)
    }

    private var untrustedNetwork: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(link.network == nil ? "Kein Netzwerk erkannt" : "Dieses Netzwerk ist nicht als vertraut markiert")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
            Text("Der Handy-Dienst öffnet einen Netzwerk-Port und läuft deshalb nur in Netzwerken, denen du vertraust.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let network = link.network {
                Button("Diesem Netzwerk vertrauen · \(network.label)") {
                    link.trustCurrentNetwork()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unpaired: some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Noch kein Handy gekoppelt")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
            Text("Auf dem Handy Smart Connect öffnen, auf + tippen und „QR-Code scannen“ wählen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            pairButton(title: "Kopplungs-Code anzeigen")
            statusMessage
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pairButton(title: String) -> some View {
        Button(title) {
            Task {
                if let url = await link.newPairingCode() {
                    PairingWindow.shared.show(codeAt: url)
                    vm.close()
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let message = link.message {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    // MARK: - Connected device

    private var device: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "smartphone")
                    .foregroundStyle(link.status.connected ? .green : .secondary)
                Text(link.status.model ?? link.status.name ?? "Handy")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            if link.status.connected {
                HStack(spacing: 10) {
                    if let battery = link.status.battery {
                        Label("\(battery) %", systemImage: link.status.charging ? "battery.100.bolt" : batterySymbol(battery))
                    }
                    if let wifi = link.status.wifiSignal {
                        Label("\(wifi)", systemImage: "wifi")
                    }
                    if let cell = link.status.cellSignal {
                        Label("\(cell)", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            } else {
                Text("Nicht verbunden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            statusMessage
            HStack(spacing: 6) {
                if link.status.connected {
                    Button("Spiegeln") {
                        PhoneStreams.shared.startMirror()
                        vm.close()
                    }
                    .buttonStyle(.borderedProminent)
                    Button(showingApps ? "Mitteilungen" : "Apps") {
                        showingApps.toggle()
                        if showingApps { streams.requestApps() }
                    }
                } else {
                    Button("Verbinden") { Task { await link.connect() } }
                }
                if !link.status.connected { pairButton(title: "Koppeln …") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(width: 190, alignment: .leading)
        .contextMenu {
            Button("Verbindung trennen") { Task { await link.disconnect() } }
            Button("Neu koppeln …") {
                Task {
                    if let url = await link.newPairingCode() {
                        PairingWindow.shared.show(codeAt: url)
                        vm.close()
                    }
                }
            }
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }

    // MARK: - Notifications

    // MARK: - Apps

    private var filteredApps: [PhoneApp] {
        let query = appSearch.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? streams.apps : streams.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var appPicker: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("App suchen", text: $appSearch)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 9)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
                if let message = streams.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            if streams.apps.isEmpty {
                IslandEmptyState(icon: "square.grid.2x2", text: "Lade die Apps vom Handy …")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 4) {
                        ForEach(filteredApps) { app in
                            Button {
                                streams.start(app)
                                if streams.message == nil { vm.close() }
                            } label: {
                                VStack(spacing: 4) {
                                    PhoneAppIcon(app: app)
                                        .frame(width: 38, height: 38)
                                    Text(app.name)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: 66, height: 78, alignment: .top)
                                .padding(.top, 4)
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(IslandTileStyle())
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notifications: some View {
        if showingApps, link.status.connected {
            appPicker
        } else if let target = replyingTo {
            replyEditor(for: target)
        } else if link.status.notifications.isEmpty {
            IslandEmptyState(icon: "bell.slash", text: link.status.connected ? "Keine Benachrichtigungen" : "Verbinde das Handy, um Benachrichtigungen zu sehen")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(link.status.notifications) { notification in
                        row(for: notification)
                    }
                }
            }
        }
    }

    private func row(for notification: PhoneNotification) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(notification.title.isEmpty ? notification.app : notification.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !notification.title.isEmpty, notification.title != notification.app {
                        Text("· \(notification.app)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(notification.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if notification.replyable {
                Button {
                    replyText = ""
                    replyingTo = notification
                } label: {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Antworten")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
    }

    private func replyEditor(for notification: PhoneNotification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Antwort an \(notification.title.isEmpty ? notification.app : notification.title)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(notification.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField("Nachricht", text: $replyText)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                .onSubmit { send(to: notification) }
            HStack {
                statusMessage
                Spacer()
                Button("Abbrechen") { replyingTo = nil }
                Button("Senden") { send(to: notification) }
                    .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func send(to notification: PhoneNotification) {
        let text = replyText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            if await link.reply(to: notification, text: text) {
                replyingTo = nil
                replyText = ""
            }
        }
    }
}

/// Shows the pairing code large enough to scan with the phone.
@MainActor
final class PairingWindow: NSObject, NSWindowDelegate {
    static let shared = PairingWindow()
    private var window: NSWindow?

    func show(codeAt url: URL) {
        window?.close()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Handy koppeln"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PairingCodeView(image: NSImage(contentsOf: url)))
        window.center()
        window.delegate = self
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        let othersOpen = NSApp.windows.contains { $0 !== (notification.object as? NSWindow) && $0.isVisible && $0.styleMask.contains(.titled) }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

private struct PairingCodeView: View {
    let image: NSImage?
    @ObservedObject private var link = PhoneLink.shared

    var body: some View {
        VStack(spacing: 14) {
            if link.status.connected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Verbunden mit \(link.status.model ?? link.status.name ?? "dem Handy")")
                    .font(.title3.weight(.semibold))
                Text("Du kannst dieses Fenster schließen.")
                    .foregroundStyle(.secondary)
            } else {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 400, height: 400)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Text("Der Kopplungs-Code konnte nicht geladen werden.")
                        .foregroundStyle(.red)
                }
                Text("Smart Connect auf dem Handy öffnen, auf + tippen und „QR-Code scannen“ wählen. Der Code gilt 10 Minuten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 460, height: 540)
    }
}

/// Icon the daemon downloaded from the phone; a generic symbol until it is there.
private struct PhoneAppIcon: View {
    let app: PhoneApp

    var body: some View {
        if let image = NSImage(contentsOf: PhoneStreams.iconURL(for: app)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.1))
                .overlay(Image(systemName: "app.dashed").foregroundStyle(.secondary))
        }
    }
}
