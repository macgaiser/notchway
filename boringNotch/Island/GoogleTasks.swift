//
//  GoogleTasks.swift
//  boringNotch
//
//  Google Tasks: lists and tasks, kept in sync with the user's account.
//

import Defaults
import SwiftUI

struct GoogleTaskList: Codable, Identifiable, Hashable {
    let id: String
    var title: String
}

struct GoogleTask: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var notes: String?
    var status: String?
    var due: String?

    /// Google stores only the day; the time part is always midnight UTC. Read it as a local day.
    var dueDate: Date? {
        guard let due, due.count >= 10 else { return nil }
        return Self.dayFormatter.date(from: String(due.prefix(10)))
    }

    static func dueString(for date: Date) -> String {
        dayFormatter.string(from: date) + "T00:00:00.000Z"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum GoogleTasksAPI {
    private static let base = "https://tasks.googleapis.com/tasks/v1"

    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]?
    }

    private struct APIFailure: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    @MainActor
    private static func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: String?]? = nil) async throws -> Data {
        let token = try await GoogleAuth.shared.validAccessToken()
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONDecoder().decode(APIFailure.self, from: data))?.error.message
            throw GoogleAuthError.server(detail ?? "Antwort \(status)")
        }
        return data
    }

    private static func encode(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/"))) ?? id
    }

    @MainActor static func lists() async throws -> [GoogleTaskList] {
        let data = try await send("GET", "/users/@me/lists", query: [.init(name: "maxResults", value: "100")])
        return try JSONDecoder().decode(Page<GoogleTaskList>.self, from: data).items ?? []
    }

    @MainActor static func createList(title: String) async throws -> GoogleTaskList {
        let data = try await send("POST", "/users/@me/lists", body: ["title": title])
        return try JSONDecoder().decode(GoogleTaskList.self, from: data)
    }

    @MainActor static func tasks(in list: String) async throws -> [GoogleTask] {
        let data = try await send("GET", "/lists/\(encode(list))/tasks", query: [
            .init(name: "maxResults", value: "100"),
            .init(name: "showCompleted", value: "false"),
        ])
        return try JSONDecoder().decode(Page<GoogleTask>.self, from: data).items ?? []
    }

    @MainActor static func add(title: String, notes: String? = nil, to list: String) async throws -> GoogleTask {
        var body = ["title": title]
        if let notes { body["notes"] = notes }
        let data = try await send("POST", "/lists/\(encode(list))/tasks", body: body)
        return try JSONDecoder().decode(GoogleTask.self, from: data)
    }

    /// A nil value clears that field at Google.
    @MainActor @discardableResult
    static func update(_ id: String, in list: String, fields: [String: String?]) async throws -> GoogleTask {
        let data = try await send("PATCH", "/lists/\(encode(list))/tasks/\(encode(id))", body: fields)
        return try JSONDecoder().decode(GoogleTask.self, from: data)
    }

    @MainActor static func delete(_ id: String, in list: String) async throws {
        _ = try await send("DELETE", "/lists/\(encode(list))/tasks/\(encode(id))")
    }
}

extension Defaults.Keys {
    static let islandTasksListID = Key<String>("islandTasksListID", default: "")
}

@MainActor
final class TasksStore: ObservableObject {
    static let shared = TasksStore()

    @Published private(set) var lists: [GoogleTaskList] = []
    @Published private(set) var tasks: [GoogleTask] = []
    @Published private(set) var isLoading = false
    @Published var errorText: String?
    @Published var selectedListID: String = Defaults[.islandTasksListID] {
        didSet {
            guard selectedListID != oldValue else { return }
            Defaults[.islandTasksListID] = selectedListID
            tasks = []
            Task { await refresh() }
        }
    }

    /// The list that stores notes is managed by the notes view, not shown as tasks.
    static let notesListTitle = "Island-Notizen"

    var visibleLists: [GoogleTaskList] { lists.filter { $0.title != Self.notesListTitle } }

