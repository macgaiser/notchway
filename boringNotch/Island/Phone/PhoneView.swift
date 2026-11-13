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
    @ObservedObject private var files = PhoneFiles.shared
    @Default(.islandPhoneAppsLandscape) private var appsLandscape
    @Default(.islandPhoneFavorites) private var favorites
    /// App being dragged between the grid and the favorites, and where the pointer is.
    @State private var dragged: PhoneApp?
    @State private var dragLocation: CGPoint = .zero
    @State private var favoritesFrame: CGRect = .zero

    private static let dragSpace = "phone"
    private static let maxFavorites = 12
    private static let favoriteColumns = 3
    private static let favoriteTileHeight: CGFloat = 64
    private static let favoriteSpacing: CGFloat = 4

    var body: some View {
        Group {
            if !link.daemonAvailable {
                hint(icon: "exclamationmark.triangle", text: String(localized: "Der Handy-Dienst fehlt in dieser App-Version. Bitte mit island-build.sh bauen."))
            } else if !link.networkTrusted {
                untrustedNetwork
            } else if !link.status.paired {
                unpaired
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Keeps its normal height when the island grows for the app grid.
                        device
                            .frame(height: showingApps ? 122 : nil, alignment: .top)
                        if showingApps, link.status.connected {
                            favoritesArea
                        }
                    }
                    .frame(width: 190)
                    Divider().overlay(Color.white.opacity(0.12))
                    notifications
                }
                .coordinateSpace(name: Self.dragSpace)
                .overlay {
                    if let dragged {
                        PhoneAppIcon(app: dragged)
                            .frame(width: 46, height: 46)
                            .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
                            .position(dragLocation)
                            .allowsHitTesting(false)
                    }
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
            vm.setIslandExpanded(false)
        }
        .onChange(of: showingApps) { _, showing in
            vm.setIslandExpanded(showing && link.status.connected)
        }
        .onChange(of: link.status.connected) { _, connected in
            if !connected { showingApps = false }
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
            Text(link.network == nil ? String(localized: "Kein Netzwerk erkannt") : String(localized: "Dieses Netzwerk ist nicht als vertraut markiert"))
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
            Text(String(localized: "Der Handy-Dienst öffnet einen Netzwerk-Port und läuft deshalb nur in Netzwerken, denen du vertraust."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let network = link.network {
                Button(String(localized: "Diesem Netzwerk vertrauen · \(network.label)")) {
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
            Text(String(localized: "Noch kein Handy gekoppelt"))
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
            Text(String(localized: "Auf dem Handy Smart Connect öffnen, auf + tippen und „QR-Code scannen“ wählen."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            pairButton(title: String(localized: "Kopplungs-Code anzeigen"))
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
                Text(link.status.model ?? link.status.name ?? String(localized: "Handy"))
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
                .overlay(alignment: .leading) {
                    // A running transfer takes the place of the status line.
                    if let activity = files.activity {
                        Text(activity)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black)
                    }
                }
            } else {
                Text(link.message ?? String(localized: "Nicht verbunden"))
                    .font(.caption)
                    .foregroundStyle(link.message == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }

            // The two main actions fill the rest of the column.
            HStack(spacing: 6) {
                if link.status.connected {
                    actionTile(String(localized: "Spiegeln"), icon: "rectangle.on.rectangle", highlighted: false) {
                        PhoneStreams.shared.startMirror()
                        vm.close()
                    }
                    actionTile(showingApps ? String(localized: "Mitteilungen") : String(localized: "Apps"), icon: showingApps ? "bell.fill" : "square.grid.2x2.fill", highlighted: showingApps) {
                        showingApps.toggle()
                        if showingApps { streams.requestApps() }
                    }
                } else {
                    actionTile(String(localized: "Verbinden"), icon: "link", highlighted: false) {
                        Task { await link.connect() }
                    }
                    actionTile(String(localized: "Koppeln"), icon: "qrcode", highlighted: false) {
                        Task {
                            if let url = await link.newPairingCode() {
                                PairingWindow.shared.show(codeAt: url)
                                vm.close()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 190, alignment: .leading)
        .contextMenu {
            Button(String(localized: "Verbindung trennen")) { Task { await link.disconnect() } }
            Button(String(localized: "Neu koppeln …")) {
                Task {
                    if let url = await link.newPairingCode() {
                        PairingWindow.shared.show(codeAt: url)
                        vm.close()
                    }
                }
            }
        }
    }

    private func actionTile(_ title: String, icon: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(height: 24)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(highlighted ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(IslandTileStyle())
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

    /// The grid on the right: everything that is not a favorite.
    private var filteredApps: [PhoneApp] {
        let pinned = Set(favorites.map(\.id))
        let query = appSearch.trimmingCharacters(in: .whitespaces)
        return streams.apps.filter { app in
            !pinned.contains(app.id) && (query.isEmpty || app.name.localizedCaseInsensitiveContains(query))
        }
    }

    private func launch(_ app: PhoneApp) {
        streams.start(app)
        if streams.message == nil { vm.close() }
    }

    /// A tile that starts the app on click and can be dragged between grid and favorites.
    /// The drag is handled here instead of by system drag and drop, which the island
    /// would take for a file heading to the shelf.
    private func appTile(_ app: PhoneApp, iconSize: CGFloat, height: CGFloat, lines: Int) -> some View {
        let isFavorite = favorites.contains { $0.id == app.id }
        return PhoneAppTile(app: app, iconSize: iconSize, height: height, lines: lines)
            .opacity(dragged?.id == app.id ? 0.25 : 1)
            .onTapGesture { launch(app) }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.dragSpace))
                    .onChanged { value in
                        dragged = app
                        dragLocation = value.location
                    }
                    .onEnded { value in
                        drop(app, at: value.location)
                        dragged = nil
                    }
            )
            .contextMenu {
                if isFavorite {
                    Button(String(localized: "Aus Favoriten entfernen")) { favorites.removeAll { $0.id == app.id } }
                } else {
                    Button(String(localized: "Zu Favoriten hinzufügen")) { pin(app, at: favorites.count) }
                        .disabled(favorites.count >= Self.maxFavorites)
                }
            }
    }

    private func pin(_ app: PhoneApp, at index: Int) {
        var list = favorites
        let wasPinned = list.contains { $0.id == app.id }
        guard wasPinned || list.count < Self.maxFavorites else { return }
        list.removeAll { $0.id == app.id }
        list.insert(app, at: min(max(0, index), list.count))
        withAnimation(.smooth(duration: 0.25)) { favorites = list }
    }

    private func drop(_ app: PhoneApp, at point: CGPoint) {
        if favoritesFrame.contains(point) {
            pin(app, at: favoriteIndex(at: point))
        } else if point.x > favoritesFrame.maxX, favorites.contains(where: { $0.id == app.id }) {
            // Dragged back onto the grid.
            withAnimation(.smooth(duration: 0.25)) { favorites.removeAll { $0.id == app.id } }
        }
    }

    /// Position in the favorites grid that lies under the pointer.
    private func favoriteIndex(at point: CGPoint) -> Int {
        let spacing = Self.favoriteSpacing
        let cellWidth = (favoritesFrame.width - 2 * spacing + spacing) / CGFloat(Self.favoriteColumns)
        let column = Int((point.x - favoritesFrame.minX - spacing) / cellWidth)
        let row = Int((point.y - favoritesFrame.minY - spacing) / (Self.favoriteTileHeight + spacing))
        return max(0, row) * Self.favoriteColumns + min(max(0, column), Self.favoriteColumns - 1)
    }

    private var favoritesArea: some View {
        let targeted = dragged != nil && favoritesFrame.contains(dragLocation)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(localized: "Favoriten"))
                Spacer()
                if !favorites.isEmpty {
                    Text("\(favorites.count)/\(Self.maxFavorites)")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(targeted ? 0.1 : 0.04))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.08), style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: favorites.isEmpty && !targeted ? [4, 4] : []))
                if favorites.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "star")
                            .font(.title3)
                        Text(String(localized: "Apps von rechts hierher ziehen"))
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.favoriteSpacing), count: Self.favoriteColumns), spacing: Self.favoriteSpacing) {
                        ForEach(favorites) { app in
                            appTile(app, iconSize: 36, height: Self.favoriteTileHeight, lines: 1)
                        }
                    }
                    .padding(Self.favoriteSpacing)
                }
            }
            .frame(maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.dragSpace))
            } action: { frame in
                favoritesFrame = frame
            }
        }
    }

    private var appPicker: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField(String(localized: "App suchen"), text: $appSearch)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 9)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
                Button {
                    appsLandscape.toggle()
                } label: {
                    Image(systemName: appsLandscape ? "rectangle" : "rectangle.portrait")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(appsLandscape ? String(localized: "Apps öffnen im Querformat (Tablet). Klicken für Hochformat.") : String(localized: "Apps öffnen im Hochformat (Handy). Klicken für Querformat."))
                if let message = streams.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            if streams.apps.isEmpty {
                IslandEmptyState(icon: "square.grid.2x2", text: String(localized: "Lade die Apps vom Handy …"))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                        ForEach(filteredApps) { app in
                            appTile(app, iconSize: 42, height: 80, lines: 2)
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
            IslandEmptyState(icon: "bell.slash", text: link.status.connected ? String(localized: "Keine Benachrichtigungen") : String(localized: "Verbinde das Handy, um Benachrichtigungen zu sehen"))
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
                .help(String(localized: "Antworten"))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
    }

    private func replyEditor(for notification: PhoneNotification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Antwort an \(notification.title.isEmpty ? notification.app : notification.title)"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(notification.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField(String(localized: "Nachricht"), text: $replyText)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                .onSubmit { send(to: notification) }
            HStack {
                statusMessage
                Spacer()
                Button(String(localized: "Abbrechen")) { replyingTo = nil }
                Button(String(localized: "Senden")) { send(to: notification) }
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
        window.title = String(localized: "Handy koppeln")
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
                Text(String(localized: "Verbunden mit \(link.status.model ?? link.status.name ?? "dem Handy")"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "Du kannst dieses Fenster schließen."))
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
                    Text(String(localized: "Der Kopplungs-Code konnte nicht geladen werden."))
                        .foregroundStyle(.red)
                }
                Text(String(localized: "Smart Connect auf dem Handy öffnen, auf + tippen und „QR-Code scannen“ wählen. Der Code gilt 10 Minuten."))
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

/// App icon with its name; lights up under the pointer.
private struct PhoneAppTile: View {
    let app: PhoneApp
    let iconSize: CGFloat
    let height: CGFloat
    let lines: Int
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            PhoneAppIcon(app: app)
                .frame(width: iconSize, height: iconSize)
            Text(app.name)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .lineLimit(lines)
                .multilineTextAlignment(.center)
                .frame(height: lines == 1 ? 13 : 25, alignment: .top)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
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
