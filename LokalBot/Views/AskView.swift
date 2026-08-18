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
    @State private var mode: AskMode = .ask
    /// Search flavor within keyword mode: exact words vs. semantic matching.
    /// Seeded from the persisted setting; selecting "Match by meaning" turns
    /// indexing on, while going back to exact words never turns it off.
    @State private var matchByMeaning = false
    @State private var sources = AskSourceScope.defaults
    @State private var facet: AskFacet = .all
    @State private var hits: [SearchIndex.Hit] = []
    @State private var ocrHits: [ActivityStore.OCRHit] = []
    @State private var semanticHits: [EmbeddingIndex.Hit] = []
    @State private var screenDateScope: ScreenSearchDateScope = .any
    @State private var selectedScreenApp: String?
    @State private var screenApps: [String] = []
    @State private var pinnedScreens: [ScreenAskContext] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .onChange(of: query) { if mode == .keyword { runSearch() } }
        .onChange(of: mode) { if mode == .keyword { runSearch() } }
        .onChange(of: facet) { runSearch() }
        .onChange(of: screenDateScope) { runSearch() }
        .onChange(of: selectedScreenApp) { runSearch() }
        .onChange(of: app.askPrefill) { consumePrefill() }
        .onChange(of: app.askScreenContextIDs) { consumeScreenContext() }
        .onChange(of: app.askSubmitRequested) { consumeSubmitRequest() }
        .onChange(of: model.currentID) {
            // A saved conversation selection is an explicit mode switch. An
            // old search query must not keep masking the selected transcript.
            query = ""
            mode = .ask
        }
        .onAppear {
            matchByMeaning = app.settings.semanticSearchEnabled
            consumePrefill()
            consumeScreenContext()
            consumeSubmitRequest()
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

    private func consumePrefill() {
        guard let prefill = app.askPrefill else { return }
        mode = .ask
        query = prefill
        app.askPrefill = nil
    }

    private func consumeScreenContext() {
        guard !app.askScreenContextIDs.isEmpty else { return }
        for snapshotID in app.askScreenContextIDs {
            guard !pinnedScreens.contains(where: { $0.snapshotID == snapshotID }),
                  let screenshot = app.activityStore.screenshot(id: snapshotID) else { continue }
            let ocr = app.activityStore.ocrText(snapshotID: snapshotID) ?? ""
            pinnedScreens.append(ScreenAskContext(screenshot: screenshot, ocrText: ocr))
        }
        app.askScreenContextIDs = []
    }

    private func consumeSubmitRequest() {
        guard app.askSubmitRequested else { return }
        // Consume all handoff state in one pass. SwiftUI may coalesce the
        // individual @Published updates from `openAsk`, so this remains
        // ordering-independent even when Ask is already visible.
        consumePrefill()
        consumeScreenContext()
        app.askSubmitRequested = false
        escalate()
    }

    // MARK: - Input + facets

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            composerPanel

            if mode == .ask {
                sourceScopeRow
                if !pinnedScreens.isEmpty { pinnedContextRow }
            } else {
                facetRow
                if facet == .screen { screenFilterRow }
            }
        }
        .padding(.horizontal, WorkspaceMetric.pagePadding)
        .padding(.bottom, 31)
        .workspaceReadingWidth()
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var composerPanel: some View {
        let canSubmit = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isResponding

        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                TextField(
                    mode == .ask
                        ? "Ask LokalBot about your work…"
                        : (matchByMeaning
                            ? "Search local memory by meaning…"
                            : "Search exact words in local memory…"),
                    text: $query)
                .textFieldStyle(.plain)
                .font(WorkspaceTypography.editorialBody)
                .focused($inputFocused)
                .onSubmit {
                    if mode == .ask { escalate() } else { runSearch() }
                }
                .accessibilityIdentifier("search.field")
                if model.isResponding {
                    Button(action: model.stop) {
                        Image(systemName: "stop.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Stop")
                    .accessibilityIdentifier("chat.stop")
                } else if !query.isEmpty, mode == .keyword {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
                if mode == .ask {
                    Button {
                        guard canSubmit else { return }
                        escalate()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Ask")
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .font(WorkspaceTypography.control)
                        .foregroundStyle(.white)
                        .padding(.leading, 56)
                        .padding(.trailing, 14)
                        .padding(.vertical, 11)
                        .background(
                            // Brand accent, not a bespoke cyan: the CTA is the
                            // most prominent tinted control in the app and must
                            // move with `Brand.teal`.
                            LinearGradient(
                                colors: [Brand.teal, Brand.teal.opacity(0.88)],
                                startPoint: .leading,
                                endPoint: .trailing),
                            in: Capsule())
                        .opacity(canSubmit ? 1 : 0.82)
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(canSubmit)
                    .accessibilityIdentifier("ask.submit")
                }
            }
            .padding(.leading, 26)
            .padding(.trailing, 17)
            .frame(minHeight: 70)

            HStack(spacing: 8) {
                retrievalModeControl
                Spacer()
            }
            .padding(.horizontal, WorkspaceMetric.panelPadding)
            .padding(.top, 2)
            .padding(.bottom, 22)
        }
        .background(.quaternary.opacity(0.26),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.panel,
                                         style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.11))
        }
    }

    // MARK: - Retrieval mode

    /// The one control for how a query is answered: chat, exact words, or
    /// semantic matching — previously three competing capsules.
    private enum AskRetrieval: String, CaseIterable, Identifiable {
        case ask = "Ask"
        case keyword = "Keyword search"
        case meaning = "Match by meaning"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .ask: "sparkles"
            case .keyword: "magnifyingglass"
            case .meaning: "atom"
            }
        }

        var identifier: String {
            switch self {
            case .ask: "ask.mode.ask"
            case .keyword: "ask.mode.keyword"
            case .meaning: "ask.semantic"
            }
        }

        var helpText: String {
            switch self {
            case .ask:
                "Ask the local assistant, with evidence from your library."
            case .keyword:
                "Find exact words in meetings, summaries, and permitted screen text."
            case .meaning:
                "Match by meaning, not just keywords. Downloads the Qwen3 embedding model and indexes transcripts plus on-device OCR when first enabled."
            }
        }
    }

    private var currentRetrieval: AskRetrieval {
        if mode == .ask { return .ask }
        return matchByMeaning ? .meaning : .keyword
    }

    private var retrievalModeControl: some View {
        HStack(spacing: 2) {
            ForEach(AskRetrieval.allCases) { retrieval in
                let selected = currentRetrieval == retrieval
                Button {
                    select(retrieval)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: retrieval.icon)
                        Text(retrieval.rawValue)
                    }
                    .font(WorkspaceTypography.control)
                    .foregroundStyle(selected ? AnyShapeStyle(.primary)
                                              : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selected ? AnyShapeStyle(Brand.teal.opacity(0.30))
                                         : AnyShapeStyle(.clear),
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(retrieval.identifier)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(retrieval.helpText)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.42), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.10)) }
    }

    private func select(_ retrieval: AskRetrieval) {
        switch retrieval {
        case .ask:
            mode = .ask
        case .keyword:
            matchByMeaning = false
            mode = .keyword
        case .meaning:
            matchByMeaning = true
            if !app.settings.semanticSearchEnabled { enableSemanticIndexing() }
            mode = .keyword
        }
        if mode == .keyword { runSearch() }
    }

    private var sourceScopeRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 15) {
                sourceScopeLabel
                sourceScopeControls
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                sourceScopeLabel
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        sourceScopeControls
                    }
                }
            }
        }
        .padding(.leading, 2)
    }

    private var sourceScopeLabel: some View {
        Text("Sources")
            .font(WorkspaceTypography.bodyEmphasis)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var sourceScopeControls: some View {
        ForEach(AskSourceScope.allCases) { source in
            Button {
                if sources.contains(source) {
                    if sources.count > 1 { sources.remove(source) }
                } else {
                    sources.insert(source)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: sources.contains(source)
                          ? "checkmark.circle.fill" : source.icon)
                    Text(source.rawValue)
                }
                .font(WorkspaceTypography.control)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    sources.contains(source)
                        ? AnyShapeStyle(Brand.teal.opacity(0.30))
                        : AnyShapeStyle(.quaternary.opacity(0.42)),
                    in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        sources.contains(source)
                            ? Brand.teal.opacity(0.32)
                            : Color.primary.opacity(0.09))
                }
                .offset(y: 1)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.source.\(source.rawValue.lowercased())")
            .accessibilityAddTraits(sources.contains(source) ? .isSelected : [])
        }

        Button {
            app.openSettings(tab: .privacy)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gearshape")
                Text("Manage")
            }
            .font(WorkspaceTypography.control)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.42), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.09)) }
            .fixedSize()
        }
        .buttonStyle(.plain)
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
                                pinnedScreens.removeAll { $0.id == context.id }
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
            Button("Clear") { pinnedScreens = [] }
                .buttonStyle(.plain)
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ask.screen.context")
    }

    private var facetRow: some View {
        HStack(spacing: 6) {
            ForEach(AskFacet.allCases) { candidate in
                facetChip(candidate.rawValue,
                          on: facet == candidate,
                          id: "ask.facet.\(candidate.rawValue.lowercased())") {
                    facet = candidate
                }
            }
            if let day = app.askDayScope {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(day.formatted(date: .abbreviated, time: .omitted))
                    Button { app.askDayScope = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear day scope")
                }
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
                .chipChrome()
                .help("Questions sent to the assistant are scoped to this day.")
                .accessibilityIdentifier("ask.dayScope")
            }
            Spacer()
        }
    }

    private func facetChip(_ label: String, on: Bool, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(on ? AnyShapeStyle(Brand.teal)
                               : AnyShapeStyle(.quaternary.opacity(0.5)),
                            in: Capsule())
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
        let contextualQuestion = ScreenAskContext.prompt(question: q, contexts: pinnedScreens)
        let prompt: String
        if let day = app.askDayScope {
            prompt = "About my day on \(day.formatted(date: .long, time: .omitted)): \(contextualQuestion)"
        } else {
            prompt = contextualQuestion
        }
        let questionSources = sources
        model.send(prompt, displayText: q, sourceScopes: questionSources)
        pinnedScreens = []
        query = ""
        sources = AskSourceScope.defaults
    }

    // MARK: - Results

    private var results: some View {
        List {
            Button(action: escalate) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Brand.tealBright)
                    Text("Ask the assistant about “\(query)”")
                        .font(.callout.weight(.medium))
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
                    ResultRow(title: meetingTitle(hit.meetingID),
                              kind: kindLabel(hit),
                              snippet: hit.snippet,
                              timestamp: meetingDate(hit.meetingID))
                        .contentShape(Rectangle())
                        .onTapGesture { app.openSearchHit(hit) }
                        .accessibilityIdentifier("search.hit.\(hit.meetingID.uuidString).\(hit.kind.rawValue)")
                }
                if facet == .all && !semanticHits.isEmpty {
                    Section("Related (semantic)") {
                        ForEach(semanticHits) { hit in
                            ResultRow(title: meetingTitle(hit.meetingID),
                                      kind: String(format: "≈ %.0f%%", hit.score * 100),
                                      snippet: hit.text)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if hit.start > 0 { app.pendingSeek = hit.start }
                                    app.openMeeting(hit.meetingID)
                                }
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
            pinnedScreens.remove(at: index)
        } else {
            if let screenshot = app.activityStore.screenshot(id: hit.snapshotID) {
                let ocr = app.activityStore.ocrText(snapshotID: hit.snapshotID) ?? hit.snippet
                pinnedScreens.append(ScreenAskContext(screenshot: screenshot, ocrText: ocr))
            } else {
                pinnedScreens.append(ScreenAskContext(hit: hit))
            }
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
                InferenceDisclosure(
                    usesRemote: app.settings.usesRemoteMainLLM,
                    localText: "Answers use your local Main LLM; retrieved evidence stays on this Mac.",
                    remoteText: "Answers use your approved remote Main LLM (\(app.settings.summarizerBackend.displayName)); retrieved evidence is sent to that server.")
                    .frame(maxWidth: 400, alignment: .leading)
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
    }

    private func sendSuggestion(_ suggestion: String) {
        let questionSources = sources
        model.send(suggestion, sourceScopes: questionSources)
        sources = AskSourceScope.defaults
    }
}
