//
//  Pomodoro.swift
//  boringNotch
//
//  Focus timer with alternating work and break phases.
//

import AppKit
import Defaults
import SwiftUI

extension Defaults.Keys {
    static let islandPomodoroWorkMinutes = Key<Int>("islandPomodoroWorkMinutes", default: 25)
    static let islandPomodoroBreakMinutes = Key<Int>("islandPomodoroBreakMinutes", default: 5)
}

@MainActor
final class PomodoroTimer: ObservableObject {
    static let shared = PomodoroTimer()

    enum Phase {
        case work, rest

        var title: String { self == .work ? "Fokus" : "Pause" }
        var color: Color { self == .work ? .orange : .green }
    }

    @Published private(set) var phase: Phase = .work
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var isRunning = false
    @Published private(set) var completedRounds = 0

    private var endDate: Date?
    private var timer: Timer?

    private init() {
        remaining = TimeInterval(Defaults[.islandPomodoroWorkMinutes] * 60)
    }

    var duration: TimeInterval {
        TimeInterval((phase == .work ? Defaults[.islandPomodoroWorkMinutes] : Defaults[.islandPomodoroBreakMinutes]) * 60)
    }

    var progress: Double {
        duration > 0 ? 1 - remaining / duration : 0
    }

    var timeText: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    private func start() {
        // Pick up changed durations when starting from a full, untouched phase.
        if endDate == nil, remaining <= 0 || remaining > duration { remaining = duration }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        endDate = nil
        isRunning = false
    }

    func reset() {
        pause()
        phase = .work
        completedRounds = 0
        remaining = duration
    }

    func skip() {
        let wasRunning = isRunning
        pause()
        advance()
        if wasRunning { start() }
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        guard remaining <= 0 else { return }

        NSSound(named: "Glass")?.play()
        pause()
        advance()
        start()
    }

    private func advance() {
        if phase == .work { completedRounds += 1 }
        phase = phase == .work ? .rest : .work
        remaining = duration
    }
}

struct PomodoroView: View {
    @ObservedObject private var pomodoro = PomodoroTimer.shared

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: pomodoro.progress)
                    .stroke(pomodoro.phase.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: pomodoro.progress)
                Text(pomodoro.timeText)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pomodoro.phase.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(pomodoro.phase.color)
                    Text("Abgeschlossene Runden: \(pomodoro.completedRounds)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    control(pomodoro.isRunning ? "pause.fill" : "play.fill", help: pomodoro.isRunning ? "Pausieren" : "Starten") {
                        pomodoro.toggle()
                    }
                    control("forward.end.fill", help: "Phase überspringen") { pomodoro.skip() }
                    control("arrow.counterclockwise", help: "Zurücksetzen") { pomodoro.reset() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 38, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(IslandTileStyle())
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
        .help(help)
    }
}
