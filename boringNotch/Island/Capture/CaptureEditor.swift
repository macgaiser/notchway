//
//  CaptureEditor.swift
//  boringNotch
//
//  The window that opens after a capture: view, mark up, copy and save.
//

import AVKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Marks

enum MarkTool: String, CaseIterable, Identifiable {
    case pen, marker, arrow, rectangle, ellipse, text, stamp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Stift"
        case .marker: "Textmarker"
        case .arrow: "Pfeil"
        case .rectangle: "Rechteck"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .stamp: "Symbol"
        }
    }

    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .stamp: "seal"
        }
    }
}

struct Mark: Identifiable {
    let id = UUID()
    var tool: MarkTool
    /// Image points, measured from the top-left corner.
    var points: [CGPoint]
    var color: Color
    var width: CGFloat
    var text = ""
    /// SF Symbol name, or "#" followed by a number for a numbered badge.
    var symbol = ""

    func draw(in context: inout GraphicsContext, factor: CGFloat) {
        guard let first = points.first, let last = points.last else { return }
        let start = CGPoint(x: first.x * factor, y: first.y * factor)
        let end = CGPoint(x: last.x * factor, y: last.y * factor)
        let line = width * factor
        let style = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)

        switch tool {
        case .pen, .marker:
            var path = Path()
            path.move(to: start)
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * factor, y: point.y * factor))
            }
            if points.count == 1 { path.addLine(to: CGPoint(x: start.x + 0.1, y: start.y)) }
            if tool == .marker {
                context.stroke(path, with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: line * 4, lineCap: .square, lineJoin: .round))
            } else {
                context.stroke(path, with: .color(color), style: style)
            }

        case .arrow:
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(12 * factor, line * 4)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                path.move(to: end)
                path.addLine(to: CGPoint(x: end.x + head * cos(angle + offset), y: end.y + head * sin(angle + offset)))
            }
            context.stroke(path, with: .color(color), style: style)

        case .rectangle, .ellipse:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            let path = tool == .rectangle ? Path(roundedRect: rect, cornerRadius: 3 * factor) : Path(ellipseIn: rect)
            context.stroke(path, with: .color(color), style: style)

        case .text:
            let size = (10 + width * 3) * factor
            // Same origin as the text field used while typing.
            context.draw(
                Text(text).font(.system(size: size, weight: .semibold)).foregroundColor(color),
                at: start, anchor: .topLeading
            )

        case .stamp:
            let size = (22 + width * 4) * factor
            let rect = CGRect(x: start.x - size / 2, y: start.y - size / 2, width: size, height: size)
            if symbol.hasPrefix("#") {
                context.fill(Path(ellipseIn: rect), with: .color(color))
                context.draw(
                    Text(String(symbol.dropFirst())).font(.system(size: size * 0.58, weight: .bold, design: .rounded)).foregroundColor(.white),
                    at: start, anchor: .center
                )
            } else {
                var resolved = context.resolve(Image(systemName: symbol))
                resolved.shading = .color(color)
                let ratio = resolved.size.height > 0 ? resolved.size.width / resolved.size.height : 1
                let fitted = ratio >= 1
                    ? CGRect(x: rect.minX, y: rect.midY - size / ratio / 2, width: size, height: size / ratio)
                    : CGRect(x: rect.midX - size * ratio / 2, y: rect.minY, width: size * ratio, height: size)
                context.draw(resolved, in: fitted)
            }
        }
    }
}

@MainActor
final class CaptureEditorModel: ObservableObject {
    let image: CGImage
    let scale: CGFloat

    @Published var marks: [Mark] = []
    @Published var current: Mark?
    @Published var tool: MarkTool = .pen
    @Published var color: Color = .red
    @Published var width: CGFloat = 3
    @Published var text = ""
    /// Where text is being typed right now, in image points.
    @Published var textEntry: CGPoint?
    private var pendingTextLocation: CGPoint = .zero
    @Published var symbol = "checkmark.circle.fill"
    @Published var notice: String?
    @Published var recognizedText: String?

