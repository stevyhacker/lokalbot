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
        } else if app.dictation.state.isWorking {
            Image(systemName: "mic.and.signal.meter.fill")
        } else {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

/// The LokalBot brand mark for the status item: a minimal robot head whose
/// face is a three-bar waveform — "bot" and "listens locally" in one glyph.
/// Drawn in code as a template image so it stays crisp at any backing scale
/// and picks up the menu bar's light/dark/highlight tinting for free.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LokalBot"
        return image
    }()

    private static func draw() {
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Head
        let head = NSBezierPath(
            roundedRect: NSRect(x: 2.5, y: 1.5, width: 13, height: 10.5),
            xRadius: 3, yRadius: 3
        )
        head.lineWidth = 1.5
        head.stroke()

        // Antenna — stem long enough that the knob clearly separates from the head
        let stem = NSBezierPath()
        stem.lineWidth = 1.5
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: 9, y: 12))
        stem.line(to: NSPoint(x: 9, y: 13.9))
        stem.stroke()
        NSBezierPath(ovalIn: NSRect(x: 9 - 1.2, y: 15.4 - 1.2, width: 2.4, height: 2.4)).fill()

        // Waveform face — bars pixel-aligned so 1x rasterization keeps the gaps
        func bar(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: x, y: y0))
            path.line(to: NSPoint(x: x, y: y1))
            path.stroke()
        }
        bar(5.5, 5.2, 7.6)
        bar(9.0, 3.8, 9.3)
        bar(12.5, 5.2, 7.6)
    }
}

/// A narrowly-observed control for pausing day tracking. `AppState` owns the
/// sampler but does not rebroadcast its frequent sample updates, so views that
/// display `isPaused` must observe the sampler directly to refresh immediately.
struct TrackingPauseButton: View {
    enum Presentation {
        case menuBar
        case toolbar
    }

    @ObservedObject var sampler: ActivitySampler
    let presentation: Presentation

    var body: some View {
        switch presentation {
        case .menuBar:
            Button(action: toggle) {
                Image(systemName: sampler.isPaused ? "play.fill" : "pause.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(actionTitle)
            .help(actionTitle)

        case .toolbar:
            Button(action: toggle) {
                Label(actionTitle,
                      systemImage: sampler.isPaused ? "play.fill" : "pause.fill")
            }
            .help(actionTitle)
        }
    }

    private var actionTitle: String {
        sampler.isPaused ? "Resume activity tracking" : "Pause activity tracking"
    }

    private func toggle() {
        sampler.isPaused.toggle()
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
                        // MenuBarExtra keeps this view mounted after its popover
                        // closes, so never leave a display-linked animation here.
                        LiveWaveform(barCount: 7, barWidth: 3, maxHeight: 14,
                                     animated: false)
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

    /// Keep the always-mounted menu extra static while recording. Repeating
    /// SwiftUI animations continue after the popover closes and otherwise
    /// consume the main thread for the duration of a meeting.
    private var statusDot: some View {
        let live = app.isRecording || app.dictation.state.isRecording
        return StatusDot(color: live ? Brand.recording : Color.secondary.opacity(0.4),
                         size: 11)
    }

    private var statusTitle: String {
        if app.isRecording { return "Recording" }
        switch app.dictation.state {
        case .idle: return "Not recording"
        case .recording: return "Dictating"
        case .transcribing: return "Transcribing"
        case .composing: return "Composing"
        }
    }

    private var statusSubtitle: String {
        switch app.dictation.state {
        case .recording:
            return "Release \(DictationShortcut.label) to compose"
        case .transcribing:
            return "Turning speech into a writing request"
        case .composing:
            return "Writing for the focused app"
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
            case .transcribing, .composing: Text("...")
            }
        }
    }

    private var primaryActionTitle: String {
        if app.isRecording { return "Stop recording" }
        switch app.dictation.state {
        case .idle: return "Record now"
        case .recording: return "Stop & compose"
        case .transcribing, .composing: return "Cancel dictation"
        }
    }

    private var primaryActionIcon: String {
        if app.isRecording { return "stop.fill" }
        switch app.dictation.state {
        case .idle: return "record.circle"
        case .recording: return "stop.fill"
        case .transcribing, .composing: return "xmark.circle"
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
            Button {
                WindowAccess.shared.open("quick-recall")
            } label: {
                Label("Recall", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            Button("Open LokalBot") { WindowAccess.shared.open("main") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Settings") {
                app.navSection = .settings
                WindowAccess.shared.open("main")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)

            Spacer()

            if app.settings.trackingEnabled {
                TrackingPauseButton(sampler: app.sampler, presentation: .menuBar)
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
        case .transcribing, .composing: "Cancel"
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