    func refresh() async {
        guard GoogleAuth.shared.isConnected, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            lists = try await GoogleTasksAPI.lists()
            if !visibleLists.contains(where: { $0.id == selectedListID }) {
                selectedListID = visibleLists.first?.id ?? ""
                return
            }
            guard !selectedListID.isEmpty else { return }
            tasks = try await GoogleTasksAPI.tasks(in: selectedListID)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func add(_ title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selectedListID.isEmpty else { return }
        do {
            let created = try await GoogleTasksAPI.add(title: trimmed, to: selectedListID)
            tasks.insert(created, at: 0)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Saves edited fields; returns false if Google rejected them.
    @discardableResult
    func save(_ task: GoogleTask, title: String, notes: String, due: Date?) async -> Bool {
        do {
            let updated = try await GoogleTasksAPI.update(task.id, in: selectedListID, fields: [
                "title": title,
                "notes": notes,
                "due": due.map(GoogleTask.dueString(for:)),
            ])
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = updated }
            errorText = nil
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func complete(_ task: GoogleTask) async {
        await change(task) { try await GoogleTasksAPI.update(task.id, in: self.selectedListID, fields: ["status": "completed"]) }
    }

    func delete(_ task: GoogleTask) async {
        await change(task) { try await GoogleTasksAPI.delete(task.id, in: self.selectedListID) }
    }

    /// Removes the task right away and puts it back if Google rejects the change.
    private func change(_ task: GoogleTask, _ operation: () async throws -> Void) async {
        guard let index = tasks.firstIndex(of: task) else { return }
        tasks.remove(at: index)
        do {
            try await operation()
            errorText = nil
        } catch {
            tasks.insert(task, at: min(index, tasks.count))
            errorText = error.localizedDescription
        }
    }
}

struct TasksView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var auth = GoogleAuth.shared
    @ObservedObject private var store = TasksStore.shared
    @State private var newTitle = ""
    @State private var editing: GoogleTask?

    var body: some View {
        if auth.isConnected {
            ZStack {
                if let task = editing {
                    TaskEditor(task: task) { editing = nil }
                        .id(task.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    VStack(spacing: 8) {
                        toolbar
                        content
                    }
                    .transition(.opacity)
                }
            }
            .animation(IslandMotion.tab, value: editing?.id)
            .task { await store.refresh() }
            .onAppear { IslandFocus.allowsKey = true }
            .onDisappear {
                IslandFocus.allowsKey = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        } else {
            VStack(spacing: 8) {
                IslandEmptyState(icon: "checklist", text: "Google-Konto noch nicht verbunden")
                Button("In den Einstellungen verbinden") {
                    SettingsWindowController.shared.showWindow()
                    vm.close()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.visibleLists) { list in
                    Button(list.title) { store.selectedListID = list.id }
                }
            } label: {
                Text(store.visibleLists.first { $0.id == store.selectedListID }?.title ?? "Liste")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: 150, alignment: .leading)

            TextField("Neue Aufgabe", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                .onSubmit {
                    let title = newTitle
                    newTitle = ""
                    Task { await store.add(title) }
                }

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                    .animation(store.isLoading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.isLoading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Mit Google abgleichen")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorText = store.errorText {
            Text(errorText)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if store.tasks.isEmpty {
            IslandEmptyState(icon: "checkmark.circle", text: store.isLoading ? "Lade Aufgaben …" : "Keine offenen Aufgaben")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.tasks) { task in
                        row(for: task)
                    }
                }
            }
        }
    }

    private func row(for task: GoogleTask) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.complete(task) }
            } label: {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Als erledigt markieren")

            Button {
                editing = task
            } label: {
                HStack(spacing: 6) {
                    Text(task.title.isEmpty ? "Ohne Titel" : task.title)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if task.notes?.isEmpty == false {
                        Image(systemName: "text.alignleft")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let due = task.dueDate {
                        Text(due.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.caption)
                            .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) ? .red : .secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Öffnen und bearbeiten")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Bearbeiten") { editing = task }
            Button("Aufgabe löschen") { Task { await store.delete(task) } }
        }
    }
}

/// Full view of one task inside the island: title, details and due date.
struct TaskEditor: View {
    let task: GoogleTask
    let onClose: () -> Void

    @ObservedObject private var store = TasksStore.shared
    @State private var title: String
    @State private var notes: String
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var isSaving = false
    @State private var closed = false

    init(task: GoogleTask, onClose: @escaping () -> Void) {
        self.task = task
        self.onClose = onClose
        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.notes ?? "")
        _hasDue = State(initialValue: task.dueDate != nil)
        _due = State(initialValue: task.dueDate ?? Calendar.current.startOfDay(for: Date()))
    }

    private var changed: Bool {
        title != task.title || notes != (task.notes ?? "") || (hasDue ? due : nil) != task.dueDate
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                TextField("Titel", text: $title)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.09)))
                    .onSubmit { Task { await saveAndClose() } }

                TextEditor(text: $notes)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
                    .overlay(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("Details")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 5)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Termin", isOn: $hasDue)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                if hasDue {
                    DatePicker("Termin", selection: $due, displayedComponents: .date)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                if let errorText = store.errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Button(isSaving ? "Speichere …" : changed ? "Sichern" : "Zurück") {
                        Task { await saveAndClose() }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                    Button {
                        closed = true
                        onClose()
                        Task { await store.complete(task) }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .help("Als erledigt markieren")
                    Button(role: .destructive) {
                        closed = true
                        onClose()
                        Task { await store.delete(task) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Aufgabe löschen")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(width: 170, alignment: .leading)
        }
        // Leaving the island with unsaved edits must not lose them.
        .onDisappear {
            guard !closed, changed else { return }
            let (title, notes, due) = (title, notes, hasDue ? due : nil)
            Task { await store.save(task, title: title, notes: notes, due: due) }
        }
    }

    private func saveAndClose() async {
        if changed {
            isSaving = true
            let saved = await store.save(task, title: title, notes: notes, due: hasDue ? due : nil)
            isSaving = false
            guard saved else { return }
        }
        closed = true
        onClose()
    }
}
