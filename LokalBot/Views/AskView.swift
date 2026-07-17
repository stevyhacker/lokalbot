import SwiftUI

/// The Ask pillar — Search and the Assistant merged into one query surface
/// (spec §2.3): one input, two response modes. Typing shows live-debounced
/// faceted results; ↵ (or the pinned escalation row) sends the query to the
/// assistant, and the same pane becomes the conversation transcript.
struct AskView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        AskContent(model: app.chat)
            .navigationTitle("Ask")
    }
}

private struct AskContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: ChatViewModel

    @State private var query = ""
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

    private var phase: AskPhase {
        AskRouter.phase(query: query, hasMessages: !model.messages.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch phase {
            case .searching: results
            case .conversation: ChatTranscriptView(model: model)
            case .idle: emptyState
            }
        }
        .onChange(of: query) { runSearch() }
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
        }
        .onAppear {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search — press ↵ to ask", text: $query)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit(escalate)
                    .accessibilityIdentifier("search.field")
                if model.isResponding {
                    Button(action: model.stop) {
                        Image(systemName: "stop.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Stop")
                    .accessibilityIdentifier("chat.stop")
                } else if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            facetRow
            if facet == .screen {
                screenFilterRow
            }
            if !pinnedScreens.isEmpty {
                pinnedContextRow
            }
        }
        .padding(12)
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
                    .font(.caption2)
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
                .font(.caption2.weight(selected ? .semibold : .regular))
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pinnedScreens) { context in
                        HStack(spacing: 6) {
                            ScreenThumbnailView(snapshotID: context.snapshotID, height: 34)
                                .frame(width: 54)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(context.app).font(.caption.weight(.medium)).lineLimit(1)
                                Text(context.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2.monospacedDigit())
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
                .font(.caption)
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
            Divider().frame(height: 14)
            facetChip("≈ Semantic",
                      on: app.settings.semanticSearchEnabled,
                      id: "ask.facet.semantic",
                      action: toggleSemantic)
                .help("Also match meetings and captured screen text by meaning, not just keywords. Downloads the Qwen3 embedding model and indexes transcripts plus on-device OCR when first enabled.")
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
                .font(.caption)
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
                .font(.caption.weight(on ? .semibold : .regular))
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

    /// Turning semantic search on kicks off the embedding backfill (which
    /// downloads the embedding model on first use) — same behavior the old
    /// Search toggle had.
    private func toggleSemantic() {
        app.settings.semanticSearchEnabled.toggle()
        if app.settings.semanticSearchEnabled {
            Task {
                await app.embeddingIndex.reindexAll(app.meetings)
                await app.embeddingIndex.reindexScreenText()
            }
        }
        runSearch()
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
        model.send(prompt, displayText: q)
        pinnedScreens = []
        query = ""
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
                if app.settings.semanticSearchEnabled {
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
                   app.settings.semanticSearchEnabled, app.embeddingIndex.hasEmbeddings {
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
            Label("Ask your meetings", systemImage: "sparkle.magnifyingglass")
        } description: {
            Text("Search everything LokalBot has indexed, or press ↵ to ask the assistant — decisions, action items, who said what. Everything stays on this Mac.")
                .frame(maxWidth: 400)
        } actions: {
            VStack(spacing: 8) {
                ForEach(model.suggestions, id: \.self) { suggestion in
                    Button { model.send(suggestion) } label: {
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
}