    static let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]
    static let symbols = ["#", "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "questionmark.circle.fill", "star.fill", "heart.fill", "hand.point.up.left.fill", "arrowshape.right.fill"]

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = max(1, scale)
    }

    /// Size of the shot in points, as it appeared on screen.
    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    private var nextNumber: Int {
        marks.filter { $0.symbol.hasPrefix("#") }.count + 1
    }

    // MARK: Drawing input

    func dragChanged(start: CGPoint, location: CGPoint) {
        if tool == .text {
            pendingTextLocation = location
            return
        }
        if current == nil {
            var mark = Mark(tool: tool, points: [start], color: color, width: width)
            mark.text = text
            mark.symbol = symbol == "#" ? "#\(nextNumber)" : symbol
            current = mark
        }
        switch tool {
        case .pen, .marker: current?.points.append(location)
        case .stamp: current?.points = [location]
        default: current?.points = [start, location]
        }
    }

    func dragEnded() {
        if tool == .text {
            // A click finishes the text being typed and starts a new one at that spot.
            commitText()
            textEntry = pendingTextLocation
            return
        }
        defer { current = nil }
        guard let mark = current else { return }
        notice = nil
        marks.append(mark)
    }

    /// Turns the text being typed into a mark.
    func commitText() {
        defer {
            textEntry = nil
            text = ""
        }
        guard let location = textEntry, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var mark = Mark(tool: .text, points: [location], color: color, width: width)
        mark.text = text
        marks.append(mark)
    }

    var textSize: CGFloat { 10 + width * 3 }

    func undo() {
        if textEntry != nil {
            textEntry = nil
            text = ""
        } else if !marks.isEmpty {
            marks.removeLast()
        }
    }

    // MARK: Output

    func rendered() -> CGImage {
        commitText()
        guard !marks.isEmpty else { return image }
        let renderer = ImageRenderer(content: MarkedImage(model: self, showCurrent: false).frame(width: pointSize.width, height: pointSize.height))
        renderer.scale = scale
        return renderer.cgImage ?? image
    }

    private func pngData() -> Data? {
        NSBitmapImageRep(cgImage: rendered()).representation(using: .png, properties: [:])
    }

    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return "Bildschirmfoto \(formatter.string(from: Date())).png"
    }

    func copy() {
        let result = rendered()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: result, size: pointSize)])
        notice = "In die Zwischenablage kopiert."
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.fileName()
        guard panel.runModal() == .OK, let url = panel.url, let data = pngData() else { return }
        do {
            try data.write(to: url, options: .atomic)
            notice = "Gesichert: \(url.lastPathComponent)"
        } catch {
            notice = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func sendToShelf() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.fileName())
        guard let data = pngData(), (try? data.write(to: url, options: .atomic)) != nil,
              let provider = NSItemProvider(contentsOf: url) else {
            notice = "Ablegen fehlgeschlagen."
            return
        }
        ShelfStateViewModel.shared.load([provider])
        notice = "In die Ablage der Island gelegt."
    }

    func recognizeText() {
        let source = image
        notice = "Erkenne Text …"
        Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: source).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            await MainActor.run {
                self.notice = lines.isEmpty ? "Kein Text gefunden." : nil
                self.recognizedText = lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
        }
    }
}

/// The shot with its marks. Also used off-screen to produce the final image.
struct MarkedImage: View {
    @ObservedObject var model: CaptureEditorModel
    var showCurrent = true

    var body: some View {
        Canvas { context, size in
            let factor = size.width / max(1, model.pointSize.width)
            context.draw(Image(decorative: model.image, scale: 1), in: CGRect(origin: .zero, size: size))
            for mark in model.marks {
                mark.draw(in: &context, factor: factor)
            }
            if showCurrent, let current = model.current {
                current.draw(in: &context, factor: factor)
            }
        }
    }
}

// MARK: - Image editor

struct CaptureImageEditor: View {
    @StateObject var model: CaptureEditorModel
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                let available = CGSize(width: max(1, geometry.size.width - 32), height: max(1, geometry.size.height - 32))
                let factor = min(available.width / model.pointSize.width, available.height / model.pointSize.height, 2)
                let size = CGSize(width: model.pointSize.width * factor, height: model.pointSize.height * factor)

