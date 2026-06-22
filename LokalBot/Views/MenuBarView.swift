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
            Text("\(Image(systemName: "record.circle.fill")) \(app.menuBarTimer)")
                .monospacedDigit()
        } else {
            Image(systemName: "waveform.circle")
        }
    }
}

/// The dropdown shown when the menu bar item is clicked. The primary surface for
/// running LokalBotV3 without ever opening the main window: live recording state,
/// the record/stop control, recent meetings, and app actions (Settings, Quit).
struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard

            if let error = app.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }

            if !PermissionManager.shared.allGranted {
                Button { WindowAccess.shared.open("onboarding") } label: {
                    Label("Grant permissions to record", systemImage: "exclamationmark.shield.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
            }

            Divider()
            recentSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            // Register so non-View code (AppDelegate reopen, AppState first-run
            // onboarding) can open windows even when none are on screen.
            WindowAccess.shared.register { openWindow(id: $0) }
            pulse = app.isRecording
        }
        .onChange(of: app.isRecording) { _, recording in pulse = recording }
    }

    // MARK: Recording status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.isRecording ? "Recording" : "Not recording")
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }

            if app.isRecording {
                Text(app.menuBarTimer)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Label(audioSourceLabel, systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button {
                app.isRecording
                    ? app.stopRecording()
                    : app.startRecording(detectedApp: app.detector.activeApp, source: "menubar")
            } label: {
                Label(app.isRecording ? "Stop recording" : "Record now",
                      systemImage: app.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(app.isRecording ? .red : .accentColor)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(app.isRecording ? Color.red.opacity(0.35) : Color.clear))
    }

    /// Solid dot, with an expanding ring that pulses while recording.
    private var statusDot: some View {
        Circle()
            .fill(app.isRecording ? Color.red : Color.secondary.opacity(0.4))
            .frame(width: 11, height: 11)
            .overlay {
                if app.isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.55), lineWidth: 3)
                        .scaleEffect(pulse ? 2.4 : 1)
                        .opacity(pulse ? 0 : 0.7)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                   value: pulse)
                }
            }
    }

    private var statusSubtitle: String {
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

    private var audioSourceLabel: String {
        (app.currentMeeting?.hasSystemTrack ?? false)
            ? "Microphone + system audio"
            : "Microphone only"
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if app.meetings.isEmpty {
                Text("No meetings yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(app.meetings.prefix(3)) { meeting in
                    Button {
                        app.navSection = .meetings
                        app.selectedMeetingIDs = [meeting.id]
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
            Button("Open LokalBotV3") { WindowAccess.shared.open("main") }
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

    private func shortMenuTitle(_ title: String) -> String {
        let limit = 30
        guard title.count > limit else { return title }
        let end = title.index(title.startIndex, offsetBy: limit - 3)
        return String(title[..<end]) + "..."
    }
}
