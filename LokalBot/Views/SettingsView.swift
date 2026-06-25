import SwiftUI
import LaunchAtLogin
import AppKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    @StateObject private var updates = AppUpdateManager.shared
    @State private var cliMessage: String?

    // Settings search + live system readouts.
    @State private var settingsQuery = ""
    @StateObject private var power = PowerSourceMonitor()
    @ObservedObject private var metrics = GenerationMetricsStore.shared
    @ObservedObject private var cotypingStats = CotypingStatsStore.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings…", text: $settingsQuery)
                        .textFieldStyle(.plain)
                    if !settingsQuery.isEmpty {
                        Button { settingsQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }

            if shows("General", ["launch", "login", "startup", "open at login", "auto start",
                                 "menu bar", "menubar", "dock", "window", "background", "tray"]) {
                Section("General") {
                    LaunchAtLogin.Toggle("Launch LokalBotV3 at login")
                    Text("Start LokalBotV3 automatically so it's ready to catch meetings.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Menu bar only (hide Dock icon)", isOn: $app.settings.menuBarOnly)
                        .onChange(of: app.settings.menuBarOnly) { _, menuBarOnly in
                            DockPolicy.sync()
                            if !menuBarOnly { openWindow(id: "main") }
                        }
                    Text("Run from the menu bar with a live recording timer — no Dock icon, no window at launch. The window stays one click away. Takes full effect once open windows are closed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("Meetings", ["meeting", "auto record", "detect", "debounce", "recording", "calendar"]) {
                Section("Meetings") {
                    Picker("When a meeting is detected", selection: $app.settings.autoRecordMode) {
                        ForEach(AppSettings.AutoRecordMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    LabeledContent("Detected apps") {
                        Text(Set(MeetingDetector.knownApps.values).sorted().joined(separator: ", ")
                             + " + browser meetings (Meet, Jitsi, Whereby)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Stop debounce") {
                        Text("\(Int(app.settings.stopDebounceSeconds)) s after mic releases")
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Toggle("Use calendar to improve detection", isOn: $app.settings.calendarDetectionEnabled)
                        .onChange(of: app.settings.calendarDetectionEnabled) { _, enabled in
                            if enabled, app.calendar.authorizationStatus == .notDetermined {
                                app.calendar.requestAccess { _ in }
                            }
                        }
                    Text("Reads your Mac Calendar (including Google/Exchange accounts synced into it) to confirm meetings — so a Google Meet in your browser is caught even when its window title is generic.")
                        .font(.caption).foregroundStyle(.secondary)
                    if app.settings.calendarDetectionEnabled {
                        Toggle("Use calendar titles for recordings", isOn: $app.settings.useCalendarTitles)
                        Toggle("Require a calendar match for browser auto-recording", isOn: $app.settings.requireCalendarForBrowser)
                        Text("Stricter: only auto-record a browser tab when a scheduled event with a meeting link is in progress.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Calendar access") { calendarAccessControl }
                    }
                }
            }

            if shows("Processing", ["transcribe", "summarize", "automatic", "auto", "after meeting"]) {
                Section("Processing") {
                    Toggle("Transcribe automatically after each meeting", isOn: $app.settings.autoTranscribe)
                    Toggle("Summarize automatically after transcription", isOn: $app.settings.autoSummarize)
                    Text("Choose transcription and summarization models in the Models section (sidebar → Engine → Models).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("Summarization", ["summary", "summarize", "notes", "template", "language", "diarization", "speaker"]) {
                Section("Summarization") {
                    Picker("Notes template", selection: $app.settings.noteTemplate) {
                        ForEach(NoteTemplate.allCases) { template in
                            Text("\(template.displayName)").tag(template)
                        }
                    }
                    Text(app.settings.noteTemplate.description)
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Notes language", selection: $app.settings.summaryLanguage) {
                        Text("Match transcript (auto)").tag(SummaryLanguage.matchTranscript)
                        Divider()
                        ForEach(SummaryLanguage.presets, id: \.rawValue) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    Toggle("Split \"Them\" by speaker (neural diarization)",
                           isOn: $app.settings.multiSpeakerDiarization)
                    Text("Adds 30–60 s of post-processing per meeting. First run downloads ~100 MB of speaker models from Hugging Face.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("Cotyping", ["cotyping", "autocomplete", "inline", "ghost", "suggestion", "typing", "complete", "tab", "autocorrect"]) {
                Section("Cotyping") {
                    Toggle("Inline AI autocomplete (cotyping)", isOn: $app.settings.cotypingEnabled)
                    Text("Suggests text inline as you type in other apps. Choose its model under Models (it can differ from summarization). Needs Accessibility + Input Monitoring; open the Cotyping tab for setup and a live preview.")
                        .font(.caption).foregroundStyle(.secondary)
                    if app.settings.cotypingEnabled {
                        TextField("Your name (optional — tunes the voice)", text: $app.settings.cotypingUserName)
                        TextField("Writing style (optional, e.g. \u{201c}concise, British spelling\u{201d})", text: $app.settings.cotypingStyleNote)
                        TextField("Languages you write in (optional, e.g. \u{201c}English, German\u{201d})",
                                  text: $app.settings.cotypingLanguages)
                        TextField("Notes / glossary (optional — names, jargon, style)",
                                  text: $app.settings.cotypingExtendedContext, axis: .vertical)
                            .lineLimit(1...3)
                        Toggle("Use a dedicated high-quality cotyping model", isOn: $app.settings.cotypingUseSeparateModel)
                        CotypingModelPreparationView(compact: true)
                        if app.settings.cotypingUseSeparateModel {
                            Picker("Cotyping model", selection: $app.settings.cotypingBuiltInModelID) {
                                ForEach(ModelCatalog.selectableEntries(custom: app.settings.customBuiltInModels)) { entry in
                                    Text(entry.displayName).tag(entry.id)
                                }
                            }
                            Text("Gemma 4 E4B Q5 XL is the recommended quality target; Qwen3.5 2B and LFM2.5 1.2B are smaller latency options.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Learn from accepted completions", isOn: $app.settings.cotypingUseLocalLearning)
                        if app.settings.cotypingUseLocalLearning {
                            Stepper("Use \(app.settings.cotypingLearningExamplesInPrompt) learned examples",
                                    value: $app.settings.cotypingLearningExamplesInPrompt, in: 1...5)
                            CotypingLearningControls(store: app.cotypingLearning)
                        }
                        Stepper("Suggestion length: up to \(app.settings.cotypingMaxWords) words",
                                value: $app.settings.cotypingMaxWords, in: 2...50)
                        Toggle("Allow multi-line suggestions", isOn: $app.settings.cotypingMultiLine)
                        Toggle("Stream suggestions while generating", isOn: $app.settings.cotypingStreamSuggestionsWhileGenerating)
                        Text("When off, suggestions appear once fully formed, matching Cotypist's default. Turn on to show token-by-token partials sooner.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Use app & window context", isOn: $app.settings.cotypingUseAppContext)
                        Text("Conditions suggestions on the focused app and its window title (email subject, chat channel, page title) for sharper, on-topic completions. Read locally via Accessibility; skipped in code editors and terminals.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Use the clipboard as context", isOn: $app.settings.cotypingUseClipboard)
                        Text("Folds what you just copied into the prompt so suggestions can build on it. Read fresh each time and never stored. Off by default — turn on only if you want the model to see your clipboard.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Match the app\u{2019}s font and text color", isOn: $app.settings.cotypingMatchHostStyle)
                        Text("Ghost text mimics the field you\u{2019}re typing in (font family and a dimmed version of its text color) instead of a fixed style. Read locally via Accessibility; cached per field.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Show suggestions", selection: $app.settings.cotypingMirrorPreference) {
                            ForEach(CotypingMirrorPreference.allCases) { Text($0.label).tag($0) }
                        }
                        Text("\u{201c}Automatic\u{201d} draws ghost text inline at the caret, but falls back to a popup below the caret when its geometry is unreliable or the caret is mid-line.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Autocorrect the word you're typing", isOn: $app.settings.cotypingAutocorrect)
                        Text("Spots a misspelled word and offers the fix inline — Tab swaps it. Uses the macOS spell checker (on-device); never touches code, URLs, or numbers.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Emoji autocomplete (\u{201c}:rocket:\u{201d} \u{2192} \u{1f680})", isOn: $app.settings.cotypingEmoji)
                        Toggle("Macros (\u{201c}/5+5\u{201d}, \u{201c}/today\u{201d}, \u{201c}/10km->mi\u{201d})", isOn: $app.settings.cotypingMacros)
                        Text("Type \u{201c}/\u{201d} then an expression — math, dates, unit/currency conversion, or random — and the result shows inline. Accept to swap it in.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Accept next", selection: $app.settings.cotypingAcceptKey) {
                            ForEach(CotypingAcceptKey.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Each accept takes", selection: $app.settings.cotypingAcceptGranularity) {
                            ForEach(CotypingAcceptGranularity.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Accept whole suggestion", selection: $app.settings.cotypingFullAcceptKey) {
                            ForEach(CotypingFullAcceptKey.allCases) { Text($0.label).tag($0) }
                        }
                        Toggle("Paste large / multi-line accepts", isOn: $app.settings.cotypingPasteInsertion)
                        Text("Commits big or multi-line suggestions via paste instead of synthetic keystrokes \u{2014} steadier in some apps. Briefly uses the clipboard, then restores it.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Pause before suggesting") {
                            Text("\(app.settings.cotypingDebounceMs) ms").foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(app.settings.cotypingDebounceMs) },
                            set: { app.settings.cotypingDebounceMs = Int($0) }),
                            in: 20...1000, step: 20)
                        TextField("Never suggest in (app names, comma-separated)",
                                  text: $app.settings.cotypingExcludedApps)
                        Text("Cotyping never runs in password fields. Add apps (or terminals) here to exclude them too.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Never suggest on (websites, comma-separated)",
                                  text: $app.settings.cotypingExcludedDomains)
                        Text("Block cotyping on specific sites (e.g. \u{201c}bank.com\u{201d}). Subdomains included; read locally via Accessibility in browsers.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider().padding(.vertical, 2)
                        LabeledContent("Suggestions generated") {
                            Text("\(cotypingStats.stats.generations)").foregroundStyle(.secondary)
                        }
                        LabeledContent("Accepted") {
                            Text("\(cotypingStats.stats.accepts)  (\(String(format: "%.2f", cotypingStats.stats.acceptsPerGeneration))/gen)").foregroundStyle(.secondary)
                        }
                        LabeledContent("Characters inserted") {
                            Text("\(cotypingStats.stats.charsAccepted)").foregroundStyle(.secondary)
                        }
                        if cotypingStats.stats.errors > 0 {
                            LabeledContent("Failed generations") {
                                Text("\(cotypingStats.stats.errors)").foregroundStyle(.secondary)
                            }
                        }
                        if let avg = cotypingStats.stats.avgLatencyMs {
                            LabeledContent("Generation latency") {
                                Text("avg \(avg) ms · p95 \(cotypingStats.stats.p95LatencyMs ?? avg) · max \(cotypingStats.stats.maxLatencyMs ?? avg)").foregroundStyle(.secondary)
                            }
                        }
                        if cotypingStats.stats != CotypingStats() {
                            Button("Reset cotyping stats", role: .destructive) { cotypingStats.clear() }
                                .font(.caption)
                        }
                    }
                }
            }

            if shows("Day tracking", ["tracking", "activity", "screenshots", "ocr", "window", "accessibility", "retention", "private"]) {
                Section("Day tracking") {
                    Toggle("Track app & window activity", isOn: Binding(
                        get: { app.settings.trackingEnabled },
                        set: { app.settings.trackingEnabled = $0; app.applyTrackingSetting() }))
                    LabeledContent("Window titles") {
                        if ActivitySampler.hasAccessibility {
                            Text("Accessibility granted").foregroundStyle(.secondary)
                        } else {
                            Button("Grant Accessibility access…") {
                                PermissionManager.shared.request(.accessibility)
                                PermissionManager.shared.openSettings(for: .accessibility)
                            }
                        }
                    }
                    Toggle("Periodic screenshots (OCR'd locally, encrypted at rest)", isOn: Binding(
                        get: { app.settings.screenshotsEnabled },
                        set: { app.settings.screenshotsEnabled = $0; app.screenshots.restart() }))
                    if app.settings.screenshotsEnabled {
                        Slider(value: Binding(
                            get: { app.settings.screenshotIntervalMinutes },
                            set: { app.settings.screenshotIntervalMinutes = $0; app.screenshots.restart() }),
                            in: 1...15, step: 1) {
                            Text("Every \(Int(app.settings.screenshotIntervalMinutes)) min")
                        }
                        Stepper("Keep screenshots \(app.settings.retentionDays) days",
                                value: $app.settings.retentionDays, in: 1...90)
                    }
                    TextField("Never capture (app names, comma-separated)",
                              text: $app.settings.excludedApps)
                    Text("Sampled every 5 s, idle-aware (3 min); never captures the lock screen. Screenshots are AES-GCM encrypted (key in your Keychain); extracted text stays searchable after pixels are pruned. Excluded apps log as “Private”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("Storage", ["storage", "location", "files", "folder", "disk"]) {
                Section("Storage") {
                    LabeledContent("Location") {
                        Button(app.storage.rootURL.path(percentEncoded: false)) {
                            NSWorkspace.shared.activateFileViewerSelecting([app.storage.rootURL])
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            if shows("Updates", ["update", "version", "sparkle", "upgrade", "check", "release"]) {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.automaticallyChecksForUpdates = $0 }))
                    LabeledContent("Current version") {
                        Text(AppUpdateManager.currentVersionString).foregroundStyle(.secondary)
                    }
                    Button("Check for Updates…") {
                        AppUpdateManager.shared.checkForUpdates()
                    }
                    .disabled(!updates.isStarted)
                    Text(updates.isStarted
                         ? "Updates are signed and delivered via Sparkle. LokalBot stays local-first — only the appcast and the chosen download are fetched."
                         : "Updater inactive — set the appcast feed URL and Sparkle public key before shipping (see RELEASING.md).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if shows("System", ["system", "hardware", "ram", "memory", "chip", "cpu", "battery", "power", "diagnostics", "performance", "generations"]) {
                Section("System") {
                    LabeledContent("This Mac") {
                        Text(DeviceInfo.snapshot().summaryLine)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if power.isLowPower {
                        Label("Low Power Mode is on — summaries may run slower.", systemImage: "bolt.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if power.isOnBattery {
                        Label("Running on battery.", systemImage: "battery.75")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if metrics.recent.isEmpty {
                        Text("No model generations recorded yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(metrics.recent.reversed().prefix(5))) { metric in
                            LabeledContent(metric.label) {
                                Text(String(format: "%.1fs · ~%d tok · %.0f tok/s",
                                            metric.durationSec, metric.approxTokens, metric.tokensPerSec))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if shows("Agent CLI", ["cli", "agent", "terminal", "claude", "codex", "cursor", "gemini", "symlink", "install"]) {
                Section("Agent CLI") {
                    let installer = LokalBotCLIInstaller.bundled
                    if installer.bundledBinary == nil {
                        Text("This build doesn't ship lokalbot-cli. Build the lokalbot-cli scheme once before opening Settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Status") {
                            if installer.isInstalled {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if !installer.isBundleLocationStable {
                                Label("Move LokalBotV3.app to /Applications first",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            } else {
                                Label("Not installed", systemImage: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button(installer.isInstalled ? "Reinstall…" : "Install for your coding agent…") {
                                cliMessage = nil
                                do {
                                    try installer.install()
                                    cliMessage = "Installed at \(installer.binLink.path(percentEncoded: false))."
                                } catch {
                                    cliMessage = "Install failed: \(error.localizedDescription)"
                                }
                            }
                            .disabled(!installer.isBundleLocationStable)
                            if installer.isInstalled {
                                Button("Uninstall", role: .destructive) {
                                    cliMessage = nil
                                    do {
                                        try installer.uninstall()
                                        cliMessage = "Removed lokalbot-cli symlinks."
                                    } catch {
                                        cliMessage = "Uninstall failed: \(error.localizedDescription)"
                                    }
                                }
                            }
                            if !installer.localBinOnPath {
                                Button("Add ~/.local/bin to PATH") {
                                    cliMessage = nil
                                    do {
                                        try installer.addLocalBinToPath()
                                        cliMessage = "Appended to ~/.zshrc — open a new terminal."
                                    } catch {
                                        cliMessage = error.localizedDescription
                                    }
                                }
                            }
                        }
                        if let cliMessage {
                            Text(cliMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Symlinks the bundled CLI at ~/.local/bin/lokalbot-cli and the skill at ~/.agents/skills/lokalbot-cli. Read-only by design.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if shows("Privacy", ["privacy", "local", "network", "data", "security"]) {
                Section("Privacy") {
                    Label("Audio and transcripts never leave this Mac. Network access is localhost (your LLM server) plus user-initiated model downloads from Hugging Face.",
                          systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .navigationTitle("Settings")
        .onAppear { power.start(); app.calendar.refreshAuthorizationStatus() }
        .onDisappear { power.stop() }
    }

    /// Calendar permission state + action for the Meetings section.
    @ViewBuilder private var calendarAccessControl: some View {
        switch app.calendar.authorizationStatus {
        case .fullAccess:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            Button("Grant Calendar Access…") { app.calendar.requestAccess { _ in } }
        default:
            Button("Open System Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// A section is visible when the search field is empty or its title/keywords
    /// match the query (every query token must appear).
    private func shows(_ title: String, _ keywords: [String]) -> Bool {
        SettingsSearchRanker.matches(query: settingsQuery, haystack: [title] + keywords)
    }

}

private struct CotypingLearningControls: View {
    @ObservedObject var store: CotypingLearningStore

    var body: some View {
        LabeledContent("Learned examples") {
            Text("\(store.exampleCount)").foregroundStyle(.secondary)
        }
        if store.exampleCount > 0 {
            Button("Delete learned writing data", role: .destructive) {
                store.clear()
            }
            .font(.caption)
        }
    }
}
