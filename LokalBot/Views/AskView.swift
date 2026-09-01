import SwiftUI

/// The Ask pillar — Search and the Assistant merged into one query surface
/// (spec §2.3): one input, two response modes. Typing shows live-debounced
/// faceted results; ↵ (or the pinned escalation row) sends the query to the
/// assistant, and the same pane becomes the conversation transcript.
struct AskView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        AskContent(model: app.chat)
    }
}

private struct AskContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: ChatViewModel

    @State private var query = ""
    /// Search flavor within keyword mode: exact words vs. semantic matching.
    /// Seeded from the persisted setting; selecting "Match by meaning" turns
    /// indexing on, while going back to exact words never turns it off.
    @State private var matchByMeaning = false
    @SceneStorage("lokalbot.ask.sourceScopes") private var storedSourceScopes =
        AskSourceScope.storageValue(for: AskSourceScope.defaults)
    @State private var facet: AskFacet = .all
    @State private var hits: [SearchIndex.Hit] = []
    @State private var ocrHits: [ActivityStore.OCRHit] = []
    @State private var semanticHits: [EmbeddingIndex.Hit] = []
    @State private var screenDateScope: ScreenSearchDateScope = .any
    @State private var selectedScreenApp: String?
    @State private var screenApps: [String] = []
    @State private var pinnedScreens: [ScreenAskContext] = []
    @State private var screenWasEnabledBeforePins: Bool?
    @State private var searchTask: Task<Void, Never>?
    @State private var showingTimeScope = false
    @FocusState private var inputFocused: Bool

    private var mode: AskMode {
        get { app.askMode }
        nonmutating set { app.askMode = newValue }
    }

    private var sources: Set<AskSourceScope> {
        get { AskSourceScope.scopes(fromStorageValue: storedSourceScopes) }
        nonmutating set { storedSourceScopes = AskSourceScope.storageValue(for: newValue) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            retrievalBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(nil, value: mode)
        .animation(nil, value: matchByMeaning)
        .onChange(of: query) { if mode == .keyword { runSearch() } }
        .onChange(of: mode) { if mode == .keyword { runSearch() } }
        .onChange(of: facet) { runSearch() }
        .onChange(of: screenDateScope) { runSearch() }
        .onChange(of: selectedScreenApp) { runSearch() }
        .onChange(of: app.navigationHandoff.revision) { consumeNavigationHandoff() }
        .onChange(of: model.currentID) {
            // A saved conversation selection is an explicit mode switch. An
            // old search query must not keep masking the selected transcript.
            query = ""
            mode = .ask
            if model.messages.isEmpty {
                resetAskScope()
            } else {
                restoreAskScope()
            }
        }
        .onAppear {
            matchByMeaning = app.settings.semanticSearchEnabled
            if !consumeNavigationHandoff() {
                restoreAskScope()
            }
            inputFocused = true
            #if LOKALBOT_UI_TEST_HOST
            if query.isEmpty,
               let q = ProcessInfo.processInfo.environment["LOKALBOT_INITIAL_SEARCH"],
               !q.isEmpty {
                query = q
            }
            #endif
        }
    }

    @discardableResult
    private func consumeNavigationHandoff() -> Bool {
        guard let handoff = app.navigationHandoff.consumeAsk() else { return false }
        app.askDayScope = handoff.dayScope.map(Calendar.current.startOfDay(for:))
        if handoff.query != nil || handoff.submit { mode = .ask }
        if let handedQuery = handoff.query {
            query = handedQuery
        }
        if !handoff.screenSnapshotIDs.isEmpty, pinnedScreens.isEmpty {
            rememberScreenAccessBeforePinning()
        }
        for snapshotID in handoff.screenSnapshotIDs {
            guard !pinnedScreens.contains(where: { $0.snapshotID == snapshotID }),
                  let screenshot = app.activityStore.screenshot(id: snapshotID) else { continue }
            let ocr = app.activityStore.ocrText(snapshotID: snapshotID) ?? ""
            pinnedScreens.append(ScreenAskContext(screenshot: screenshot, ocrText: ocr))
        }
        if pinnedScreens.isEmpty {
            restoreScopeAfterRemovingPins()
        } else {
            reconcilePinnedScreenScope()
        }
        if handoff.submit { escalate() }
        return true
    }

    // MARK: - Input + facets

    @ViewBuilder
    private var retrievalBody: some View {
        Group {
            if mode == .keyword {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    keywordEmptyState
                } else {
                    results
                }
            } else if model.messages.isEmpty {
                emptyState
            } else {
                ChatTranscriptView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var hasActiveContent: Bool {
        !model.messages.isEmpty
            || (mode == .keyword
                && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: hasActiveContent ? 10 : 16) {
            topLevelModeControl
            composerPanel
            if mode == .ask {
                askScopeControls
            } else {
                searchControls
            }
            if mode == .ask, !pinnedScreens.isEmpty {
                pinnedContextRow
            } else if mode == .keyword, facet == .screen {
                screenFilterRow
            }
        }
        .padding(.horizontal, WorkspaceMetric.pagePadding)
        .padding(.top, hasActiveContent ? 10 : 16)
        .padding(.bottom, hasActiveContent ? 12 : 24)
        .workspaceReadingWidth()
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var topLevelModeControl: some View {
        Picker("Mode", selection: Binding(get: { mode }, set: selectMode)) {
            ForEach(AskMode.allCases) { candidate in
                Text(candidate.displayName).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
        .accessibilityIdentifier("ask.retrieval")
    }

    private func selectMode(_ selection: AskMode) {
        mode = selection
        if selection == .keyword { runSearch() }
        inputFocused = true
    }

    private var composerPanel: some View {
        let canSubmit = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isResponding

        return HStack(alignment: .center, spacing: 10) {
            TextField(
                mode == .ask
                    ? (model.messages.isEmpty
                        ? "Ask LokalBot about your work…"
                        : "Ask a follow-up…")
                    : (matchByMeaning
                        ? "Search local memory by meaning…"
                        : "Search exact words in local memory…"),
                text: $query,
                axis: .vertical)
                .textFieldStyle(.plain)
                .font(WorkspaceTypography.body)
                .lineLimit(hasActiveContent ? 1...3 : 1...4)
                .focused($inputFocused)
                .onSubmit { submitQuery() }
                .accessibilityIdentifier("search.field")
            if model.isResponding {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Stop answering (Esc)")
                .accessibilityLabel("Stop answering")
                .accessibilityIdentifier("chat.stop")
            }
            submitButton(canSubmit: canSubmit)
        }
        .padding(.horizontal, hasActiveContent ? 14 : 18)
        .padding(.vertical, hasActiveContent ? 10 : 16)
        .frame(minHeight: hasActiveContent ? 52 : 72)
        .background(.quaternary.opacity(0.26),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.panel,
                                         style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.11))
        }
    }

    private func submitQuery() {
        // Search results already update while typing, so Return performs the
        // useful secondary action: ask LokalBot about the current search.
        escalate()
    }

    private func submitButton(canSubmit: Bool) -> some View {
        Button {
            guard canSubmit else { return }
            escalate()
        } label: {
            Label("Ask", systemImage: mode == .ask ? "arrow.up" : "sparkles")
                .font(WorkspaceTypography.control)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(hasActiveContent ? .regular : .large)
        .tint(Brand.teal)
        .disabled(!canSubmit)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityIdentifier(mode == .ask ? "ask.submit" : "ask.escalate")
        .accessibilityLabel(mode == .ask ? "Ask" : "Ask about this search")
        .help(mode == .ask
            ? "Ask (Return or Command-Return)"
            : "Ask about this search (Return or Command-Return)")
    }

    // MARK: - Ask and Search controls

    private var askScopeControls: some View {
        HStack(spacing: 8) {
            sourceScopeControl
            timeScopeControl
            Spacer(minLength: 8)
            inferenceStatus
        }
        .font(WorkspaceTypography.control)
        .controlSize(.small)
    }

    private var sourceScopeControl: some View {
        Menu {
            ForEach(AskSourceScope.allCases) { source in
                Button {
                    toggleSource(source)
                } label: {
                    Label(source.displayName,
                          systemImage: sources.contains(source) ? "checkmark" : source.icon)
                }
                .disabled(
                    (sources.contains(source) && sources.count == 1)
                        || (source == .screen && !pinnedScreens.isEmpty))
            }
            Divider()
            Button {
                app.openSettings(tab: .privacy)
            } label: {
                Label("Manage source permissions…", systemImage: "gearshape")
            }
        } label: {
            Label(sourceSummary, systemImage: "square.stack.3d.up")
        }
        .fixedSize()
        .help("Choose which local sources LokalBot may use")
        .accessibilityIdentifier("ask.sources")
    }

    private var sourceSummary: String {
        if sources == AskSourceScope.defaults { return "All sources" }
        if let only = sources.first, sources.count == 1 { return only.displayName }
        return "\(sources.count) sources"
    }

    private func toggleSource(_ source: AskSourceScope) {
        var selection = sources
        if selection.contains(source) {
            if selection.count > 1 { selection.remove(source) }
        } else {
            selection.insert(source)
        }
        sources = selection
    }

    private var timeScopeControl: some View {
        Button {
            showingTimeScope.toggle()
        } label: {
            Label(timeScopeLabel, systemImage: "calendar")
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .popover(isPresented: $showingTimeScope, arrowEdge: .bottom) {
            timeScopePopover
        }
        .help("Limit every enabled source to one calendar day")
        .accessibilityIdentifier("ask.timeScope")
    }

    private var timeScopePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time scope")
                .font(WorkspaceTypography.sectionTitle)
            Text("Applied to Meetings, Activity, and Screen independently of source access.")
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    app.askDayScope = nil
                    showingTimeScope = false
                } label: {
                    Label("Any time", systemImage: app.askDayScope == nil ? "checkmark" : "clock")
                }
                .buttonStyle(.bordered)
                Button {
                    app.askDayScope = Calendar.current.startOfDay(for: Date())
                    showingTimeScope = false
                } label: {
                    Label("Today", systemImage: isTodayScoped ? "checkmark" : "sun.max")
                }
                .buttonStyle(.bordered)
            }
            Divider()
            DatePicker("Specific date", selection: scopedDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .accessibilityIdentifier("ask.timeScope.date")
        }
        .padding(16)
        .frame(width: 300)
    }

    private var scopedDate: Binding<Date> {
        Binding(
            get: { app.askDayScope ?? Date() },
            set: { app.askDayScope = Calendar.current.startOfDay(for: $0) })
    }

    private var isTodayScoped: Bool {
        app.askDayScope.map(Calendar.current.isDateInToday) ?? false
    }

    private var timeScopeLabel: String {
        guard let day = app.askDayScope else { return "Any time" }
        if Calendar.current.isDateInToday(day) { return "Today" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private var inferenceStatus: some View {
        Button {
            app.openSettings(tab: .models)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: inferenceState.icon)
                    .foregroundStyle(inferenceState.color)
                Text(inferenceState.label)
                    .foregroundStyle(.primary)
            }
            .font(WorkspaceTypography.metadataEmphasis)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(.quaternary.opacity(0.18), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(inferenceStatusHelp) Open model settings.")
        .accessibilityLabel(inferenceStatusHelp)
        .accessibilityHint("Opens model settings")
        .accessibilityIdentifier("ask.inferenceStatus")
    }

    private var inferenceStatusHelp: String {
        switch inferenceState {
        case .approvedRemote:
            return "Answers and retrieved evidence use your approved remote Main LLM, \(app.settings.summarizerBackend.displayName)."
        case .local:
            return "Answers use your local Main LLM. Retrieved evidence stays on this Mac."
        case .blocked:
            return "The selected remote Main LLM is not valid or approved. Asking will fail closed until it is fixed in Settings → Models."
        }
    }

    private enum InferenceState {
        case local, approvedRemote, blocked

        var label: String {
            switch self {
            case .local: "On this Mac"
            case .approvedRemote: "Approved remote"
            case .blocked: "Remote blocked"
            }
        }

        var icon: String {
            switch self {
            case .local: "lock.shield"
            case .approvedRemote: "network"
            case .blocked: "exclamationmark.triangle"
            }
        }

        var color: Color {
            switch self {
            case .local: Brand.teal
            case .approvedRemote: Brand.amber
            case .blocked: Brand.error
            }
        }
    }

    private var inferenceState: InferenceState {
        let rawURL: String
        switch app.settings.summarizerBackend {
        case .builtIn, .appleIntelligence:
            return .local
        case .ollama:
            rawURL = app.settings.ollamaBaseURL
        case .openAICompatible:
            rawURL = app.settings.openAIBaseURL
        }
        guard let url = URL(string: rawURL),
              InferenceEndpointPolicy.origin(for: url) != nil else { return .blocked }
        if InferenceEndpointPolicy.isLoopback(url) { return .local }
        return app.settings.usesRemoteMainLLM ? .approvedRemote : .blocked
    }

    private var searchControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchMatchingControl
                Divider().frame(height: 20)
                facetControls
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                searchMatchingControl
                compactFacetControl
                Spacer(minLength: 0)
            }
        }
    }

    private var compactFacetControl: some View {
        Menu {
            ForEach(AskFacet.allCases) { candidate in
                Button {
                    facet = candidate
                } label: {
                    Label(candidate.rawValue,
                          systemImage: facet == candidate
                            ? "checkmark"
                            : "line.3.horizontal.decrease")
                }
            }
        } label: {
            Label("Filter: \(facet.rawValue)",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
        .accessibilityIdentifier("ask.facet.compact")
    }

    private var searchMatchingControl: some View {
        Menu {
            Button {
                setMatchByMeaning(false)
            } label: {
                Label("Exact words", systemImage: matchByMeaning ? "text.magnifyingglass" : "checkmark")
            }
            Button {
                setMatchByMeaning(true)
            } label: {
                Label("Match by meaning", systemImage: matchByMeaning ? "checkmark" : "atom")
            }
        } label: {
            Label(matchByMeaning ? "Meaning" : "Exact words",
                  systemImage: matchByMeaning ? "atom" : "text.magnifyingglass")
        }
        .fixedSize()
        .help(matchByMeaning
            ? "Match concepts even when the words differ"
            : "Match the words you type")
        .accessibilityIdentifier("ask.searchMatching")
    }

    private func setMatchByMeaning(_ enabled: Bool) {
        matchByMeaning = enabled
        if enabled && !app.settings.semanticSearchEnabled { enableSemanticIndexing() }
        runSearch()
    }

    private var screenFilterRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach([ScreenSearchDateScope.today, .yesterday, .sevenDays, .any]) { scope in
                    screenFilterChip(scope.rawValue, selected: screenDateScope == scope) {
                        screenDateScope = scope
                    }
                }
                Spacer()
                Text("Click to rewind · pin to ask with context")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    screenFilterChip("All apps", selected: selectedScreenApp == nil) {
                        selectedScreenApp = nil
                    }
                    ForEach(screenApps, id: \.self) { appName in
                        screenFilterChip(appName, selected: selectedScreenApp == appName) {
                            selectedScreenApp = appName
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("ask.screen.filters")
    }

    private func screenFilterChip(_ text: String, selected: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.white)
                                          : AnyShapeStyle(.secondary))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(selected ? AnyShapeStyle(Brand.teal)
                                     : AnyShapeStyle(.quaternary.opacity(0.45)),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var pinnedContextRow: some View {
        HStack(spacing: 8) {
            Label("Context", systemImage: "pin.fill")
                .font(WorkspaceTypography.metadataEmphasis)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pinnedScreens) { context in
                        HStack(spacing: 6) {
                            ScreenThumbnailView(snapshotID: context.snapshotID, height: 34)
                                .frame(width: 54)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(context.app).font(WorkspaceTypography.metadataEmphasis).lineLimit(1)
                                Text(context.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(WorkspaceTypography.metadata.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                removePinnedScreen(context.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(context.app) screen from context")
                        }
                        .padding(4)
                        .background(.quaternary.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                    }
                }
            }
            Button("Clear") { clearPinnedScreens(restoringScope: true) }
                .buttonStyle(.plain)
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ask.screen.context")
    }

    private var facetControls: some View {
        HStack(spacing: 10) {
            ForEach(AskFacet.allCases) { candidate in
                facetChip(candidate.rawValue,
                          on: facet == candidate,
                          id: "ask.facet.\(candidate.rawValue.lowercased())") {
                    facet = candidate
                }
            }
        }
    }

    private func facetChip(_ label: String, on: Bool, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(WorkspaceTypography.control)
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(on ? AnyShapeStyle(Brand.teal)
                               : AnyShapeStyle(.quaternary.opacity(0.42)),
                            in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        on ? Brand.teal.opacity(0.32) : Color.primary.opacity(0.09))
                }
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// First selection of "Match by meaning" turns semantic indexing on and
    /// kicks off the embedding backfill (which downloads the embedding model
    /// on first use) — same behavior the old toggle had. Switching back to
    /// exact words never turns indexing off.
    private func enableSemanticIndexing() {
        app.settings.semanticSearchEnabled = true
        Task {
            await app.embeddingIndex.reindexAll(app.meetings)
            await app.embeddingIndex.reindexScreenText()
        }
    }

    // MARK: - Escalation

    /// ↵ or the pinned row: hand the query to the assistant and switch the
    /// pane to the conversation (the send appends messages, which flips the
    /// router to `.conversation`; clearing the query keeps it there). A day
    /// scope from Capture is prepended so the agent reaches for its
    /// activity-summary tool with the right date.
    private func escalate() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.isResponding else { return }
        reconcilePinnedScreenScope()
        let scope = AskEscalationScope.resolve(
            mode: mode,
            selectedSources: sources,
            selectedDay: app.askDayScope)
        let contextualQuestion = ScreenAskContext.prompt(question: q, contexts: pinnedScreens)
        let prompt: String
        if let day = scope.dayScope {
            prompt = "About my day on \(day.formatted(date: .long, time: .omitted)): \(contextualQuestion)"
        } else {
            prompt = contextualQuestion
        }
        mode = .ask
        model.send(
            prompt,
            displayText: q,
            sourceScopes: scope.sources,
            dayScope: scope.dayScope,
            attachedScreenDates: pinnedScreens.map(\.timestamp))
        sources = scope.sources
        app.askDayScope = scope.dayScope
        clearPinnedScreens(restoringScope: false)
        query = ""
    }

    private func resetAskScope() {
        sources = AskSourceScope.defaults
        app.askDayScope = nil
        pinnedScreens = []
        screenWasEnabledBeforePins = nil
        showingTimeScope = false
    }

    private func restoreAskScope() {
        guard let scope = model.currentQuestionScope else {
            resetAskScope()
            return
        }
        sources = scope.sources
        app.askDayScope = scope.dayScopeKey.flatMap { AskDayScope.date(for: $0) }
        pinnedScreens = []
        screenWasEnabledBeforePins = nil
        showingTimeScope = false
    }

    private func reconcilePinnedScreenScope() {
        guard !pinnedScreens.isEmpty else { return }
        let reconciled = AskScopeReconciler.addingScreenContext(
            to: sources,
            dayScope: app.askDayScope)
        sources = reconciled.scopes
        app.askDayScope = reconciled.dayScope
    }

    private func rememberScreenAccessBeforePinning() {
        guard screenWasEnabledBeforePins == nil else { return }
        screenWasEnabledBeforePins = sources.contains(.screen)
    }

    private func removePinnedScreen(_ id: Int64) {
        pinnedScreens.removeAll { $0.id == id }
        if pinnedScreens.isEmpty { restoreScopeAfterRemovingPins() }
    }

    private func clearPinnedScreens(restoringScope: Bool) {
        pinnedScreens = []
        if restoringScope {
            restoreScopeAfterRemovingPins()
        } else {
            screenWasEnabledBeforePins = nil
        }
    }

    private func restoreScopeAfterRemovingPins() {
        guard let wasEnabled = screenWasEnabledBeforePins else { return }
        if !wasEnabled, sources.contains(.screen), sources.count > 1 {
            var updated = sources
            updated.remove(.screen)
            sources = updated
        }
        screenWasEnabledBeforePins = nil
    }

    // MARK: - Results

    private var results: some View {
        List {
            Button(action: escalate) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Brand.tealBright)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask the assistant about “\(query)”")
                            .font(.callout.weight(.medium))
                        Text("All sources · Any time")
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "return").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.escalate")

            if facet == .screen {
                if ocrHits.isEmpty {
                    noMatchesRow("No screen-text matches — OCR text from periodic screenshots is searched here.")
                } else {
                    ForEach(ocrHits) { hit in
                        ScreenSearchResultRow(
                            hit: hit,
                            isPinned: pinnedScreens.contains { $0.snapshotID == hit.snapshotID },
                            open: { app.openScreenSnapshot(hit.snapshotID) },
                            togglePin: { togglePinned(hit) })
                    }
                }
            } else {
                if hits.isEmpty && semanticHits.isEmpty {
                    noMatchesRow("No results for “\(query)” in \(facet.rawValue.lowercased()).")
                }
                ForEach(hits) { hit in
                    Button {
                        app.openSearchHit(hit)
                    } label: {
                        ResultRow(title: meetingTitle(hit.meetingID),
                                  kind: kindLabel(hit),
                                  snippet: hit.snippet,
                                  timestamp: meetingDate(hit.meetingID))
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.hit.\(hit.meetingID.uuidString).\(hit.kind.rawValue)")
                }
                if facet == .all && !semanticHits.isEmpty {
                    Section("Related (semantic)") {
                        ForEach(semanticHits) { hit in
                            Button {
                                app.openMeeting(
                                    hit.meetingID,
                                    seek: hit.start > 0 ? hit.start : nil)
                            } label: {
                                ResultRow(title: meetingTitle(hit.meetingID),
                                          kind: String(format: "≈ %.0f%%", hit.score * 100),
                                          snippet: hit.text)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("search.hit.semantic.\(hit.meetingID.uuidString)")
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("search.results")
    }

    private func noMatchesRow(_ text: String) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private func meetingTitle(_ id: Meeting.ID) -> String {
        app.meetings.first { $0.id == id }?.title ?? "Unknown meeting"
    }

    private func meetingDate(_ id: Meeting.ID) -> String? {
        app.meetings.first { $0.id == id }?
            .startedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private func kindLabel(_ hit: SearchIndex.Hit) -> String {
        switch hit.kind {
        case .title: "Title"
        case .summary: "Summary"
        case .segment: "▶ \(Transcript.stamp(hit.start))\(hit.speaker.isEmpty ? "" : " · \(hit.speaker)")"
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query, f = facet
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))   // debounce typing
            guard !Task.isCancelled else { return }
            if f == .screen {
                guard !q.isEmpty else {
                    ocrHits = []
                    screenApps = []
                    return
                }
                let interval = screenDateScope.interval()
                screenApps = Array(Set(app.activityStore
                    .screenshots(in: interval)
                    .map(\.app))).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                let filter = ScreenSearchFilter(interval: interval, app: selectedScreenApp)
                var keyword = app.activityStore.searchOCR(q, limit: 80, filter: filter)
                if keyword.isEmpty {
                    keyword = app.activityStore.searchOCR(
                        q, limit: 80, matchAll: false, dropStopWords: true, filter: filter)
                }
                if matchByMeaning {
                    let semantic = await app.embeddingIndex.searchScreen(q, filter: filter, limit: 80)
                    guard !Task.isCancelled else { return }
                    let keywordByID = Dictionary(
                        keyword.map { ($0.snapshotID, $0) },
                        uniquingKeysWith: { first, _ in first })
                    let semanticByID = Dictionary(
                        semantic.map { ($0.snapshotID, $0) },
                        uniquingKeysWith: { first, _ in first })
                    ocrHits = ScreenSearchRanker.fuse(
                        keyword: keyword, semantic: semantic, limit: 40).compactMap { ranked in
                            if let lexical = keywordByID[ranked.snapshotID] { return lexical }
                            guard let related = semanticByID[ranked.snapshotID],
                                  let screenshot = app.activityStore.screenshot(
                                    id: ranked.snapshotID) else { return nil }
                            return ActivityStore.OCRHit(
                                snapshotID: ranked.snapshotID,
                                ts: screenshot.ts,
                                app: screenshot.app,
                                windowTitle: screenshot.windowTitle,
                                snippet: related.text)
                        }
                } else {
                    ocrHits = Array(keyword.prefix(40))
                }
            } else {
                hits = q.isEmpty ? [] : app.searchIndex.search(q, kind: f.kind)
                semanticHits = []
                if f == .all, !q.isEmpty, q.count > 3,
                   matchByMeaning, app.embeddingIndex.hasEmbeddings {
                    let semantic = await app.embeddingIndex.search(q)
                    guard !Task.isCancelled else { return }
                    // Drop chunks already surfaced by keyword search.
                    let seen = Set(hits.map { "\($0.meetingID)-\(Int($0.start))" })
                    semanticHits = semantic.filter { !seen.contains("\($0.meetingID)-\(Int($0.start))") }
                }
            }
        }
    }

    private func togglePinned(_ hit: ActivityStore.OCRHit) {
        if let index = pinnedScreens.firstIndex(where: { $0.snapshotID == hit.snapshotID }) {
            let id = pinnedScreens[index].id
            removePinnedScreen(id)
        } else {
            if pinnedScreens.isEmpty { rememberScreenAccessBeforePinning() }
            if let screenshot = app.activityStore.screenshot(id: hit.snapshotID) {
                let ocr = app.activityStore.ocrText(snapshotID: hit.snapshotID) ?? hit.snippet
                pinnedScreens.append(ScreenAskContext(screenshot: screenshot, ocrText: ocr))
            } else {
                pinnedScreens.append(ScreenAskContext(hit: hit))
            }
            reconcilePinnedScreenScope()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Ask your work memory", systemImage: "sparkle.magnifyingglass")
        } description: {
            VStack(spacing: 10) {
                Text("Find an answer in indexed meetings and permitted screen text, with sources. Asking is read-only.")
                    .frame(maxWidth: 400)
                if inferenceState == .blocked {
                    Label(inferenceStatusHelp, systemImage: inferenceState.icon)
                        .workspaceTextRole(.warning)
                        .frame(maxWidth: 400, alignment: .leading)
                } else {
                    InferenceDisclosure(
                        usesRemote: inferenceState == .approvedRemote,
                        localText: "Answers use your local Main LLM; retrieved evidence stays on this Mac.",
                        remoteText: "Answers use your approved remote Main LLM (\(app.settings.summarizerBackend.displayName)); retrieved evidence is sent to that server.")
                        .frame(maxWidth: 400, alignment: .leading)
                }
            }
        } actions: {
            VStack(spacing: 8) {
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Button { sendSuggestion(suggestion) } label: {
                        HStack {
                            Text(suggestion).foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.tint)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: 400)
                        .background(.quaternary.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .accessibilityIdentifier("chat.empty")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keywordEmptyState: some View {
        ContentUnavailableView {
            Label(matchByMeaning ? "Match by meaning" : "Keyword search",
                  systemImage: matchByMeaning ? "atom" : "magnifyingglass")
        } description: {
            Text(matchByMeaning
                ? "Find meetings and permitted screen text that mean what you type, even when the words differ."
                : "Search meeting titles, transcripts, summaries, and permitted screen text without asking the model.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendSuggestion(_ suggestion: String) {
        query = suggestion
        escalate()
    }
}
