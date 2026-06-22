import SwiftUI

/// Search across everything LokalBotV2 has indexed (design doc §4.2):
/// one box, scope filter, highlighted snippets; transcript hits deep-link
/// to the meeting at their audio timestamp.
struct SearchView: View {
    @EnvironmentObject var app: AppState

    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var hits: [SearchIndex.Hit] = []
    @State private var searchTask: Task<Void, Never>?

    private enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case transcripts = "Transcripts"
        case summaries = "Summaries"
        case screen = "Screen"
        var id: String { rawValue }
        var kind: SearchIndex.Kind? {
            switch self {
            case .all, .screen: nil
            case .transcripts: .segment
            case .summaries: .summary
            }
        }
    }

    @State private var ocrHits: [ActivityStore.OCRHit] = []
    @State private var semanticHits: [EmbeddingIndex.Hit] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search transcripts, summaries, titles…", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("search.field")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) {
                        Text($0.rawValue).tag($0).accessibilityIdentifier("search.scope.\($0.rawValue.lowercased())")
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("search.scope")
            }
            .padding(12)
            Divider()

            if scope == .screen {
                if ocrHits.isEmpty {
                    ContentUnavailableView("No screen-text matches", systemImage: "camera.viewfinder",
                        description: Text("OCR text from periodic screenshots is searched here."))
                        .frame(maxHeight: .infinity)
                } else {
                    List(ocrHits) { hit in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(hit.app).font(.headline)
                                Text(hit.ts.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            Text(hit.snippet.replacingOccurrences(of: "«", with: "")
                                    .replacingOccurrences(of: "»", with: ""))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .padding(.vertical, 3)
                    }
                    .listStyle(.inset)
                }
            } else if hits.isEmpty && semanticHits.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Search your meetings" : "No matches",
                    systemImage: "magnifyingglass",
                    description: Text(query.isEmpty
                        ? "Everything is indexed locally — words said in meetings, summaries, titles."
                        : "No results for “\(query)” in \(scope.rawValue.lowercased())."))
                    .frame(maxHeight: .infinity)
            } else {
                resultsList
            }
        }
        .onChange(of: query) { runSearch() }
        .onChange(of: scope) { runSearch() }
    }

    private var resultsList: some View {
        List {
            ForEach(hits) { hit in
                SearchHitRow(hit: hit, meeting: app.meetings.first { $0.id == hit.meetingID })
                    .contentShape(Rectangle())
                    .onTapGesture { app.openSearchHit(hit) }
                    .accessibilityIdentifier("search.hit.\(hit.meetingID.uuidString).\(hit.kind.rawValue)")
            }
            if scope == .all && !semanticHits.isEmpty {
                Section("Related (semantic)") {
                    ForEach(semanticHits) { hit in
                        SemanticHitRow(hit: hit,
                                       meeting: app.meetings.first { $0.id == hit.meetingID })
                            .contentShape(Rectangle())
                            .onTapGesture {
                                app.selectedMeetingIDs = [hit.meetingID]
                                if hit.start > 0 { app.pendingSeek = hit.start }
                            }
                            .accessibilityIdentifier("search.hit.semantic.\(hit.meetingID.uuidString)")
                    }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("search.results")
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query, s = scope
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))   // debounce typing
            guard !Task.isCancelled else { return }
            if s == .screen {
                ocrHits = q.isEmpty ? [] : app.activityStore.searchOCR(q)
            } else {
                hits = q.isEmpty ? [] : app.searchIndex.search(q, kind: s.kind)
                semanticHits = []
                if s == .all, !q.isEmpty, q.count > 3,
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
}

private struct SemanticHitRow: View {
    let hit: EmbeddingIndex.Hit
    let meeting: Meeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(meeting?.title ?? "Unknown meeting")
                    .font(.headline)
                Spacer()
                Text(String(format: "≈ %.0f%%", hit.score * 100))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text(hit.text).font(.callout)
                .foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.vertical, 3)
    }
}

private struct SearchHitRow: View {
    let hit: SearchIndex.Hit
    let meeting: Meeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(meeting?.title ?? "Unknown meeting")
                    .font(.headline)
                if let meeting {
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                kindChip
            }
            highlighted(hit.snippet)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var kindChip: some View {
        let label = switch hit.kind {
        case .title: "Title"
        case .summary: "Summary"
        case .segment: "▶ \(Transcript.stamp(hit.start))\(hit.speaker.isEmpty ? "" : " · \(hit.speaker.capitalized)")"
        }
        Text(label)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    /// Render «matches» from the FTS5 snippet as bold primary text.
    private func highlighted(_ snippet: String) -> Text {
        var result = Text("")
        var rest = Substring(snippet)
        while let open = rest.firstIndex(of: "«") {
            result = result + Text(rest[..<open])
            rest = rest[rest.index(after: open)...]
            if let close = rest.firstIndex(of: "»") {
                result = result + Text(rest[..<close]).bold().foregroundStyle(.primary)
                rest = rest[rest.index(after: close)...]
            } else { break }
        }
        return result + Text(rest)
    }
}
