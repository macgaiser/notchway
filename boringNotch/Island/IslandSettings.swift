//
//  IslandSettings.swift
//  boringNotch
//
//  Settings pages for the island's views.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// "Ansichten": which views exist, where their symbols sit and which one opens first.
struct IslandSettings: View {
    @Default(.islandStartView) private var startView
    @Default(.islandHiddenTabs) private var hiddenTabs
    @Default(.boringShelf) private var shelfEnabled
    @Default(.islandTabsLeading) private var leadingTabs
    @Default(.islandTabsTrailing) private var trailingTabs

    private var sides: (leading: [NotchViews], trailing: [NotchViews]) {
        IslandTabLayout.arranged(leading: leadingTabs, trailing: trailingTabs)
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Ansicht beim Öffnen"), selection: $startView) {
                    ForEach(IslandStartView.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } footer: {
                Text(String(localized: "Ist die gewählte Startansicht ausgeblendet, öffnet sich Player & Kalender."))
            }

            side(sides.leading, isLeading: true)
            side(sides.trailing, isLeading: false)

            Section {
                Text(String(localized: "Die Symbole lassen sich auch direkt in der offenen Notch mit der Maus an eine andere Stelle ziehen, auch auf die andere Seite."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(String(localized: "Standardanordnung wiederherstellen")) {
                    Defaults.reset(.islandTabsLeading, .islandTabsTrailing)
                }
            }
        }
        .navigationTitle(String(localized: "Ansichten"))
    }

    private func side(_ tabs: [NotchViews], isLeading: Bool) -> some View {
        let capacity = isLeading ? IslandTabLayout.leadingCapacity : IslandTabLayout.trailingCapacity
        let shown = tabs.filter { $0.isVisible(hidden: hiddenTabs, shelfEnabled: shelfEnabled) }.count
        return Section {
            if tabs.isEmpty {
                Text(String(localized: "Keine Ansicht auf dieser Seite."))
                    .foregroundStyle(.secondary)
            }
            ForEach(tabs, id: \.self) { tab in
                HStack(spacing: 10) {
                    Image(systemName: tab.icon)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Text(tab.title)
                    Spacer()
                    Button {
                        move(tab, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(tabs.first == tab)
                    .help(String(localized: "Weiter nach links"))
                    Button {
                        move(tab, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(tabs.last == tab)
                    .help(String(localized: "Weiter nach rechts"))
                    Button(isLeading ? String(localized: "Nach rechts") : String(localized: "Nach links")) {
                        switchSide(tab)
                    }
                    .help(isLeading ? String(localized: "Auf die rechte Seite der Notch") : String(localized: "Auf die linke Seite der Notch"))
                    Toggle(tab.title, isOn: visibility(of: tab))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(tab == .home)
                }
            }
        } header: {
            Text(isLeading ? String(localized: "Links der Notch") : String(localized: "Rechts der Notch"))
        } footer: {
            if shown > capacity {
                Text(isLeading
                     ? String(localized: "Links ist Platz für \(capacity) Symbole. Was nicht passt, rückt automatisch nach rechts.")
                     : String(localized: "Rechts ist neben dem Einstellungen-Symbol Platz für etwa \(capacity) Symbole. Blende eine Ansicht aus oder schiebe sie nach links."))
                    .foregroundStyle(.orange)
            } else {
                Text(isLeading
                     ? String(localized: "Die Reihenfolge von oben nach unten entspricht den Symbolen von links nach rechts. Player & Kalender ist immer sichtbar.")
                     : String(localized: "Die Symbole stehen rechtsbündig, direkt vor dem Einstellungen-Symbol."))
            }
        }
    }

    private func visibility(of tab: NotchViews) -> Binding<Bool> {
        if tab == .shelf { return $shelfEnabled }
        return Binding(
            get: { !hiddenTabs.contains(tab.rawValue) },
            set: { visible in
                hiddenTabs.removeAll { $0 == tab.rawValue }
                if !visible { hiddenTabs.append(tab.rawValue) }
            }
        )
    }

    private func store(leading: [NotchViews], trailing: [NotchViews]) {
        leadingTabs = leading.map(\.rawValue)
        trailingTabs = trailing.map(\.rawValue)
    }

    private func move(_ tab: NotchViews, by offset: Int) {
        var (left, right) = sides
        if let index = left.firstIndex(of: tab), left.indices.contains(index + offset) {
            left.swapAt(index, index + offset)
        } else if let index = right.firstIndex(of: tab), right.indices.contains(index + offset) {
            right.swapAt(index, index + offset)
        }
        store(leading: left, trailing: right)
    }

    /// Moves the symbol next to the notch on the other side.
    private func switchSide(_ tab: NotchViews) {
        var (left, right) = sides
        if let index = left.firstIndex(of: tab) {
            left.remove(at: index)
            right.insert(tab, at: 0)
        } else if let index = right.firstIndex(of: tab) {
            right.remove(at: index)
            left.append(tab)
        }
        store(leading: left, trailing: right)
    }
}

enum IslandFilePicker {
    @MainActor
    static func pick(multiple: Bool) -> [QuickLaunchItem] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = multiple
        panel.allowsMultipleSelection = multiple
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = multiple ? String(localized: "Hinzufügen") : String(localized: "Auswählen")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(QuickLaunchItem.init(fileURL:))
    }
}

struct QuickLaunchSettings: View {
    @Default(.islandQuickLaunch) private var quickLaunch
    @Default(.islandMusicLauncher) private var musicLauncher
    @State private var newSiteName = ""
    @State private var newSiteAddress = ""
    @State private var newSiteBrowser: String?
    @State private var showAddressHint = false
    @State private var browsers: [URL] = NSWorkspace.shared
        .urlsForApplications(toOpen: URL(string: "https://example.com")!)
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

    var body: some View {
        Form {
            Section {
                ForEach(quickLaunch) { item in
                    HStack(spacing: 10) {
                        QuickLaunchIcon(item: item)
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.target)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if item.isWeb {
                            Picker(String(localized: "Browser"), selection: browser(of: item)) {
                                Text(String(localized: "Standardbrowser")).tag(String?.none)
                                ForEach(browsers, id: \.path) { url in
                                    Text(url.deletingPathExtension().lastPathComponent).tag(String?.some(url.path))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            .help(String(localized: "Browser, in dem diese Website geöffnet wird"))
                        }
                        Button {
                            move(item, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(quickLaunch.first == item)
                        .help(String(localized: "Nach vorne"))
                        Button {
                            move(item, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(quickLaunch.last == item)
                        .help(String(localized: "Nach hinten"))
                        Button(role: .destructive) {
                            quickLaunch.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help(String(localized: "Entfernen"))
                    }
                }
                Button(String(localized: "App, Datei oder Ordner hinzufügen …")) { quickLaunch.append(contentsOf: IslandFilePicker.pick(multiple: true)) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Website hinzufügen"))
                    HStack {
                        TextField(String(localized: "Name"), text: $newSiteName, prompt: Text(String(localized: "Name (optional)")))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        TextField(String(localized: "Adresse"), text: $newSiteAddress, prompt: Text(String(localized: "Adresse, z. B. music.youtube.com oder http://nas:9091")))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addSite() }
                        Picker(String(localized: "Browser"), selection: $newSiteBrowser) {
                            Text(String(localized: "Standardbrowser")).tag(String?.none)
                            ForEach(browsers, id: \.path) { url in
                                Text(url.deletingPathExtension().lastPathComponent).tag(String?.some(url.path))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Button(String(localized: "Hinzufügen")) { addSite() }
                    }
                    if showAddressHint {
                        Text(String(localized: "Bitte eine gültige Adresse eintragen, zum Beispiel music.youtube.com oder http://nas:9091."))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text(String(localized: "Schnellstart"))
            }
        }
        .navigationTitle(String(localized: "Schnellstart"))
    }

    private func browser(of item: QuickLaunchItem) -> Binding<String?> {
        Binding(
            get: { quickLaunch.first { $0.id == item.id }?.browser },
            set: { path in
                guard let index = quickLaunch.firstIndex(where: { $0.id == item.id }) else { return }
                quickLaunch[index].browser = path
                // The player button holds its own copy of the entry.
                if musicLauncher?.id == item.id { musicLauncher = quickLaunch[index] }
            }
        )
    }

    private func move(_ item: QuickLaunchItem, by offset: Int) {
        guard let index = quickLaunch.firstIndex(of: item) else { return }
        let target = index + offset
        guard quickLaunch.indices.contains(target) else { return }
        quickLaunch.swapAt(index, target)
    }

    private var normalizedAddress: String? {
        let trimmed = newSiteAddress.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), url.host?.isEmpty == false else { return nil }
            return trimmed
        }
        guard !trimmed.contains(" "), let probe = URL(string: "https://" + trimmed), let host = probe.host, !host.isEmpty else { return nil }
        // Devices on the home network (plain names, IP addresses, custom ports) rarely offer https.
        let isLocal = !host.contains(".") || host.hasSuffix(".local") || probe.port != nil
            || host.allSatisfy { $0.isNumber || $0 == "." }
        return (isLocal ? "http://" : "https://") + trimmed
    }

    private func addSite() {
        guard let address = normalizedAddress else {
            showAddressHint = true
            return
        }
        showAddressHint = false
        let name = newSiteName.trimmingCharacters(in: .whitespaces)
        let fallback = URL(string: address)?.host ?? address
        var item = QuickLaunchItem(name: name.isEmpty ? fallback : name, target: address)
        item.browser = newSiteBrowser
        quickLaunch.append(item)
        SiteIconLoader.preload([address])
        newSiteName = ""
        newSiteAddress = ""
    }
}

/// Shown on the upstream "Media" page: the button that starts a music app from the player.
struct PlayerLauncherSection: View {
    @Default(.islandQuickLaunch) private var quickLaunch
    @Default(.islandMusicLauncher) private var musicLauncher

    var body: some View {
        Section {
            Picker(String(localized: "Startknopf öffnet"), selection: $musicLauncher) {
                Text(String(localized: "Kein Startknopf")).tag(QuickLaunchItem?.none)
                ForEach(launcherChoices) { item in
                    Text(item.name).tag(QuickLaunchItem?.some(item))
                }
            }
            Button(String(localized: "Andere App wählen …")) {
                if let item = IslandFilePicker.pick(multiple: false).first { musicLauncher = item }
            }
        } header: {
            Text(String(localized: "Startknopf im Player"))
        } footer: {
            Text(String(localized: "Der Startknopf erscheint im Player, solange nichts abgespielt wird. Zur Auswahl stehen deine Schnellstart-Einträge oder eine beliebige App. In welchem Browser eine Website aufgeht, legst du unter „Schnellstart“ beim jeweiligen Eintrag fest."))
        }
    }

    /// Schnellstart entries, plus the current choice if it is not one of them.
    private var launcherChoices: [QuickLaunchItem] {
        var choices = quickLaunch
        if let musicLauncher, !choices.contains(where: { $0.id == musicLauncher.id }) { choices.insert(musicLauncher, at: 0) }
        return choices
    }
}

struct PomodoroSettings: View {
    @Default(.islandPomodoroWorkMinutes) private var workMinutes
    @Default(.islandPomodoroBreakMinutes) private var breakMinutes

    var body: some View {
        Form {
            Section {
                Stepper(String(localized: "Fokus: \(workMinutes) Minuten"), value: $workMinutes, in: 1...120)
                Stepper(String(localized: "Pause: \(breakMinutes) Minuten"), value: $breakMinutes, in: 1...60)
            } header: {
                Text(String(localized: "Pomodoro"))
            } footer: {
                Text(String(localized: "Geänderte Zeiten gelten ab der nächsten Phase."))
            }
        }
        .navigationTitle(String(localized: "Pomodoro"))
    }
}

struct ClipboardSettings: View {
    @Default(.islandClipboardLimit) private var clipboardLimit

    var body: some View {
        Form {
            Section {
                Stepper(String(localized: "Einträge im Verlauf: \(clipboardLimit)"), value: $clipboardLimit, in: 5...200, step: 5)
                Button(String(localized: "Verlauf löschen"), role: .destructive) {
                    ClipboardHistory.shared.clear()
                }
            } header: {
                Text(String(localized: "Verlauf"))
            } footer: {
                Text(String(localized: "Gespeichert wird nur Text, lokal auf diesem Mac. Einträge, die Passwortmanager als vertraulich markieren, werden übersprungen. Ist die Ansicht ausgeblendet, wird nichts aufgezeichnet."))
            }
        }
        .navigationTitle(String(localized: "Zwischenablage"))
    }
}

struct PhoneSettings: View {
    @ObservedObject private var phone = PhoneLink.shared
    @Default(.islandTrustedNetworks) private var trustedNetworks
    @Default(.islandPhoneClipboardSend) private var phoneClipboardSend
    @Default(.islandPhoneClipboardReceive) private var phoneClipboardReceive

    var body: some View {
        Form {
            Section {
                if trustedNetworks.isEmpty {
                    Text(String(localized: "Noch kein Netzwerk als vertraut markiert."))
                        .foregroundStyle(.secondary)
                }
                ForEach(trustedNetworks.sorted { $0.value < $1.value }, id: \.key) { id, label in
                    HStack {
                        Image(systemName: phone.network?.id == id ? "wifi" : "wifi.slash")
                            .foregroundStyle(phone.network?.id == id ? .green : .secondary)
                        Text(label + (phone.network?.id == id ? String(localized: " · aktuell verbunden") : ""))
                        Spacer()
                        Button(role: .destructive) {
                            phone.forget(networkID: id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help(String(localized: "Nicht mehr vertrauen"))
                    }
                }
                if let network = phone.network, trustedNetworks[network.id] == nil {
                    Button(String(localized: "Aktuellem Netzwerk vertrauen · \(network.label)")) { phone.trustCurrentNetwork() }
                }
                LabeledContent(String(localized: "Handy-Dienst"), value: phone.daemonRunning ? String(localized: "läuft") : String(localized: "aus"))
                HStack {
                    Button(String(localized: "Diagnose kopieren")) { phone.copyDiagnosis() }
                    if let message = phone.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(String(localized: "Vertraute Netzwerke"))
            } footer: {
                Text(String(localized: "Für die Verbindung zum Handy nimmt der Mac Verbindungen aus dem lokalen Netzwerk an. Der Dienst dafür läuft nur in den hier aufgeführten Netzwerken und nur, solange die Ansicht „Handy“ eingeblendet ist. In jedem anderen Netzwerk ist er beendet und der Port geschlossen. Erkannt wird ein Netzwerk an seinem Router, nicht am Namen."))
            }

            PhoneAudioSection()

            Section {
                Toggle(String(localized: "Vom Mac zum Handy"), isOn: $phoneClipboardSend)
                Toggle(String(localized: "Vom Handy zum Mac"), isOn: $phoneClipboardReceive)
            } header: {
                Text(String(localized: "Zwischenablage"))
            } footer: {
                Text(String(localized: "Übertragen wird nur Text. Was Passwortmanager als vertraulich markieren, bleibt auf dem Mac. Eine Änderung startet den Handy-Dienst kurz neu; das Handy verbindet sich danach von selbst wieder."))
            }
            .onChange(of: phoneClipboardSend) { _, _ in phone.restartService() }
            .onChange(of: phoneClipboardReceive) { _, _ in phone.restartService() }
        }
        .navigationTitle(String(localized: "Handy"))
    }
}

struct GoogleAccountSettings: View {
    @Default(.islandGoogleClientID) private var googleClientID
    @ObservedObject private var google = GoogleAuth.shared
    @State private var googleClientSecret = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    if google.isConnected {
                        Label(String(localized: "Verbunden"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button(String(localized: "Trennen"), role: .destructive) { google.disconnect() }
                    } else {
                        Button(google.isWorking ? String(localized: "Warte auf Browser …") : String(localized: "Mit Google verbinden")) {
                            let secret = googleClientSecret
                            googleClientSecret = ""
                            Task { await google.connect(clientSecret: secret) }
                        }
                        .disabled(google.isWorking || !(GoogleClient.isConfigured || (!googleClientID.isEmpty && !googleClientSecret.isEmpty)))
                        if google.isWorking {
                            Button(String(localized: "Abbrechen")) { google.cancelConnect() }
                        }
                    }
                }
                if let message = google.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Google-Konto")
            } footer: {
                Text(String(localized: "Für die Ansichten „Aufgaben“ und „Notizen“. Die App fragt nur den Zugriff auf Google Tasks an. Der Zugang liegt im macOS-Schlüsselbund und lässt sich hier oder in deinem Google-Konto unter „Sicherheit“ widerrufen."))
            }

            Section {
                DisclosureGroup(String(localized: "Eigenen Google-Client verwenden")) {
                    TextField("Client-ID", text: $googleClientID, prompt: Text("…apps.googleusercontent.com"))
                    SecureField(String(localized: "Client-Schlüssel"), text: $googleClientSecret, prompt: Text(google.hasClientSecret ? String(localized: "Gespeichert") : "GOCSPX-…"))
                    Text(String(localized: "Optional: Client-ID und Client-Schlüssel aus deinem eigenen Projekt in der Google Cloud Console (Typ „Desktop-App“). Leer lassen, um den Client von Notchway zu nutzen."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Google-Konto")
    }
}

/// Shown on the "General" page: the app's language, independent of the system's.
struct LanguageSection: View {
    @State private var language: String = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first.map { String($0.prefix(2)) } ?? ""

    var body: some View {
        Section {
            Picker(String(localized: "Sprache"), selection: $language) {
                Text(String(localized: "Wie das System")).tag("")
                Text(verbatim: "Deutsch").tag("de")
                Text(verbatim: "English").tag("en")
            }
            .onChange(of: language) { _, chosen in
                if chosen.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([chosen], forKey: "AppleLanguages")
                }
                // Texts are looked up in the language the app started with.
                ApplicationRelauncher.restart()
            }
        } footer: {
            Text(String(localized: "Die App startet neu, damit die Sprache gilt."))
        }
    }
}


/// Sound of streamed phone apps on the Mac, through the phone's wireless debugging.
struct PhoneAudioSection: View {
    @Default(.islandPhoneAudio) private var enabled
    @Default(.islandPhoneAudioOnPhone) private var onPhone
    @ObservedObject private var audio = PhoneAudio.shared
    @State private var code = ""

    var body: some View {
        Section {
            Toggle(String(localized: "Ton von Handy-Apps am Mac abspielen"), isOn: $enabled)
                .onChange(of: enabled) { _, _ in audio.configure() }
            if enabled {
                Toggle(String(localized: "Ton zusätzlich am Handy abspielen"), isOn: $onPhone)
                LabeledContent(String(localized: "Verbindung"),
                               value: audio.playing ? String(localized: "Ton läuft") : audio.connected ? String(localized: "Handy verbunden") : String(localized: "nicht verbunden"))
                if !audio.connected {
                    if audio.pairingAvailable {
                        HStack {
                            TextField(String(localized: "Kopplungscode"), text: $code, prompt: Text("123456"))
                                .frame(maxWidth: 140)
                            Button(String(localized: "Koppeln")) {
                                audio.pair(code: code)
                                code = ""
                            }
                            .disabled(code.trimmingCharacters(in: .whitespaces).count < 6)
                        }
                    }
                    Button(String(localized: "Erneut verbinden")) { audio.connect() }
                }
                if !PhoneAudio.isInstalled {
                    Text(String(localized: "Diese Version enthält den Ton-Dienst nicht."))
                        .font(.caption).foregroundStyle(.red)
                }
                if let message = audio.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "Ton über Drahtloses Debugging"))
        } footer: {
            Text(String(localized: "Einmal einrichten: Am Handy Entwickleroptionen einschalten (Einstellungen › Über das Telefon › 7-mal auf Build-Nummer tippen), dann unter Entwickleroptionen „Drahtloses Debugging“ einschalten und „Mit Kopplungscode koppeln“ öffnen. Der Code erscheint dort, der Mac erkennt das Fenster und du gibst den Code hier ein. Danach hört der Mac den Ton, solange ein Handy-App-Fenster offen ist. Das Drahtlose Debugging schaltet sich bei einem Netzwechsel aus und muss dann am Handy neu eingeschaltet werden."))
        }
    }
}
