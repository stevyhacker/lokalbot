import SwiftUI

struct DictationView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var permissions = PermissionManager.shared

    var body: some View {
        Form {
            statusSection
            shortcutSection
            outputSection
            modelSection
            if app.settings.dictationEnabled { permissionsSection }
            if let transcript = app.dictation.lastTranscript {
                lastTranscriptSection(transcript)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .navigationTitle("Dictation")
        .onAppear {
            permissions.startPolling()
            app.dictation.applySettings()
        }
        .onDisappear { permissions.stopPolling() }
        .onChange(of: permissions.granted) { _, _ in
            app.dictation.applySettings()
        }
    }

    private var statusSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dictation").font(.headline)
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(actionTitle) { app.dictation.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(app.dictation.state.isRecording ? .red : .accentColor)
            }
            Toggle("Enable global shortcut", isOn: $app.settings.dictationEnabled)
        }
    }

    private var shortcutSection: some View {
        Section("Shortcut") {
            LabeledContent("Shortcut") {
                Text(DictationShortcut.label)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Picker("Trigger", selection: $app.settings.dictationTriggerMode) {
                ForEach(DictationTriggerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Toggle("Show floating pill", isOn: $app.settings.dictationShowOverlay)
            Toggle("Show live transcript while dictating", isOn: $app.settings.dictationLivePreview)
                .disabled(!app.settings.dictationShowOverlay)
            Text("Live preview uses the selected transcription model. The final paste still comes from the full recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        Section("Output") {
            Picker("After transcription", selection: $app.settings.dictationOutputMode) {
                ForEach(DictationOutputMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Toggle("Keep dictation audio files", isOn: $app.settings.dictationRetainAudio)
            Text("Audio is otherwise deleted after the text is delivered.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Transcription") {
                Text(app.settings.transcriptionModel.rawValue)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Language") {
                Text(app.settings.transcriptionLanguage.displayName)
                    .foregroundStyle(.secondary)
            }
            Text("Dictation uses the same local ASR selection as meeting transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow(.microphone, why: "Records your voice for the current dictation.")
            permissionRow(.inputMonitoring, why: "Detects the global dictation shortcut.")
            permissionRow(.accessibility, why: "Pastes the transcript into the focused app.")
            if !app.dictation.isShortcutMonitoringActive {
                Text("After granting Input Monitoring, quit and reopen LokalBot if the shortcut is still inactive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func lastTranscriptSection(_ transcript: String) -> some View {
        Section("Last transcript") {
            Text(transcript)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let engine = app.dictation.lastEngine {
                Text(engine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ permission: AppPermission, why: String) -> some View {
        let granted = permissions.granted[permission] ?? permission.isGranted
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…") {
                    PermissionManager.shared.request(permission)
                    PermissionManager.shared.openSettings(for: permission)
                }
            }
        }
    }

    private var statusText: String {
        switch app.dictation.state {
        case .idle:
            if app.settings.dictationEnabled {
                return app.dictation.isShortcutMonitoringActive
                    ? "Ready — hold \(DictationShortcut.label) to dictate."
                    : "Shortcut inactive."
            }
            return "Ready from this screen. Turn on the shortcut for system-wide use."
        case .recording:
            return "Listening \(app.dictation.timerLabel)"
        case .transcribing:
            return "Transcribing \(app.dictation.timerLabel)"
        }
    }

    private var actionTitle: String {
        switch app.dictation.state {
        case .idle: "Start"
        case .recording: "Stop & Paste"
        case .transcribing: "Cancel"
        }
    }
}
