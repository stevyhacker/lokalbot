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
            if let result = app.dictation.lastComposedText {
                lastResultSection(result)
            } else if let transcript = app.dictation.lastTranscript {
                lastSpokenRequestSection(transcript)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .accessibilityIdentifier("dictation.form")
        .onAppear {
            permissions.startPolling()
            app.dictation.applySettings()
        }
        .onDisappear {
            permissions.stopPolling()
            PermissionGuidanceController.shared.dismiss()
        }
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
                .accessibilityIdentifier("dictation.enabled")
            Text("Speak the text you want, or ramble an instruction. LokalBot always composes the final wording and can use the focused window as context.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("Live preview shows the speech transcript. The final result is composed from the full recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        Section("Output") {
            Picker("After composing", selection: $app.settings.dictationOutputMode) {
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
                Text(app.settings.transcriptionModel.displayName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Language") {
                Text(app.settings.transcriptionLanguage.displayName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Compose") {
                Text(app.settings.summarizerBackend.displayName)
                    .foregroundStyle(.secondary)
            }
            Text("Speech uses the meeting ASR model; final wording uses the Main LLM and your Cotyping writing profile. If Main LLM is remote, spoken and screen text follow that approved backend setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            PermissionRow(permission: .microphone, why: "Records your voice for the current dictation.")
            PermissionRow(permission: .inputMonitoring, why: "Detects the global dictation shortcut.")
            PermissionRow(permission: .accessibility, why: "Validates the focused field and inserts the composed text safely.")
            PermissionRow(permission: .screenRecording, why: "Optionally reads only the focused window for this request. The image and OCR text are never stored.")
            if !app.dictation.isShortcutMonitoringActive {
                HStack {
                    Text("Relaunch after granting Input Monitoring if the shortcut is still inactive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch") { PermissionManager.relaunch() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func lastResultSection(_ result: String) -> some View {
        Section("Last composed text") {
            Text(result)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let spoken = app.dictation.lastTranscript {
                Text("Spoken request: \(spoken)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let engine = app.dictation.lastEngine {
                Text(engine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func lastSpokenRequestSection(_ transcript: String) -> some View {
        Section("Last spoken request") {
            Text(transcript)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusText: String {
        switch app.dictation.state {
        case .idle:
            if app.settings.dictationEnabled {
                return app.dictation.isShortcutMonitoringActive
                    ? "Ready — hold \(DictationShortcut.label) to compose."
                    : "Shortcut inactive."
            }
            return "Ready from this screen. Turn on the shortcut for system-wide use."
        case .recording:
            return "Listening \(app.dictation.timerLabel)"
        case .transcribing:
            return "Transcribing \(app.dictation.timerLabel)"
        case .composing:
            return "Composing \(app.dictation.timerLabel)"
        }
    }

    private var actionTitle: String {
        switch app.dictation.state {
        case .idle: "Start"
        case .recording: "Stop & Compose"
        case .transcribing, .composing: "Cancel"
        }
    }
}
