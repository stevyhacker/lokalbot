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
                .scrollContentBackground(.hidden)
                .background(Color.clear)
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
            app.refreshDreamMemory()
        }
        .onDisappear {
            power.stop()
            permissions.stopPolling()
            PermissionGuidanceController.shared.dismiss()
        }
    }

    private var queryIsEmpty: Bool {
        settingsQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search field + tab strip, above the tabbed content so search works
    /// from any tab (including Models).
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 18) {
                    settingsHeaderTitle
                    Spacer(minLength: 12)
                    settingsSearchField
                        .frame(width: 230)
                }

                VStack(alignment: .leading, spacing: 12) {
                    settingsHeaderTitle
                    settingsSearchField
                }
            }

            Picker("", selection: $app.settingsTab) {
                ForEach(AppState.SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520, alignment: .leading)
            .accessibilityIdentifier("settings.tab")
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var settingsHeaderTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(app.settingsTab.displayName)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.35)
            Text(settingsTabSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settingsSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search settings…", text: $settingsQuery)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("settings.search")
            if !settingsQuery.isEmpty {
                Button { settingsQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .workspaceControl()
    }

    private var settingsTabSubtitle: String {
        switch app.settingsTab {
        case .general:
            "Startup, shortcuts, permissions, storage, and updates."
        case .recording:
            "Meeting capture, processing, summaries, day memory, and routines."
        case .models:
            "Choose and prepare local or remote model backends."
        case .privacy:
            "Control retention, exclusions, encryption, and remote processing."
        case .advanced:
            "Inspect memory health, resources, diagnostics, and Agent CLI."
        }
    }

    /// Spec §2.5 tab distribution: SettingsView's existing sections spread
    /// across General · Recording · Privacy · Advanced; Models is ModelsView.
    @ViewBuilder private func sections(for tab: AppState.SettingsTab) -> some View {
        switch tab {
        case .general:
            generalSection; cotypingSection; permissionsSection; storageSection; updatesSection
        case .recording:
            meetingsSection; processingSection; summarizationSection; dayTrackingSection; routinesSection
            dreamingSection
        case .models:
            EmptyView() // handled by the ModelsView branch in body
        case .privacy:
            privacySection
        case .advanced:
            memoryHealthSection; resourceMonitorSection; systemSection; agentCLISection
        }
    }

    /// Spec §2.5: the search field filters across ALL tabs — a non-empty
    /// query shows every matching section regardless of the selected tab,
    /// plus a jump row into the Models tab when its keywords match.
    @ViewBuilder private var searchResults: some View {
        generalSection; cotypingSection; permissionsSection; meetingsSection
        processingSection; summarizationSection; dayTrackingSection; routinesSection; dreamingSection; privacySection
        storageSection; updatesSection; memoryHealthSection; resourceMonitorSection; systemSection; agentCLISection
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

    @ViewBuilder private var memoryHealthSection: some View {
        if shows("Memory Health", ["health", "capture", "activity", "audio", "ocr",
                                   "accessibility", "retention", "queue", "routines",
                                   "disk", "permissions", "recovery", "diagnostics"]) {
            MemoryHealthSection()
        }
    }

    @ViewBuilder private var resourceMonitorSection: some View {
        if shows("Resource Monitor", ["resource", "usage", "cpu", "memory", "ram",
                                      "footprint", "models", "loaded", "running",
                                      "performance", "diagnostics"]) {
            ResourceMonitorSection()
        }
    }

    @ViewBuilder private var generalSection: some View {
        if shows("General", ["launch", "login", "startup", "open at login", "auto start",
                                 "menu bar", "menubar", "dock", "dock icon", "hide dock",
                                 "window", "background", "tray", "quick recall", "shortcut",
                                 "hotkey", "global search"]) {
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
                    Divider()
                    Toggle("Enable the system-wide Ask shortcut", isOn: $app.settings.quickRecallEnabled)
                    Text("Press \(QuickRecallHotKeyController.shortcutLabel) from any app to search meetings, captured screen text, and saved moments—or ask the assistant without opening the main window. LokalBot registers only this shortcut and does not inspect other keystrokes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

    }

    /// A pointer, not a settings surface: cotyping's one home (enable, model,
    /// suggestions, exclusions, advanced) is Type → Cotyping. This section
    /// only keeps it findable from Settings search.
    @ViewBuilder private var cotypingSection: some View {
        if shows("Cotyping", ["cotyping", "autocomplete", "suggestion", "suggestions",
                              "length", "words", "max words", "ghost", "inline",
                              "completion", "typing"]) {
            Section("Cotyping") {
                LabeledContent("Inline autocomplete") {
                    Button("Open Type → Cotyping") { app.openType(.cotyping) }
                }
                Text("Enable cotyping, pick its model, and tune suggestions in Type → Cotyping — its one home.")
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
                    Text("Only record when everyone has been informed and you have any consent required for the meeting and location.")
                        .font(.caption).foregroundStyle(.secondary)
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
                                      "excluded apps", "never capture", "export", "obsidian",
                                      "logseq", "markdown", "daily note", "vault", "digest",
                                      "journal", "schedule", "prompt"]) {
                Section("Day tracking") {
                    Toggle("Track app & window activity", isOn: Binding(
                        get: { app.settings.trackingEnabled },
                        set: { app.settings.trackingEnabled = $0
                               if $0 {
                                   PermissionGuidanceController.shared.requestAccess(
                                       for: .accessibility)
                               } else {
                                   app.settings.screenContextCaptureMode = .activityOnly
                                   app.settings.screenshotsEnabled = false
                               } }))
                    LabeledContent("Window titles") {
                        if ActivitySampler.hasAccessibility {
                            Text("Accessibility granted").foregroundStyle(.secondary)
                        } else {
                            Button("Grant Accessibility access…") {
                                PermissionGuidanceController.shared.requestAccess(
                                    for: .accessibility)
                            }
                        }
                    }
                    Picker("Screen context", selection: Binding(
                        get: { app.settings.effectiveScreenContextCaptureMode },
                        set: { mode in
                            app.settings.screenContextCaptureMode = mode
                            app.settings.screenshotsEnabled = mode.capturesPixels
                            if mode.capturesText {
                                app.settings.trackingEnabled = true
                                PermissionGuidanceController.shared.requestAccess(
                                    for: .accessibility)
                            }
                            if mode.capturesPixels {
                                PermissionGuidanceController.shared.requestAccess(
                                    for: .screenRecording)
                            }
                        })) {
                        ForEach(AppSettings.ScreenContextCaptureMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Text(app.settings.effectiveScreenContextCaptureMode.detail)
                        .font(.caption).foregroundStyle(.secondary)
                    if app.settings.effectiveScreenContextCaptureMode.capturesText {
                        Slider(value: Binding(
                            get: { app.settings.screenshotIntervalMinutes },
                            set: { app.settings.screenshotIntervalMinutes = $0 }),
                            in: 1...15, step: 1) {
                            Text("Idle fallback: at least every \(Int(app.settings.screenshotIntervalMinutes)) min")
                        }
                        Stepper("Keep screen context \(app.settings.retentionDays) days",
                                value: $app.settings.retentionDays, in: 1...90)
                        TextField("Never capture (domains or URL prefixes, comma-separated)",
                                  text: $app.settings.excludedScreenDomains)
                        Toggle("Allow private/incognito browser windows",
                               isOn: $app.settings.capturePrivateWindows)
                        if app.settings.effectiveScreenContextCaptureMode.capturesPixels {
                            Toggle("Capture low-frequency visual context during meetings",
                                   isOn: $app.settings.meetingVisualContextEnabled)
                            Text("Off by default. When enabled, captures the focused display at most once per minute on meaningful changes and links each frame to the active meeting.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TextField("Never capture (app names, comma-separated)",
                              text: $app.settings.excludedApps)
                    Text(
                        "Captures context after app/window changes, clicks, typing pauses, settled "
                            + "scrolls, or a clipboard-generation change without storing raw keys, "
                            + "pointer positions, or clipboard contents. Accessible text is preferred; "
                            + "local OCR fills gaps. Private windows, excluded domains, secure fields, "
                            + "and detected credentials fail closed. Visuals are encrypted "
                            + "with a key kept in your Mac's Keychain; extracted text follows the same retention "
                            + "(see Privacy). Saved moments retain their encrypted frame and text "
                            + "until you unsave or delete them. Excluded apps log as “Private”."
                    )
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Generate the day digest automatically",
                           isOn: $app.settings.dayDigestAutoEnabled)
                    if app.settings.dayDigestAutoEnabled {
                        Stepper(
                            "Generate at \(String(format: "%02d:00", app.settings.dayDigestHour))",
                            value: $app.settings.dayDigestHour,
                            in: 0...23)
                    }
                    TextField("Digest instructions (optional)",
                              text: $app.settings.dayDigestCustomPrompt,
                              axis: .vertical)
                        .lineLimit(1...3)
                    Text("Writes the Timeline's Day digest to your local journal once the day has activity or finished meetings; a digest you generated earlier is refreshed with the full day. Instructions shape scheduled and manual generation alike.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Export a daily memory note", isOn: Binding(
                        get: { app.settings.dailyMemoryExportEnabled },
                        set: { enabled in
                            app.settings.dailyMemoryExportEnabled = enabled
                            if enabled && app.settings.dailyMemoryExportFolder.isEmpty {
                                chooseDailyExportFolder()
                            }
                        }))
                    if app.settings.dailyMemoryExportEnabled {
                        Picker("Format", selection: $app.settings.dailyMemoryExportFormat) {
                            ForEach(AppSettings.DailyMemoryExportFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        LabeledContent("Folder") {
                            Button(app.settings.dailyMemoryExportFolder.isEmpty
                                   ? "Choose…"
                                   : URL(fileURLWithPath: app.settings.dailyMemoryExportFolder).lastPathComponent) {
                                chooseDailyExportFolder()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Brand.teal)
                        }
                        Stepper(
                            "Refresh at \(String(format: "%02d:00", app.settings.dailyMemoryExportHour))",
                            value: $app.settings.dailyMemoryExportHour,
                            in: 0...23)
                    }
                    Text("Writes one idempotent, unencrypted Markdown file per day with the digest, meeting links, app-time totals, and saved moments. Existing non-LokalBot content is never overwritten.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

    }

    @ViewBuilder private var routinesSection: some View {
        if shows("Routines", ["routine", "automation", "standup", "stand-up", "weekly log",
                              "follow-up", "follow up", "unfinished actions", "journal",
                              "schedule", "history", "local output"]) {
            Section("Routines") {
                Toggle("Enable safe local routines", isOn: Binding(
                    get: { app.settings.memoryRoutinesEnabled },
                    set: { enabled in
                        app.settings.memoryRoutinesEnabled = enabled
                        if enabled && app.settings.memoryRoutineFolder.isEmpty {
                            chooseMemoryRoutineFolder()
                        }
                    }))
                if app.settings.memoryRoutinesEnabled {
                    LabeledContent("Output folder") {
                        Button(app.settings.memoryRoutineFolder.isEmpty
                               ? "Choose…"
                               : URL(fileURLWithPath: app.settings.memoryRoutineFolder).lastPathComponent) {
                            chooseMemoryRoutineFolder()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.teal)
                    }
                    Stepper(
                        "Daily time: \(String(format: "%02d:00", app.settings.memoryRoutineHour))",
                        value: $app.settings.memoryRoutineHour,
                        in: 0...23)
                    Picker("Weekly log day", selection: $app.settings.memoryRoutineWeekday) {
                        ForEach(1...7, id: \.self) { weekday in
                            Text(weekdayName(weekday)).tag(weekday)
                        }
                    }
                    ForEach(AppSettings.MemoryRoutineKind.allCases) { kind in
                        Toggle(kind.displayName, isOn: Binding(
                            get: { app.settings.enabledMemoryRoutines.contains(kind) },
                            set: { enabled in setRoutine(kind, enabled: enabled) }))
                        Text(kind.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Menu("Run now") {
                            ForEach(AppSettings.MemoryRoutineKind.allCases.filter { !$0.isEventDriven }) { kind in
                                Button(kind.displayName) { app.memoryRoutines.runNow(kind) }
                                    .disabled(!app.settings.enabledMemoryRoutines.contains(kind))
                            }
                        }
                        if app.memoryRoutines.isRunning, let kind = app.memoryRoutines.currentKind {
                            ProgressView().controlSize(.small)
                            Text(kind.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !app.memoryRoutines.recentRuns.isEmpty {
                        DisclosureGroup("Recent run history") {
                            ForEach(app.memoryRoutines.recentRuns.prefix(8)) { run in
                                LabeledContent(run.kind.displayName) {
                                    Text(run.status.capitalized + " · "
                                         + run.startedAt.formatted(.relative(presentation: .named)))
                                        .foregroundStyle(run.status == "failed" ? .orange : .secondary)
                                }
                            }
                        }
                    }
                }
                Text("Each routine has a fixed local read scope and writes Markdown only inside the chosen folder. Missed daily/weekly runs catch up after wake, each run stops after 30 seconds, and every attempt is recorded in the local database. Routines cannot execute scripts, contact services, send messages, or change source meetings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var dreamingSection: some View {
        if shows("Dreaming", ["dream", "dreaming", "overnight", "retrospective", "morning",
                              "brief", "memory", "projects", "goals", "pin", "pinned",
                              "downtime", "sleep"]) {
            Section("Dreaming") {
                Toggle("Dream overnight", isOn: Binding(
                    get: { app.settings.dreamingEnabled },
                    set: { app.setDreamingEnabled($0) }))
                if app.settings.dreamingEnabled {
                    Stepper(
                        "Dream after \(String(format: "%02d:00", app.settings.dreamingHour))",
                        value: $app.settings.dreamingHour,
                        in: 0...23)
                    HStack(spacing: 8) {
                        Button("Dream now") { app.dreamNow() }
                            .disabled(app.dreaming.isDreaming || !app.libraryReady)
                        if app.dreaming.isDreaming {
                            ProgressView().controlSize(.small)
                            Text("Dreaming…").font(.caption).foregroundStyle(.secondary)
                        } else if let last = app.dreaming.lastDreamedAt {
                            Text("Last dreamed " + last.formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = app.dreaming.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let memory = app.dreamMemory,
                   !memory.activeProjects.isEmpty || !memory.workGoals.isEmpty {
                    DisclosureGroup("Projects and goals") {
                        Text("Pin items that should never age out, be evicted, or be expired by overnight dreaming.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !memory.activeProjects.isEmpty {
                            Text("Active projects")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(memory.activeProjects, id: \.name) { project in
                                dreamMemoryPinRow(
                                    title: project.name,
                                    detail: project.status,
                                    isPinned: project.pinned,
                                    entry: .project(name: project.name))
                            }
                        }
                        if !memory.workGoals.isEmpty {
                            Text("Current goals")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(memory.workGoals, id: \.text) { goal in
                                dreamMemoryPinRow(
                                    title: goal.text,
                                    detail: goal.horizon,
                                    isPinned: goal.pinned,
                                    entry: .goal(text: goal.text))
                            }
                        }
                    }
                }
                Text("While your Mac is otherwise idle after the chosen hour, LokalBot compiles the previous day — meetings, outcomes, the day digest, and time totals — into a morning retrospective and an evolving structured memory of active projects and goals, shown on Today. "
                     + "Nights the Mac slept through catch up at the next launch. Evidence and generated files stay in the local library. Generation uses your configured Main LLM, so an approved remote backend receives the compiled evidence; if no model is reachable, a plain evidence summary is written instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func dreamMemoryPinRow(
        title: String,
        detail: String,
        isPinned: Bool,
        entry: DreamMemoryEntry
    ) -> some View {
        Toggle(isOn: Binding(
            get: { isPinned },
            set: { app.setDreamMemoryPinned($0, for: entry) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(app.dreaming.isDreaming)
    }

    @ViewBuilder private var privacySection: some View {
            if shows("Privacy", ["privacy", "retention", "ocr", "text", "screen text", "history",
                                 "delete", "prune", "forever", "keep", "local", "network",
                                 "data", "security", "agents", "mcp", "claude", "cli"]) {
                Section("Privacy") {
                    Label("Audio stays on this Mac. Transcripts and other context leave only when you approve a remote inference origin. Other network access is for models, updates, and optional Agent Mode setup.",
                          systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    Toggle("Keep screen text forever", isOn: Binding(
                        get: { app.settings.keepOCRTextForever },
                        set: { app.settings.keepOCRTextForever = $0
                               if !$0 { app.screenshots.pruneOldScreenshots() } }))
                    Text("Captured screen text is deleted with any pixels after \(app.settings.retentionDays) days. Saved moments are retained until you unsave or delete them. Turn on to keep all other screen text searchable forever; turning back off deletes text older than the window.")
                        .font(.caption).foregroundStyle(.secondary)
                    AgentAccessToggleRow(manager: app.agentAccess)
                    ScreenMemoryAccessToggleRow(manager: app.screenMemoryAccess)
                    HStack(spacing: 16) {
                        Link("Privacy Policy", destination: URL(string: "https://www.lokalbot.com/privacy")!)
                        Link("Support", destination: URL(string: "https://www.lokalbot.com/support")!)
                    }
                    .font(.caption)
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
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.teal)
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
                        Text("The command-line helper is not included in this build. Install a current LokalBot release to use Agent CLI access.")
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
                        Text("Symlinks the bundled CLI at ~/.local/bin/lokalbot-cli and the skill into ~/.agents/skills and ~/.claude/skills. Read-only by design.")
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

    private func chooseDailyExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose daily memory export folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !app.settings.dailyMemoryExportFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: app.settings.dailyMemoryExportFolder)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                if app.settings.dailyMemoryExportFolder.isEmpty {
                    app.settings.dailyMemoryExportEnabled = false
                }
                return
            }
            app.settings.dailyMemoryExportFolder = url.path
        }
    }

    private func chooseMemoryRoutineFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose routine output folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !app.settings.memoryRoutineFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: app.settings.memoryRoutineFolder)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                if app.settings.memoryRoutineFolder.isEmpty {
                    app.settings.memoryRoutinesEnabled = false
                }
                return
            }
            app.settings.memoryRoutineFolder = url.path
        }
    }

    private func setRoutine(_ kind: AppSettings.MemoryRoutineKind, enabled: Bool) {
        var values = app.settings.enabledMemoryRoutines
        if enabled {
            if !values.contains(kind) { values.append(kind) }
        } else {
            values.removeAll { $0 == kind }
        }
        app.settings.enabledMemoryRoutines = values
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "Friday" }
        return symbols[weekday - 1]
    }

}

/// Observes the nested manager directly so its published marker state keeps
/// the toggle live without relying on AppState to forward changes.
private struct AgentAccessToggleRow: View {
    @ObservedObject var manager: AgentAccessManager

    var body: some View {
        Group {
            Toggle(
                "Allow external agents to read your meeting library",
                isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.setEnabled($0) }))
            Text("Lets MCP clients and the lokalbot-cli skill (Claude, Cursor, …) list, read, and search your meetings, and ask questions answered by your local model — read-only, localhost only. Off by default; while off, agent tools return an error explaining how to enable this.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ScreenMemoryAccessToggleRow: View {
    @ObservedObject var manager: ScreenMemoryAccessManager

    var body: some View {
        Group {
            Toggle(
                "Allow external agents to read screen memory",
                isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.setEnabled($0) }))
            if manager.isEnabled {
                Picker("Granted history", selection: Binding(
                    get: { manager.profile.scope },
                    set: { manager.setScope($0) })) {
                    ForEach(ScreenMemoryAccessProfile.Scope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                Text(manager.profile.scope.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Separately grants scoped, read-only MCP access to captured text and metadata. Decrypted screenshot pixels are never returned, out-of-scope ids appear missing, and meeting access remains independently controlled above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
