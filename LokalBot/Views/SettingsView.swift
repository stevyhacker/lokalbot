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
    @StateObject private var permissions = PermissionManager.shared
    @ObservedObject private var metrics = GenerationMetricsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if app.settingsTab == .models && queryIsEmpty {
                ModelsView()
            } else {
                Form {
                    if queryIsEmpty {
                        sections(for: app.settingsTab)
                    } else {
                        searchResults
                    }
                }
                .formStyle(.grouped)
                // Keep this identifier off the enclosing VStack: a container
                // identifier propagates onto every child AX element and
                // clobbers settings.search / settings.tab in the header.
                .accessibilityIdentifier("settings.form")
            }
        }
        .frame(minWidth: 460)
        .navigationTitle("Settings")
        .onAppear {
            power.start()
            permissions.startPolling()
            app.calendar.refreshAuthorizationStatus()
        }
        .onDisappear { power.stop(); permissions.stopPolling() }
    }

    private var queryIsEmpty: Bool {
        settingsQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search field + tab strip, above the tabbed content so search works
    /// from any tab (including Models).
    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search settings…", text: $settingsQuery)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("settings.search")
                if !settingsQuery.isEmpty {
                    Button { settingsQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $app.settingsTab) {
                ForEach(AppState.SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings.tab")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Spec §2.5 tab distribution: SettingsView's existing sections spread
    /// across General · Recording · Privacy · Advanced; Models is ModelsView.
    @ViewBuilder private func sections(for tab: AppState.SettingsTab) -> some View {
        switch tab {
        case .general:
            generalSection; cotypingSection; permissionsSection; storageSection; updatesSection
        case .recording:
            meetingsSection; processingSection; summarizationSection; dayTrackingSection
        case .models:
            EmptyView() // handled by the ModelsView branch in body
        case .privacy:
            privacySection
        case .advanced:
            systemSection; agentCLISection
        }
    }

    /// Spec §2.5: the search field filters across ALL tabs — a non-empty
    /// query shows every matching section regardless of the selected tab,
    /// plus a jump row into the Models tab when its keywords match.
    @ViewBuilder private var searchResults: some View {
        generalSection; cotypingSection; permissionsSection; meetingsSection
        processingSection; summarizationSection; dayTrackingSection; privacySection
        storageSection; updatesSection; systemSection; agentCLISection
        if shows("Models", ["model", "models", "transcription", "summarization",
                            "cotyping", "embeddings", "llm", "whisper", "download",
                            "gguf", "hugging face", "ollama", "engine", "backend"]) {
            Section("Models") {
                Button("Open the Models tab…") {
                    settingsQuery = ""
                    app.settingsTab = .models
                }
                Text("Transcription, main LLM, cotyping, and embedding models live in the Models tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var generalSection: some View {
        if shows("General", ["launch", "login", "startup", "open at login", "auto start",
                                 "menu bar", "menubar", "dock", "dock icon", "hide dock",
                                 "window", "background", "tray"]) {
                Section("General") {
                    LaunchAtLogin.Toggle("Launch LokalBot at login")
                    Text("Start LokalBot automatically so it's ready to catch meetings.")
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

    }

    /// The one everyday cotyping knob kept in Settings; the feature's full
    /// form (enable, model, exclusions, advanced) lives in Type → Cotyping.
    /// Both bind the same setting, so they can never disagree.
    @ViewBuilder private var cotypingSection: some View {
        if shows("Cotyping", ["cotyping", "autocomplete", "suggestion", "suggestions",
                              "length", "words", "max words", "ghost", "inline",
                              "completion", "typing"]) {
            Section("Cotyping") {
                Stepper("Suggestion length: up to \(app.settings.cotypingMaxWords) words",
                        value: $app.settings.cotypingMaxWords, in: 2...50)
                Text("How much text one inline suggestion may add. Everything else about cotyping is in Type → Cotyping.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var permissionsSection: some View {
            if shows("Permissions", ["permission", "grant", "access", "microphone", "mic",
                                     "screen recording", "system audio", "accessibility",
                                     "input monitoring", "keyboard", "relaunch", "tcc"]) {
                Section("Permissions") {
                    PermissionRow(permission: .microphone)
                    PermissionRow(permission: .accessibility,
                                  why: "Optional — window titles for the day timeline and browser-meeting detection.")
                    PermissionRow(permission: .screenRecording,
                                  why: "Optional — only used while screenshot capture (Day tracking) is on. System audio does not need it.")
                    PermissionRow(permission: .inputMonitoring,
                                  why: "Optional — powers the dictation and cotyping shortcuts.")
                    HStack {
                        Text("Accessibility and Input Monitoring grants apply at launch.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch") { PermissionManager.relaunch() }
                    }
                }
            }

    }

    @ViewBuilder private var meetingsSection: some View {
            if shows("Meetings", ["meeting", "auto record", "detect", "debounce", "stop debounce",
                                  "recording", "calendar", "calendar access", "browser", "google meet"]) {
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
                        Stepper(value: $app.settings.stopDebounceSeconds,
                                in: AppSettings.minimumStopDebounceSeconds...AppSettings.maximumStopDebounceSeconds,
                                step: 5) {
                            Text("\(Int(app.settings.stopDebounceSeconds)) s after audio stops")
                                .foregroundStyle(.secondary)
                        }
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

    }

    @ViewBuilder private var processingSection: some View {
            if shows("Processing", ["transcribe", "transcription", "summarize", "summary",
                                    "automatic", "auto", "after meeting", "model", "models", "engine"]) {
                Section("Processing") {
                    Toggle("Transcribe automatically after each meeting", isOn: $app.settings.autoTranscribe)
                    Toggle("Summarize automatically after transcription", isOn: $app.settings.autoSummarize)
                    Text("Choose transcription and main LLM models in the Models tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

    }

    @ViewBuilder private var summarizationSection: some View {
            if shows("Summarization", ["summary", "summarize", "notes", "template", "language",
                                       "diarization", "speaker", "split speaker", "neural"]) {
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

    }

    @ViewBuilder private var dayTrackingSection: some View {
            if shows("Day tracking", ["tracking", "activity", "screenshots", "screen", "capture",
                                      "ocr", "window", "accessibility", "retention", "private",
                                      "excluded apps", "never capture"]) {
                Section("Day tracking") {
                    // Screenshots ride on the activity sampler (ScreenshotService
                    // captures on its block boundaries and guards on BOTH flags),
                    // so the toggles stay coupled the same way onboarding couples
                    // them: screenshots on ⇒ tracking on, tracking off ⇒
                    // screenshots off. Otherwise "on" here would capture nothing.
                    Toggle("Track app & window activity", isOn: Binding(
                        get: { app.settings.trackingEnabled },
                        set: { app.settings.trackingEnabled = $0
                               if $0 { PermissionManager.shared.requestIfNeeded(.accessibility) } else { app.settings.screenshotsEnabled = false }
                               app.applyTrackingSetting() }))
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
                    Toggle("Screen context capture (on app/window switch, OCR'd locally, encrypted at rest)", isOn: Binding(
                        get: { app.settings.screenshotsEnabled },
                        set: { app.settings.screenshotsEnabled = $0
                               if $0 {
                                   app.settings.trackingEnabled = true
                                   PermissionManager.shared.requestIfNeeded(.screenRecording)
                               }
                               app.applyTrackingSetting() }))
                    if app.settings.screenshotsEnabled {
                        Slider(value: Binding(
                            get: { app.settings.screenshotIntervalMinutes },
                            set: { app.settings.screenshotIntervalMinutes = $0; app.screenshots.restart() }),
                            in: 1...15, step: 1) {
                            Text("Idle fallback: at least every \(Int(app.settings.screenshotIntervalMinutes)) min")
                        }
                        Stepper("Keep screenshots \(app.settings.retentionDays) days",
                                value: $app.settings.retentionDays, in: 1...90)
                    }
                    TextField("Never capture (app names, comma-separated)",
                              text: $app.settings.excludedApps)
                    Text("Captures when you switch apps or windows (20 s cooldown, unchanged screens skipped) and at least every few minutes when idle-active; never captures the lock screen. Screenshots are AES-GCM encrypted (key in your Keychain); extracted text follows the same retention (see Privacy). Excluded apps log as “Private”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

    }

    @ViewBuilder private var privacySection: some View {
            if shows("Privacy", ["privacy", "retention", "ocr", "text", "screen text", "history",
                                 "delete", "prune", "forever", "keep", "local", "network",
                                 "data", "security"]) {
                Section("Privacy") {
                    Label("Audio and transcripts never leave this Mac. Network access is localhost (your LLM server) plus user-initiated model downloads from Hugging Face.",
                          systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    Toggle("Keep screen text forever", isOn: Binding(
                        get: { app.settings.keepOCRTextForever },
                        set: { app.settings.keepOCRTextForever = $0
                               if !$0 { app.screenshots.pruneOldScreenshots() } }))
                    Text("Text extracted from screenshots is deleted with the pixels after \(app.settings.retentionDays) days. Turn on to keep it searchable forever; turning back off deletes text older than the window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

    }

    @ViewBuilder private var storageSection: some View {
            if shows("Storage", ["storage", "location", "files", "folder", "finder", "disk"]) {
                Section("Storage") {
                    LabeledContent("Location") {
                        Button(app.storage.rootURL.path(percentEncoded: false)) {
                            NSWorkspace.shared.activateFileViewerSelecting([app.storage.rootURL])
                        }
                        .buttonStyle(.link)
                    }
                }
            }

    }

    @ViewBuilder private var updatesSection: some View {
            if shows("Updates", ["update", "version", "sparkle", "upgrade", "check", "release",
                                 "appcast", "download"]) {
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

    }

    @ViewBuilder private var systemSection: some View {
            if shows("System", ["system", "hardware", "ram", "memory", "chip", "cpu", "battery",
                                "power", "low power", "diagnostics", "performance", "generations"]) {
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

    }

    @ViewBuilder private var agentCLISection: some View {
            if shows("Agent CLI", ["cli", "agent", "terminal", "claude", "codex", "cursor",
                                   "gemini", "symlink", "install", "uninstall", "path"]) {
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
                                Label("Move LokalBot.app to /Applications first",
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
