//
//  IslandSettings.swift
//  boringNotch
//
//  Settings page for the island's views.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct IslandSettings: View {
    @Default(.islandStartView) private var startView
    @Default(.islandHiddenTabs) private var hiddenTabs
    @Default(.boringShelf) private var shelfEnabled
    @Default(.islandQuickLaunch) private var quickLaunch
    @Default(.islandPomodoroWorkMinutes) private var workMinutes
    @Default(.islandPomodoroBreakMinutes) private var breakMinutes
    @Default(.islandClipboardLimit) private var clipboardLimit
    @Default(.islandMusicLauncher) private var musicLauncher

    @Default(.islandGoogleClientID) private var googleClientID
    @ObservedObject private var google = GoogleAuth.shared
    @ObservedObject private var phone = PhoneLink.shared
    @Default(.islandTrustedNetworks) private var trustedNetworks
    @Default(.islandPhoneClipboardSend) private var phoneClipboardSend
    @Default(.islandPhoneClipboardReceive) private var phoneClipboardReceive
    @State private var googleClientSecret = ""
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
                Picker("Ansicht beim Öffnen", selection: $startView) {
                    ForEach(IslandStartView.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle(NotchViews.shelf.title, isOn: $shelfEnabled)
                ForEach(NotchViews.allCases.filter(\.canBeHidden), id: \.self) { tab in
                    Toggle(tab.title, isOn: visibility(of: tab))
                }
            } header: {
                Text("Ansichten")
            } footer: {
                Text("Player & Kalender ist immer sichtbar. Ist die gewählte Startansicht ausgeblendet, öffnet sich Player & Kalender.")
            }

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
                            Picker("Browser", selection: browser(of: item)) {
                                Text("Standardbrowser").tag(String?.none)
                                ForEach(browsers, id: \.path) { url in
                                    Text(url.deletingPathExtension().lastPathComponent).tag(String?.some(url.path))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            .help("Browser, in dem diese Website geöffnet wird")
                        }
                        Button {
                            move(item, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(quickLaunch.first == item)
                        .help("Nach vorne")
                        Button {
                            move(item, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(quickLaunch.last == item)
                        .help("Nach hinten")
                        Button(role: .destructive) {
                            quickLaunch.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Entfernen")
                    }
                }
                Button("App, Datei oder Ordner hinzufügen …") { quickLaunch.append(contentsOf: pickFiles(multiple: true)) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Website hinzufügen")
                    HStack {
                        TextField("Name", text: $newSiteName, prompt: Text("Name (optional)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        TextField("Adresse", text: $newSiteAddress, prompt: Text("Adresse, z. B. music.youtube.com oder http://nas:9091"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addSite() }
                        Picker("Browser", selection: $newSiteBrowser) {
                            Text("Standardbrowser").tag(String?.none)
                            ForEach(browsers, id: \.path) { url in
                                Text(url.deletingPathExtension().lastPathComponent).tag(String?.some(url.path))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Button("Hinzufügen") { addSite() }
                    }
                    if showAddressHint {
                        Text("Bitte eine gültige Adresse eintragen, zum Beispiel music.youtube.com oder http://nas:9091.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Schnellstart")
            }

            Section {
                Picker("Startknopf öffnet", selection: $musicLauncher) {
                    Text("Kein Startknopf").tag(QuickLaunchItem?.none)
                    ForEach(launcherChoices) { item in
                        Text(item.name).tag(QuickLaunchItem?.some(item))
                    }
                }
                Button("Andere App wählen …") {
                    if let item = pickFiles(multiple: false).first { musicLauncher = item }
                }
            } header: {
                Text("Player")
            } footer: {
                Text("Der Startknopf erscheint im Player, solange nichts abgespielt wird. Zur Auswahl stehen deine Schnellstart-Einträge oder eine beliebige App. In welchem Browser eine Website aufgeht, legst du unten beim jeweiligen Schnellstart-Eintrag fest.")
            }

            Section {
                Stepper("Fokus: \(workMinutes) Minuten", value: $workMinutes, in: 1...120)
                Stepper("Pause: \(breakMinutes) Minuten", value: $breakMinutes, in: 1...60)
            } header: {
                Text("Pomodoro")
            } footer: {
                Text("Geänderte Zeiten gelten ab der nächsten Phase.")
            }

            Section {
                Stepper("Einträge im Verlauf: \(clipboardLimit)", value: $clipboardLimit, in: 5...200, step: 5)
                Button("Verlauf löschen", role: .destructive) {
                    ClipboardHistory.shared.clear()
                }
            } header: {
                Text("Zwischenablage")
            } footer: {
                Text("Gespeichert wird nur Text, lokal auf diesem Mac. Einträge, die Passwortmanager als vertraulich markieren, werden übersprungen. Ist die Ansicht ausgeblendet, wird nichts aufgezeichnet.")
            }

            Section {
                if trustedNetworks.isEmpty {
                    Text("Noch kein Netzwerk als vertraut markiert.")
                        .foregroundStyle(.secondary)
                }
                ForEach(trustedNetworks.sorted { $0.value < $1.value }, id: \.key) { id, label in
                    HStack {
                        Image(systemName: phone.network?.id == id ? "wifi" : "wifi.slash")
                            .foregroundStyle(phone.network?.id == id ? .green : .secondary)
                        Text(label + (phone.network?.id == id ? " · aktuell verbunden" : ""))
                        Spacer()
                        Button(role: .destructive) {
                            phone.forget(networkID: id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Nicht mehr vertrauen")
                    }
                }
                if let network = phone.network, trustedNetworks[network.id] == nil {
                    Button("Aktuellem Netzwerk vertrauen · \(network.label)") { phone.trustCurrentNetwork() }
                }
                LabeledContent("Handy-Dienst", value: phone.daemonRunning ? "läuft" : "aus")
                HStack {
                    Button("Diagnose kopieren") { phone.copyDiagnosis() }
                    if let message = phone.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Handy · vertraute Netzwerke")
            } footer: {
                Text("Für die Verbindung zum Handy nimmt der Mac Verbindungen aus dem lokalen Netzwerk an. Der Dienst dafür läuft nur in den hier aufgeführten Netzwerken und nur, solange die Ansicht „Handy“ eingeblendet ist. In jedem anderen Netzwerk ist er beendet und der Port geschlossen. Erkannt wird ein Netzwerk an seinem Router, nicht am Namen.")
            }

            Section {
                Toggle("Vom Mac zum Handy", isOn: $phoneClipboardSend)
                Toggle("Vom Handy zum Mac", isOn: $phoneClipboardReceive)
            } header: {
                Text("Handy · Zwischenablage")
            } footer: {
                Text("Übertragen wird nur Text. Was Passwortmanager als vertraulich markieren, bleibt auf dem Mac. Eine Änderung startet den Handy-Dienst kurz neu; das Handy verbindet sich danach von selbst wieder.")
            }
            .onChange(of: phoneClipboardSend) { _, _ in phone.restartService() }
            .onChange(of: phoneClipboardReceive) { _, _ in phone.restartService() }

            Section {
                TextField("Client-ID", text: $googleClientID, prompt: Text("…apps.googleusercontent.com"))
                SecureField("Client-Schlüssel", text: $googleClientSecret, prompt: Text(google.hasClientSecret ? "Gespeichert" : "GOCSPX-…"))
                HStack {
                    if google.isConnected {
                        Label("Verbunden", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Trennen", role: .destructive) { google.disconnect() }
                    } else {
                        Button(google.isWorking ? "Warte auf Browser …" : "Mit Google verbinden") {
                            let secret = googleClientSecret
                            googleClientSecret = ""
                            Task { await google.connect(clientSecret: secret) }
                        }
                        .disabled(google.isWorking || googleClientID.isEmpty || (googleClientSecret.isEmpty && !google.hasClientSecret))
                        if google.isWorking {
                            Button("Abbrechen") { google.cancelConnect() }
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
                Text("Für die Ansicht „Aufgaben“. Client-ID und Client-Schlüssel stammen aus deinem eigenen Projekt in der Google Cloud Console (Typ „Desktop-App“). Die App fragt nur den Zugriff auf Google Tasks an. Schlüssel und Zugang liegen im macOS-Schlüsselbund.")
            }
        }
        .navigationTitle("Ansichten")
    }

    private func visibility(of tab: NotchViews) -> Binding<Bool> {
        Binding(
            get: { !hiddenTabs.contains(tab.rawValue) },
            set: { visible in
                hiddenTabs.removeAll { $0 == tab.rawValue }
                if !visible { hiddenTabs.append(tab.rawValue) }
            }
        )
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

    /// Schnellstart entries, plus the current choice if it is not one of them.
    private var launcherChoices: [QuickLaunchItem] {
        var choices = quickLaunch
        if let musicLauncher, !choices.contains(where: { $0.id == musicLauncher.id }) { choices.insert(musicLauncher, at: 0) }
        return choices
    }

    private func pickFiles(multiple: Bool) -> [QuickLaunchItem] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = multiple
        panel.allowsMultipleSelection = multiple
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = multiple ? "Hinzufügen" : "Auswählen"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(QuickLaunchItem.init(fileURL:))
    }
}
