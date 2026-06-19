import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Recording status card
            HStack(spacing: 8) {
                Circle()
                    .fill(app.isRecording ? .red : .secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.isRecording
                         ? "Recording — \(app.detector.activeApp?.name ?? "Manual")"
                         : "Not recording")
                        .font(.system(size: 13, weight: .semibold))
                    if app.isRecording {
                        Text(timerLabel).font(.caption).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Button(app.isRecording ? "Stop" : "Record") {
                    app.isRecording
                        ? app.stopRecording()
                        : app.startRecording(detectedApp: app.detector.activeApp)
                }
                .buttonStyle(.borderedProminent)
                .tint(app.isRecording ? .red : .accentColor)
                .controlSize(.small)
            }
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))

            if let err = app.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()

            Text("Recent").font(.caption).foregroundStyle(.secondary)
            ForEach(app.meetings.prefix(3)) { meeting in
                HStack {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary).font(.caption)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(shortMenuTitle(meeting.title))
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Text("\(meeting.appName) · \(meeting.durationLabel)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Divider()

            HStack {
                Button("Open LokalBotV1...") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                Button("Permissions...") { openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if app.settings.trackingEnabled {
                    Button(app.sampler.isPaused ? "Resume tracking" : "Pause tracking") {
                        app.sampler.isPaused.toggle()
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    Button("Capture now") { app.screenshots.captureNow() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var timerLabel: String {
        let s = Int(app.elapsed)
        return String(format: "%02d:%02d elapsed", s / 60, s % 60)
    }

    private func shortMenuTitle(_ title: String) -> String {
        let limit = 30
        guard title.count > limit else { return title }
        let end = title.index(title.startIndex, offsetBy: limit - 3)
        return String(title[..<end]) + "..."
    }
}
