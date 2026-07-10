import SwiftUI
import AppKit

/// The status-bar item itself. When recording it shows a record dot plus a live
/// MM:SS timer so a glance at the menu bar confirms a meeting is being captured
/// — no window required. Idle, it's just the app glyph.
struct MenuBarLabel: View {
    @ObservedObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        glyph
            // The status item is the one view guaranteed to exist at launch in
            // pure menu-bar mode, so register the window opener here — otherwise
            // a Finder/Dock reopen (or first-run onboarding) would queue a
            // request with nothing alive to service it.
            .onAppear { WindowAccess.shared.register { openWindow(id: $0) } }
    }

    @ViewBuilder private var glyph: some View {
        if app.isRecording {
            HStack(spacing: 3) {
                Image(systemName: "record.circle.fill")
                MeetingRecordingTimerText(recording: app.recording)
            }
                .monospacedDigit()
        } else if app.dictation.state.isRecording {
            Text("\(Image(systemName: "mic.circle.fill")) \(app.dictation.menuBarLabel)")
                .monospacedDigit()
        } else if case .transcribing = app.dictation.state {
            Image(systemName: "mic.and.signal.meter.fill")
        } else {
            Image(systemName: "waveform.circle")
        }
    }
}

/// The dropdown shown when the menu bar item is clicked. The primary surface for
/// running LokalBot without ever opening the main window: live recording state,
/// the record/stop control, recent meetings, and app actions (Settings, Quit).
struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var permissions = PermissionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard

            if let error = app.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }

            if !permissions.allGranted {
                Button { WindowAccess.shared.open("onboarding") } label: {
                    Label("Grant permissions to record", systemImage: "exclamationmark.shield.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
            }

            Divider()
            recentSection
            Divider()
            dictationRow
            Divider()
            cotypingRow
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            // Register so non-View code (AppDelegate reopen, AppState first-run
            // onboarding) can open windows even when none are on screen.
            WindowAccess.shared.register { openWindow(id: $0) }
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
    }

    // MARK: Recording status

    private var statusCard: some View {
        HeroPanel(radius: Brand.Radius.panel) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    statusDot
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(statusSubtitle)
                            .font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Spacer()
                    if app.isRecording || app.dictation.state.isRecording {
                        LiveWaveform(barCount: 7, barWidth: 3, maxHeight: 14)
                    }
                }

                if app.isRecording || app.dictation.state.isWorking {
                    primaryTimer
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Label(audioSourceLabel, systemImage: "waveform")
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                }

                Button {
                    if app.isRecording {
                        app.stopRecording()
                    } else if app.dictation.state.isWorking {
                        app.dictation.toggle(source: "menubar")
                    } else {
                        app.startRecording(context: app.recordingContext(for: app.detector.activeApp), source: "menubar")
                    }
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint((app.isRecording || app.dictation.state.isRecording) ? .red : .accentColor)

                if app.isRecording {
                    Button {
                        app.showLiveMeeting()
                    } label: {
                        Label("Live transcript & notes", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.panel)
                .strokeBorder(app.isRecording ? Brand.recording.opacity(0.5) : Color.clear))
    }

    /// Solid dot, with an expanding ring that pulses while recording.
    private var statusDot: some View {
        let live = app.isRecording || app.dictation.state.isRecording
        return StatusDot(color: live ? Brand.recording : Color.secondary.opacity(0.4),
                         size: 11, pulses: live)
    }

    private var statusTitle: String {
        if app.isRecording { return "Recording" }
        switch app.dictation.state {
        case .idle: return "Not recording"
        case .recording: return "Dictating"
        case .transcribing: return "Transcribing"
        }
    }

    private var statusSubtitle: String {
        switch app.dictation.state {
        case .recording:
            return "Release \(DictationShortcut.label) to transcribe"
        case .transcribing:
            return "Preparing text for the focused app"
        case .idle:
            break
        }
        if app.isRecording {
            return app.currentMeeting?.title ?? "In progress"
        }
        if let detected = app.detector.activeApp {
            return "\(detected.name) detected — ready"
        }
        switch app.settings.autoRecordMode {
        case .automatic: return "Auto-records detected meetings"
        case .ask: return "Asks before recording meetings"
        case .manual: return "Manual recording only"
        }
    }

    @ViewBuilder private var primaryTimer: some View {
        if app.isRecording {
            MeetingRecordingTimerText(recording: app.recording)
        } else {
            switch app.dictation.state {
            case .idle: Text("00:00")
            case .recording: Text(app.dictation.timerLabel)
            case .transcribing: Text("...")
            }
        }
    }

    private var primaryActionTitle: String {
        if app.isRecording { return "Stop recording" }
        switch app.dictation.state {
        case .idle: return "Record now"
        case .recording: return "Stop & paste"
        case .transcribing: return "Cancel dictation"
        }
    }

    private var primaryActionIcon: String {
        if app.isRecording { return "stop.fill" }
        switch app.dictation.state {
        case .idle: return "record.circle"
        case .recording: return "stop.fill"
        case .transcribing: return "xmark.circle"
        }
    }

    private var audioSourceLabel: String {
        if app.dictation.state.isWorking {
            return "Microphone dictation"
        }
        return (app.currentMeeting?.hasSystemTrack ?? false)
            ? "Microphone + system audio"
            : "Microphone only"
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "Recent")
            if app.meetings.isEmpty {
                Text("No meetings yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(app.meetings.prefix(3)) { meeting in
                    Button {
                        app.openMeeting(meeting.id)
                        WindowAccess.shared.open("main")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary).font(.caption)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(shortMenuTitle(meeting.title))
                                    .font(.callout).lineLimit(1)
                                Text("\(meeting.appName) · \(meeting.durationLabel)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open LokalBot") { WindowAccess.shared.open("main") }
                .buttonStyle(.plain).foregroundStyle(.tint)
            Button("Settings") {
                app.navSection = .settings
                WindowAccess.shared.open("main")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)

            Spacer()

            if app.settings.trackingEnabled {
                Button {
                    app.sampler.isPaused.toggle()
                } label: {
                    Image(systemName: app.sampler.isPaused ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(app.sampler.isPaused ? "Resume activity tracking" : "Pause activity tracking")
            }

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var cotypingRow: some View {
        Toggle(isOn: $app.settings.cotypingEnabled) {
            Label("Cotyping (inline autocomplete)", systemImage: "text.cursor")
                .font(.callout)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private var dictationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Dictation", systemImage: "mic.badge.plus")
                    .font(.callout)
                Spacer()
                Text(DictationShortcut.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Toggle("Shortcut", isOn: $app.settings.dictationEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer()
                Button {
                    app.dictation.toggle(source: "menubar")
                } label: {
                    Text(dictationButtonTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(app.isRecording && !app.dictation.state.isWorking)
            }
        }
    }

    private var dictationButtonTitle: String {
        switch app.dictation.state {
        case .idle: "Start"
        case .recording: "Stop"
        case .transcribing: "Cancel"
        }
    }

    private func shortMenuTitle(_ title: String) -> String {
        let limit = 30
        guard title.count > limit else { return title }
        let end = title.index(title.startIndex, offsetBy: limit - 3)
        return String(title[..<end]) + "..."
    }
}

/// The recording clock is intentionally observed below AppState so its 1 Hz
/// tick updates only this tiny label instead of every app surface.
struct MeetingRecordingTimerText: View {
    @ObservedObject var recording: RecordingController

    var body: some View {
        Text(recording.menuBarTimer).monospacedDigit()
    }
}
