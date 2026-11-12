//
//  Notes.swift
//  boringNotch
//
//  Quick notes. Stored locally and, when a Google account is connected,
//  mirrored into a Google Tasks list so they show up on the phone.
//

import SwiftUI

struct IslandNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text = ""
    var modified = Date()
    /// Id of the matching Google task, once the note has been uploaded.
    var remoteID: String?
    /// True while local edits have not reached Google yet.
    var dirty: Bool?

    var title: String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Neue Notiz" : firstLine
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A note maps to a task as: first line = title, the rest = details.
    var remoteFields: [String: String] {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return [
            "title": String(lines.first ?? "").prefix(1000).description,
            "notes": lines.count > 1 ? String(lines[1]).prefix(8000).description : "",
        ]
    }

    static func text(from task: GoogleTask) -> String {
        let details = task.notes ?? ""
        return details.isEmpty ? task.title : task.title + "\n" + details
    }
}

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published var notes: [IslandNote] {
        didSet { IslandStore.save(notes, as: "notes") }
    }
    @Published var selectedID: UUID?
    @Published private(set) var isSyncing = false
    @Published private(set) var syncError: String?

    /// Google ids of notes deleted here that still have to be deleted there.
    private var pendingDeletes: [String] {
        didSet { IslandStore.save(pendingDeletes, as: "notes-deleted") }
    }
    private var listID: String?
    private var syncTask: Task<Void, Never>?

    private init() {
        notes = IslandStore.load("notes", as: [IslandNote].self) ?? []
        pendingDeletes = IslandStore.load("notes-deleted", as: [String].self) ?? []
        selectedID = notes.first?.id
    }

    func add() {
        let note = IslandNote()
        notes.insert(note, at: 0)
        selectedID = note.id
    }

    func delete(_ note: IslandNote) {
        if let remoteID = note.remoteID { pendingDeletes.append(remoteID) }
        notes.removeAll { $0.id == note.id }
        if selectedID == note.id { selectedID = notes.first?.id }
        scheduleSync()
    }

    /// Binding to the text of the selected note.
    var selectedText: Binding<String> {
        Binding(
            get: { self.notes.first { $0.id == self.selectedID }?.text ?? "" },
            set: { newValue in
                guard let index = self.notes.firstIndex(where: { $0.id == self.selectedID }),
                      self.notes[index].text != newValue else { return }
                self.notes[index].text = newValue
                self.notes[index].modified = Date()
                self.notes[index].dirty = true
                self.scheduleSync()
            }
        )
    }

    // MARK: - Google sync

    /// Waits for a pause in typing before talking to Google.
    func scheduleSync(after seconds: Double = 3) {
        guard GoogleAuth.shared.isConnected else { return }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func sync() async {
        guard GoogleAuth.shared.isConnected, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let list = try await notesListID()

            for remoteID in pendingDeletes {
                try? await GoogleTasksAPI.delete(remoteID, in: list)
            }
            let deleted = Set(pendingDeletes)
            pendingDeletes = []

            let remote = try await GoogleTasksAPI.tasks(in: list).filter { !deleted.contains($0.id) }
            // One page holds 100 tasks. With a full page, a missing task may just be on the next page,
            // so nothing is removed locally in that case.
            let remoteIsComplete = remote.count < 100
            let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            // Edits made while this runs must not be overwritten: work on ids and re-read each note.
            for id in notes.map(\.id) {
                guard let note = notes.first(where: { $0.id == id }) else { continue }

                if let remoteID = note.remoteID, let task = remoteByID[remoteID] {
                    if note.dirty == true {
                        try await GoogleTasksAPI.update(remoteID, in: list, fields: note.remoteFields)
                        markClean(id, sentText: note.text)
                    } else if IslandNote.text(from: task) != note.text {
                        update(id) { $0.text = IslandNote.text(from: task); $0.modified = Date() }
                    }
                } else if note.remoteID != nil, note.dirty != true, remoteIsComplete {
                    // Deleted or ticked off on another device.
                    notes.removeAll { $0.id == id }
                    if selectedID == id { selectedID = notes.first?.id }
                } else if !note.isBlank {
                    let fields = note.remoteFields
                    let created = try await GoogleTasksAPI.add(title: fields["title"] ?? "", notes: fields["notes"], to: list)
                    update(id) { $0.remoteID = created.id }
                    markClean(id, sentText: note.text)
                }
            }

            let known = Set(notes.compactMap(\.remoteID))
            for task in remote where !known.contains(task.id) {
                notes.append(IslandNote(text: IslandNote.text(from: task), remoteID: task.id))
            }
            if selectedID == nil { selectedID = notes.first?.id }
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func update(_ id: UUID, _ change: (inout IslandNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
    }

    /// Clears the flag only if the note was not edited again while uploading.
    private func markClean(_ id: UUID, sentText: String) {
        update(id) { if $0.text == sentText { $0.dirty = false } }
    }

    private func notesListID() async throws -> String {
        if let listID { return listID }
        let lists = try await GoogleTasksAPI.lists()
        let list: GoogleTaskList
        if let existing = lists.first(where: { $0.title == TasksStore.notesListTitle }) {
            list = existing
        } else {
            list = try await GoogleTasksAPI.createList(title: TasksStore.notesListTitle)
        }
        listID = list.id
        return list.id
    }
}

struct NotesView: View {
    @ObservedObject private var store = NotesStore.shared
    @ObservedObject private var auth = GoogleAuth.shared

    var body: some View {
        HStack(spacing: 10) {
            sidebar
            editor
        }
        .task { await store.sync() }
        .onAppear { IslandFocus.allowsKey = true }
        .onDisappear {
            IslandFocus.allowsKey = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            store.scheduleSync(after: 0)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    store.add()
                } label: {
                    Label("Neue Notiz", systemImage: "plus")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(IslandTileStyle())

                if auth.isConnected {
                    Image(systemName: store.syncError != nil ? "exclamationmark.icloud" : store.isSyncing ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud")
                        .font(.caption)
                        .foregroundStyle(store.syncError != nil ? .red : .secondary)
                        .help(store.syncError ?? (store.isSyncing ? "Gleiche mit Google ab …" : "Mit Google Tasks abgeglichen (Liste „\(TasksStore.notesListTitle)“)"))
                        .padding(.trailing, 4)
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.notes) { note in
                        Button {
                            store.selectedID = note.id
                        } label: {
                            Text(note.title)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(store.selectedID == note.id ? .white : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(store.selectedID == note.id ? 0.12 : 0))
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Notiz löschen") { store.delete(note) }
                        }
                    }
                }
            }
        }
        .frame(width: 150)
    }

    @ViewBuilder
    private var editor: some View {
        if store.selectedID == nil {
            IslandEmptyState(icon: "note.text", text: "Noch keine Notiz")
        } else {
            TextEditor(text: store.selectedText)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        }
    }
}