                MarkedImage(model: model)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                model.dragChanged(
                                    start: CGPoint(x: value.startLocation.x / factor, y: value.startLocation.y / factor),
                                    location: CGPoint(x: value.location.x / factor, y: value.location.y / factor)
                                )
                            }
                            .onEnded { _ in model.dragEnded() }
                    )
                    .overlay(alignment: .topLeading) {
                        if let entry = model.textEntry {
                            TextField("", text: $model.text, prompt: Text("Text …").foregroundColor(model.color.opacity(0.55)))
                                .textFieldStyle(.plain)
                                .font(.system(size: model.textSize * factor, weight: .semibold))
                                .foregroundStyle(model.color)
                                .focused($typing)
                                .frame(width: max(80, size.width - entry.x * factor - 6), alignment: .leading)
                                .overlay(alignment: .bottomLeading) {
                                    Rectangle().fill(model.color.opacity(0.6)).frame(height: 1).offset(y: 2)
                                }
                                .offset(x: entry.x * factor, y: entry.y * factor)
                                .onSubmit { model.commitText() }
                                .onAppear { typing = true }
                                .id("\(entry.x)-\(entry.y)")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            statusBar
        }
        .frame(minWidth: 780, minHeight: 460)
        .onChange(of: model.tool) { _, _ in model.commitText() }
        .sheet(isPresented: Binding(get: { model.recognizedText != nil }, set: { if !$0 { model.recognizedText = nil } })) {
            RecognizedTextSheet(text: model.recognizedText ?? "") { model.recognizedText = nil }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            // Row 1: what to draw with.
            HStack(spacing: 10) {
                Picker("Werkzeug", selection: $model.tool) {
                    ForEach(MarkTool.allCases) { tool in
                        Image(systemName: tool.icon).help(tool.title).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if model.tool == .stamp {
                    Picker("Symbol", selection: $model.symbol) {
                        ForEach(CaptureEditorModel.symbols, id: \.self) { symbol in
                            if symbol == "#" {
                                Label("Nummer (zählt hoch)", systemImage: "number.circle.fill").tag(symbol)
                            } else {
                                Image(systemName: symbol).tag(symbol)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                HStack(spacing: 5) {
                    ForEach(CaptureEditorModel.palette, id: \.self) { color in
                        Circle()
                            .fill(color)
                            .frame(width: 17, height: 17)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(model.color == color ? 0.9 : 0.25), lineWidth: model.color == color ? 2.5 : 1))
                            .onTapGesture { model.color = color }
                    }
                }
                .fixedSize()

                Slider(value: $model.width, in: 1...12)
                    .frame(width: 90)
                    .help("Strichstärke und Größe")

                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.marks.isEmpty && model.textEntry == nil)
                .help("Letzte Markierung zurücknehmen (⌘Z)")

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    IconActionButton(title: "Text erkennen", icon: "text.viewfinder") { model.recognizeText() }
                    IconActionButton(title: "In Ablage", icon: "tray.and.arrow.down") { model.sendToShelf() }
                    IconActionButton(title: "Kopieren", icon: "doc.on.doc") { model.copy() }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    IconActionButton(title: "Sichern", icon: "square.and.arrow.down", prominent: true) { model.save() }
                        .keyboardShortcut("s", modifiers: .command)
                }
                .fixedSize()
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        // Above the picture, so the hover labels are not covered by it.
        .zIndex(1)
    }

    private var statusBar: some View {
        HStack {
            Text(model.notice ?? (model.tool == .text ? "Ins Bild klicken und lostippen. Enter schließt ab." : "Das unbearbeitete Bild liegt bereits in der Zwischenablage."))
                .lineLimit(1)
            Spacer()
            Text("\(model.image.width) × \(model.image.height) Pixel")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

private struct RecognizedTextSheet: View {
    @State var text: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Erkannter Text").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 460, minHeight: 240)
            HStack {
                Spacer()
                Button("Schließen", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

// MARK: - Video viewer

struct CaptureVideoViewer: View {
    let url: URL
    @State private var player: AVPlayer
    @State private var notice: String?

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .frame(minWidth: 560, minHeight: 320)
            Divider()
            HStack {
                Text(notice ?? url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    IconActionButton(title: "Kopieren", icon: "doc.on.doc", edge: .top) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([url as NSURL])
                        notice = "Videodatei in die Zwischenablage kopiert."
                    }
                    IconActionButton(title: "In Ablage", icon: "tray.and.arrow.down", edge: .top) {
                        if let provider = NSItemProvider(contentsOf: url) {
                            ShelfStateViewModel.shared.load([provider])
                            notice = "In die Ablage der Island gelegt."
                        }
                    }
                    IconActionButton(title: "Sichern", icon: "square.and.arrow.down", prominent: true, edge: .top) { save() }
                        .keyboardShortcut("s", modifiers: .command)
                }
                .fixedSize()
                .layoutPriority(1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 18)
            .padding(.vertical, 8)
            // Above the player, so the hover labels are not covered by it.
            .zIndex(1)
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
            notice = "Gesichert: \(target.lastPathComponent)"
        } catch {
            notice = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

// MARK: - Windows

/// Opens and keeps track of the capture windows. While one is open, the app shows in the Dock.
@MainActor
final class CaptureWindows: NSObject, NSWindowDelegate {
    static let shared = CaptureWindows()

    private var windows: [NSWindow] = []

    func show(_ capture: CapturedImage) {
        let model = CaptureEditorModel(image: capture.image, scale: capture.scale)
        // Room for the shot plus toolbar, within what fits on screen.
        let content = CGSize(width: model.pointSize.width + 32, height: model.pointSize.height + 32 + 80)
        present(CaptureImageEditor(model: model), title: "Bildschirmfoto", size: content)
    }

    func show(video url: URL) {
        present(CaptureVideoViewer(url: url), title: "Bildschirmvideo", size: CGSize(width: 900, height: 600))
    }

    private func present(_ view: some View, title: String, size: CGSize) {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fitted = CGSize(
            width: min(max(size.width, 800), visible.width * 0.9),
            height: min(max(size.height, 500), visible.height * 0.9)
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: fitted),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(fitted)
        window.center()
        // Several shots in a row should not stack exactly on top of each other.
        let offset = CGFloat(windows.count % 6) * 24
        window.setFrameOrigin(CGPoint(x: window.frame.minX + offset, y: window.frame.minY - offset))
        window.delegate = self
        windows.append(window)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === closing }
        closing.contentView = nil
        // Back to a background app once nothing of ours is open any more.
        let othersOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        if windows.isEmpty, !othersOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
