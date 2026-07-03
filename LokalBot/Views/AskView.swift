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
        .onChange(of: app.askPrefill) { consumePrefill() }
        .onAppear {
            consumePrefill()
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
        }
        .padding(12)
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
                .help("Also match by meaning, not just keywords. Downloads the Qwen3 embedding model and indexes your transcripts when first enabled.")
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
                .background(on ? AnyShapeStyle(Color.accentColor)
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
            Task { await app.embeddingIndex.reindexAll(app.meetings) }
        }
        runSearch()
    }

    // MARK: - Escalation

    /// ↵ or the pinned row: hand the query to the assistant and switch the
    /// pane to the conversation (the send appends messages, which flips the
    /// router to `.conversation`; clearing the query keeps it there).
    private func escalate() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.isResponding else { return }
        model.send(q)
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
                        ResultRow(title: hit.app, kind: "Screen", snippet: hit.snippet,
                                  timestamp: hit.ts.formatted(date: .abbreviated, time: .shortened))
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
                                    app.selectedMeetingIDs = [hit.meetingID]
                                    if hit.start > 0 { app.pendingSeek = hit.start }
                                    app.navSection = .meetings
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
                ocrHits = q.isEmpty ? [] : app.activityStore.searchOCR(q)
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
