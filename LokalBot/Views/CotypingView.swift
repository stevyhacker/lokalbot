import SwiftUI

/// The Cotyping section — the feature's single home: enable + permissions,
/// a live in-app preview (runs the real pipeline with no system grants),
/// model choice, everyday tuning, privacy exclusions, and an advanced layer
/// for the long tail of behavior knobs.
struct CotypingView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        CotypingContent(coordinator: app.cotyping)
            .environmentObject(app)
    }
}

private struct CotypingContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var coordinator: CotypingCoordinator
    @StateObject private var permissions = PermissionManager.shared
    @ObservedObject private var stats = CotypingStatsStore.shared

    @State private var previewText = "Hi Sarah, thanks for the update. I wanted to follow"
#if LOKALBOT_UI_TEST_HOST
    // Screenshot hooks (Scripts/capture-screenshots.sh): seed the try-it ghost
    // so captures show the feature suggesting (no engine or model present), and
    // skip the permissions rows so the ghost stays above the window fold.
    private static let captureDemo = ProcessInfo.processInfo
        .environment["LOKALBOT_COTYPING_DEMO"] == "1"
    @State private var ghost = captureDemo
        ? " up on the Postgres migration timeline we scoped yesterday." : ""
#else
    private static let captureDemo = false
    @State private var ghost = ""
#endif
    @State private var previewError: String?
    @State private var previewing = false
    @State private var previewTask: Task<Void, Never>?
    @State private var benchmarkSummary: CotypingBenchmarkSummary?
    @State private var benchmarkRunning = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            headerSection
            if app.settings.cotypingEnabled && !Self.captureDemo { permissionsSection }
            previewSection
            modelSection
            if app.settings.cotypingEnabled {
                suggestionsSection
                personalizeSection
                extrasSection
                privacySection
                advancedGateSection
                if showAdvanced {
                    generationSection
                    renderingSection
                    acceptSection
                    activitySection
                }
            }
            benchmarkSection
            tipsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .accessibilityIdentifier("cotyping.form")
        .onAppear { permissions.startPolling() }
        .onDisappear {
            permissions.stopPolling()
            PermissionGuidanceController.shared.dismiss()
            previewTask?.cancel()
        }
        .onChange(of: permissions.granted) { _, _ in
            if app.settings.cotypingEnabled { app.cotyping.applySettings() }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Inline AI autocomplete").font(.headline)
                    Text("As you type in almost any app, a gray suggestion appears next to your cursor. Press \(app.settings.cotypingAcceptKey.label) to accept it, or keep typing to ignore it. Runs on your selected on-device model — nothing leaves this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Toggle("Enable cotyping", isOn: $app.settings.cotypingEnabled)
            statusRow
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusDot(color: statusColor)
            Text(statusText).foregroundStyle(.secondary).font(.callout)
            Spacer()
        }
    }

    private var statusColor: Color {
        guard app.settings.cotypingEnabled else { return .secondary }
        switch coordinator.state {
        case .ready, .generating: return .green
        case .debouncing, .idle: return coordinator.isRunning ? .green : .orange
        case .disabled: return .orange
        case .failed: return .red
        }
    }

    private var statusText: String {
        guard app.settings.cotypingEnabled else { return "Off — turn it on to start suggesting." }
        if coordinator.isRunning {
            return "Active — \(coordinator.state.label.lowercased())"
        }
        return coordinator.state.label
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            PermissionRow(permission: .accessibility,
                          why: "Reads the text and caret position in the field you're typing in.")
            PermissionRow(permission: .inputMonitoring,
                          why: "Notices your keystrokes so it knows when to suggest, and catches the Tab key.")
            if !(permissions.granted[.accessibility] ?? false) {
                HStack {
                    Text("Accessibility access applies after a relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch") { PermissionManager.relaunch() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section("Model") {
            Picker("Cotyping model", selection: $app.settings.cotypingBuiltInModelID) {
                ForEach(ModelCatalog.selectableEntries(custom: app.settings.customBuiltInModels)) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            Text("Cotyping runs its own dedicated model, separate from the Main LLM engine. Gemma 4 · E4B is the recommended quality target; Qwen 3.5 2B and LFM2.5 1.2B are smaller latency options.")
                .font(.caption).foregroundStyle(.secondary)
            CotypingModelPreparationView(compact: true)
        }
    }

    // MARK: Everyday tuning

    private var suggestionsSection: some View {
        Section("Suggestions") {
            LabeledContent("Pause before suggesting") {
                Text("\(app.settings.cotypingDebounceMs) ms").foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(app.settings.cotypingDebounceMs) },
                set: { app.settings.cotypingDebounceMs = Int($0) }),
                in: 20...1000, step: 20)
            Stepper("Suggestion length: up to \(app.settings.cotypingMaxWords) words",
                    value: $app.settings.cotypingMaxWords, in: 2...50)
            Toggle("Allow multi-line suggestions", isOn: $app.settings.cotypingMultiLine)
        }
    }

    private var personalizeSection: some View {
        Section("Personalize") {
            TextField("Your name (optional — tunes the voice)", text: $app.settings.cotypingUserName)
            TextField("Writing style (optional, e.g. \u{201c}concise, British spelling\u{201d})", text: $app.settings.cotypingStyleNote)
            TextField("Languages you write in (optional, e.g. \u{201c}English, German\u{201d})",
                      text: $app.settings.cotypingLanguages)
            TextField("Notes / glossary (optional — names, jargon, style)",
                      text: $app.settings.cotypingExtendedContext, axis: .vertical)
                .lineLimit(1...3)
        }
    }

    private var extrasSection: some View {
        Section("Extras") {
            Toggle("Autocorrect the word you're typing", isOn: $app.settings.cotypingAutocorrect)
            Text("Spots a misspelled word and offers the fix inline — Tab swaps it. Uses the macOS spell checker (on-device); never touches code, URLs, or numbers.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Emoji autocomplete (\u{201c}:rocket:\u{201d} \u{2192} \u{1f680})", isOn: $app.settings.cotypingEmoji)
            Toggle("Macros (\u{201c}/5+5\u{201d}, \u{201c}/today\u{201d}, \u{201c}/10km->mi\u{201d})", isOn: $app.settings.cotypingMacros)
            Text("Type \u{201c}/\u{201d} then an expression — math, dates, unit/currency conversion, or random — and the result shows inline. Accept to swap it in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var privacySection: some View {
        Section("Privacy & exclusions") {
            TextField("Never suggest in (app names, comma-separated)",
                      text: $app.settings.cotypingExcludedApps)
            Text("Cotyping never runs in password fields. Add apps (or terminals) here to exclude them too.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Never suggest on (websites, comma-separated)",
                      text: $app.settings.cotypingExcludedDomains)
            Text("Block cotyping on specific sites (e.g. \u{201c}bank.com\u{201d}). Subdomains included; read locally via Accessibility in browsers.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Suggest in integrated terminals", isOn: $app.settings.cotypingSuggestInIntegratedTerminals)
            Text("Allows VS Code, Cursor, and browser xterm.js terminals. Standalone terminal apps stay off because shell completions conflict with ghost text.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use the clipboard as context", isOn: $app.settings.cotypingUseClipboard)
            Text("Folds what you just copied into the prompt so suggestions can build on it. Read fresh each time and never stored. Off by default — turn on only if you want the model to see your clipboard.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Advanced

    private var advancedGateSection: some View {
        Section {
            Button(showAdvanced ? "Hide advanced options" : "Show advanced options…") {
                withAnimation { showAdvanced.toggle() }
            }
        }
    }

    private var generationSection: some View {
        Section("Generation") {
            Toggle("Stream suggestions while generating", isOn: $app.settings.cotypingStreamSuggestionsWhileGenerating)
            Text("When off, suggestions appear once they are complete. Turn on to show partial suggestions sooner as they are generated.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Use the fast in-process runtime (recommended)", isOn: $app.settings.cotypingInProcessRuntime)
                .disabled(!CotypingEngineSelector.isAppleSilicon)
            Text("Decodes the built-in model in-process for lower latency. Turn off to use the background llama-server. Non-built-in backends always use the server. Requires Apple Silicon.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Learn from accepted completions", isOn: $app.settings.cotypingUseLocalLearning)
            if app.settings.cotypingUseLocalLearning {
                Stepper("Use \(app.settings.cotypingLearningExamplesInPrompt) learned examples",
                        value: $app.settings.cotypingLearningExamplesInPrompt, in: 1...5)
                CotypingLearningControls(store: app.cotypingLearning)
            }
        }
    }

    private var renderingSection: some View {
        Section("Rendering") {
            Toggle("Use app & window context", isOn: $app.settings.cotypingUseAppContext)
            Text("Conditions suggestions on the focused app and its window title (email subject, chat channel, page title) for sharper, on-topic completions. Read locally via Accessibility; skipped in code editors and terminals.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Match the app\u{2019}s font and text color", isOn: $app.settings.cotypingMatchHostStyle)
            Text("Ghost text mimics the field you\u{2019}re typing in (font family and a dimmed version of its text color) instead of a fixed style. Read locally via Accessibility; cached per field.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Show suggestions", selection: $app.settings.cotypingMirrorPreference) {
                ForEach(CotypingMirrorPreference.allCases) { Text($0.label).tag($0) }
            }
            Text("\u{201c}Automatic\u{201d} draws ghost text inline at the caret, but falls back to a popup below the caret when its geometry is unreliable or the caret is mid-line.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var acceptSection: some View {
        Section("Accept & insert") {
            Picker("Accept next", selection: $app.settings.cotypingAcceptKey) {
                ForEach(CotypingAcceptKey.allCases) { Text($0.label).tag($0) }
            }
            Picker("Each accept takes", selection: $app.settings.cotypingAcceptGranularity) {
                ForEach(CotypingAcceptGranularity.allCases) { Text($0.label).tag($0) }
            }
            Picker("Accept whole suggestion", selection: $app.settings.cotypingFullAcceptKey) {
                ForEach(CotypingFullAcceptKey.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Accept trailing punctuation with words",
                   isOn: $app.settings.cotypingAutoAcceptTrailingPunctuation)
            Toggle("Add space after accepting words",
                   isOn: $app.settings.cotypingAddSpaceAfterAccept)
            Toggle("Paste large / multi-line accepts", isOn: $app.settings.cotypingPasteInsertion)
            Text("Commits big, multi-line, or composing-IME suggestions via paste instead of synthetic keystrokes. Briefly uses the clipboard, then restores it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var activitySection: some View {
        Section("Activity") {
            LabeledContent("Suggestions generated") {
                Text("\(stats.stats.generations)").foregroundStyle(.secondary)
            }
            LabeledContent("Accepted") {
                Text("\(stats.stats.accepts)  (\(String(format: "%.2f", stats.stats.acceptsPerGeneration))/gen)").foregroundStyle(.secondary)
            }
            LabeledContent("Characters inserted") {
                Text("\(stats.stats.charsAccepted)").foregroundStyle(.secondary)
            }
            if stats.stats.errors > 0 {
                LabeledContent("Failed generations") {
                    Text("\(stats.stats.errors)").foregroundStyle(.secondary)
                }
            }
            if let avg = stats.stats.avgLatencyMs {
                LabeledContent("Generation latency") {
                    Text("avg \(avg) ms · p95 \(stats.stats.p95LatencyMs ?? avg) · max \(stats.stats.maxLatencyMs ?? avg)").foregroundStyle(.secondary)
                }
            }
            if stats.stats != CotypingStats() {
                Button("Reset cotyping stats", role: .destructive) { stats.clear() }
                    .font(.caption)
            }
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        Section("Try it") {
            Text("Type below and pause — the same engine that powers system-wide cotyping suggests a continuation right here, no permissions needed.")
                .font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $previewText)
                .font(.system(size: 13))
                .frame(minHeight: 70)
                .onChange(of: previewText) { _, _ in schedulePreview() }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Suggestion").font(.caption).foregroundStyle(.secondary)
                    if previewing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Accept ⇥") { acceptPreview() }
                        .controlSize(.small)
                        .disabled(ghost.isEmpty)
                }
                Group {
                    if let previewError {
                        Label(previewError, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    } else if ghost.isEmpty {
                        Text(previewing ? "Thinking…" : "Pause typing to see a suggestion.")
                            .font(.callout).foregroundStyle(.tertiary)
                    } else {
                        Text(previewAttributed)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Show only the tail of the typed text so the ghost stays visible.
    private var previewTextTail: String {
        let tail = previewText.suffix(80)
        return previewText.count > 80 ? "…" + tail : String(tail)
    }

    /// The typed tail plus the ghost continuation (ghost in accent color) as one
    /// wrapping paragraph. AttributedString avoids the deprecated `Text` `+`.
    private var previewAttributed: AttributedString {
        var result = AttributedString(previewTextTail)
        var continuation = AttributedString(ghost)
        continuation.foregroundColor = Brand.teal
        result.append(continuation)
        return result
    }

    private func schedulePreview() {
        previewTask?.cancel()
        ghost = ""
        previewError = nil
        let text = previewText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(app.settings.cotypingDebounceMs))
            guard !Task.isCancelled else { return }
            previewing = true
            defer { previewing = false }
            do {
                let suggestion = try await app.cotyping.previewSuggestion(precedingText: text)
                if !Task.isCancelled { ghost = suggestion }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    previewError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func acceptPreview() {
        guard !ghost.isEmpty else { return }
        previewText += ghost
        ghost = ""
        schedulePreview()
    }

    // MARK: Quality check

    private var benchmarkSection: some View {
        Section("Quality check") {
            Text("Runs email/chat/browser continuations, mid-word word completions, and safety scenarios through the active cotyping engine and reports safety, word-completion parity, and latency.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(benchmarkRunning ? "Running…" : "Run cotyping check") {
                    runBenchmark()
                }
                .disabled(benchmarkRunning)
                if benchmarkRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if let benchmarkSummary {
                LabeledContent("Result") {
                    Text("\(benchmarkSummary.passed)/\(benchmarkSummary.total) scenarios passed")
                        .foregroundStyle(benchmarkSummary.meetsTarget ? .green : .orange)
                }
                if let avg = benchmarkSummary.averageLatencyMs,
                   let p95 = benchmarkSummary.p95LatencyMs {
                    LabeledContent("Latency") {
                        Text("avg \(avg) ms · p95 \(p95) ms")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Expected-term hints") {
                    Text("\(benchmarkSummary.keywordHits)/\(benchmarkSummary.keywordTotal)")
                        .foregroundStyle(.secondary)
                }
                if benchmarkSummary.wordCompletionTotal > 0 {
                    LabeledContent("Word completions") {
                        Text("\(benchmarkSummary.wordCompletionPassed)/\(benchmarkSummary.wordCompletionTotal) extend the typed word")
                            .foregroundStyle(
                                benchmarkSummary.wordCompletionPassed == benchmarkSummary.wordCompletionTotal
                                    ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    }
                }
                ForEach(benchmarkSummary.results.indices, id: \.self) { index in
                    CotypingBenchmarkResultRow(result: benchmarkSummary.results[index])
                }
            }
        }
    }

    private func runBenchmark() {
        benchmarkRunning = true
        benchmarkSummary = nil
        Task {
            let summary = await app.cotyping.runQualityBenchmark()
            benchmarkSummary = summary
            benchmarkRunning = false
        }
    }

    // MARK: Tips

    private var tipsSection: some View {
        Section("How it works") {
            tip("keyboard", "Type and pause — a suggestion appears next to your cursor.")
            tip("return", "Press \(app.settings.cotypingAcceptKey.label) to accept, Esc or keep typing to dismiss.")
            tip("hand.raised", "Never runs in password fields, and skips the apps and sites you exclude above.")
            tip("lock.shield", "Suggestions are generated on-device by your local model. Nothing is sent anywhere.")
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
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

private struct CotypingBenchmarkResultRow: View {
    let result: CotypingBenchmarkCaseResult

    private var detailText: String {
        if let error = result.error { return error }
        if let suppression = result.suppression { return "Suppressed: \(suppression.rawValue)" }
        return result.text
    }

    private var latencyText: String {
        if let first = result.firstVisibleLatencyMs {
            return "\(first) ms first / \(result.latencyMs) ms final"
        }
        return "\(result.latencyMs) ms final"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(result.passed ? .green : .orange)
                Text(result.name).font(.caption)
                Spacer()
                Text(latencyText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(detailText)
                .font(.caption2)
                .foregroundStyle(result.error == nil ? Color.secondary : Color.orange)
                .lineLimit(2)
        }
    }
}
