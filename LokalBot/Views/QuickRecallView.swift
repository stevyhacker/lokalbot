import AppKit
import SwiftUI

/// Compact system-wide search and assistant surface. Typing keeps local recall
/// instant; the pinned Ask row (or Return) answers in this window, with the full
/// Ask section still available when a conversation needs more room.
struct QuickRecallView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        QuickRecallContent(model: app.chat)
    }
}

private struct QuickRecallContent: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ChatViewModel

#if LOKALBOT_UI_TEST_HOST
    @State private var query = ProcessInfo.processInfo
        .environment["LOKALBOT_QUICK_RECALL_QUERY"] ?? ""
#else
    @State private var query = ""
#endif
    @State private var meetingHits: [SearchIndex.Hit] = []
    @State private var screenHits: [ActivityStore.OCRHit] = []
    @State private var savedMoments: [ActivityStore.SavedMoment] = []
    @State private var selection = 0
    @State private var showingConversation = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .frame(width: 660, height: 480)
        .background(.regularMaterial)
        .onAppear {
            inputFocused = true
            savedMoments = app.activityStore.savedMoments(limit: 200)
            if model.isResponding {
                showingConversation = true
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                search()
            }
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: query) {
            selection = 0
            if !showingConversation {
                search()
            }
        }
        .onKeyPress(.upArrow) {
            guard !showingConversation else { return .ignored }
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !showingConversation else { return .ignored }
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            if showingConversation {
                Button(action: showRecall) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityLabel("Back to recall")
            } else {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            TextField(
                showingConversation ? "Ask a follow-up…" : "Search or ask anything…",
                text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($inputFocused)
                .onSubmit { runSelectedResult() }
                .accessibilityIdentifier("quickRecall.input")
            if showingConversation && model.isResponding {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop")
                .accessibilityLabel("Stop answer")
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear")
            }
            if showingConversation {
                Button(action: openFullAsk) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open full Ask")
                .accessibilityLabel("Open full Ask")
            }
            Text(QuickRecallHotKeyController.shortcutLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var content: some View {
        if showingConversation {
            ChatTranscriptView(model: model)
        } else {
            resultList
        }
    }

    @ViewBuilder private var resultList: some View {
        if rows.isEmpty {
            ContentUnavailableView {
                Label("Ask anything", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Type a question and press Return. Local meeting, screen, and saved-moment matches appear as you type.")
                    .frame(maxWidth: 420)
            } actions: {
                VStack(spacing: 7) {
                    ForEach(Array(model.suggestions.prefix(3).enumerated()), id: \.offset) { index, suggestion in
                        Button { ask(suggestion) } label: {
                            HStack {
                                Text(suggestion)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 420)
                            .background(.quaternary.opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("quickRecall.suggestion.\(index)")
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        QuickRecallRow(row: row, selected: selection == index)
                            .contentShape(Rectangle())
                            .onTapGesture { run(row) }
                            .accessibilityIdentifier("quickRecall.row.\(row.id)")
                    }
                }
                .padding(8)
            }
        }
    }

    private var rows: [QuickRecallRowModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return savedMoments.prefix(12).map { moment in
                .screen(
                    snapshotID: moment.snapshotID,
                    title: moment.note.isEmpty ? (moment.windowTitle.isEmpty ? moment.app : moment.windowTitle) : moment.note,
                    subtitle: "Saved moment · \(moment.app) · \(moment.ts.formatted(date: .abbreviated, time: .shortened))",
                    snippet: nil)
            }
        }
        let matchingSaved = savedMoments.filter { moment in
            [moment.note, moment.app, moment.windowTitle]
                .contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
        let savedIDs = Set(matchingSaved.map(\.snapshotID))
        let saved = matchingSaved.map { moment in
            QuickRecallRowModel.screen(
                snapshotID: moment.snapshotID,
                title: moment.note.isEmpty
                    ? (moment.windowTitle.isEmpty ? moment.app : moment.windowTitle)
                    : moment.note,
                subtitle: "Saved moment · \(moment.app) · \(moment.ts.formatted(date: .abbreviated, time: .shortened))",
                snippet: nil)
        }
        let screens = screenHits.filter { !savedIDs.contains($0.snapshotID) }.map { hit in
            QuickRecallRowModel.screen(
                snapshotID: hit.snapshotID,
                title: hit.windowTitle.isEmpty ? hit.app : hit.windowTitle,
                subtitle: "Moment · \(hit.app) · \(hit.ts.formatted(date: .abbreviated, time: .shortened))",
                snippet: hit.snippet)
        }
        let meetings = meetingHits.map { hit in
            QuickRecallRowModel.meeting(
                hit: hit,
                title: app.meetings.first(where: { $0.id == hit.meetingID })?.title ?? "Meeting",
                subtitle: hit.kind == .segment ? "Meeting transcript" : "Meeting \(hit.kind.rawValue)",
                snippet: hit.snippet)
        }
        return [
            .ask(query: trimmed, title: "Ask about “\(trimmed)”", subtitle: "Answer here", snippet: nil),
        ] + saved + screens + meetings
    }

    private func search() {
        searchTask?.cancel()
        let currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !showingConversation, !currentQuery.isEmpty else {
            meetingHits = []
            screenHits = []
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, currentQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            screenHits = app.activityStore.searchOCR(currentQuery, limit: 12)
            meetingHits = app.searchIndex.search(currentQuery, limit: 10)
        }
    }

    private func moveSelection(by offset: Int) {
        guard !showingConversation, !rows.isEmpty else { return }
        selection = (selection + offset + rows.count) % rows.count
    }

    private func runSelectedResult() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if showingConversation {
            ask(value)
            return
        }
        if rows.indices.contains(selection) {
            run(rows[selection])
        } else {
            guard !value.isEmpty else { return }
            run(.ask(query: value, title: value, subtitle: "", snippet: nil))
        }
    }

    private func run(_ row: QuickRecallRowModel) {
        switch row.destination {
        case .screen(let snapshotID):
            app.openScreenSnapshot(snapshotID)
        case .meeting(let hit):
            app.openSearchHit(hit)
        case .ask(let query):
            ask(query)
            return
        }
        WindowAccess.shared.open("main")
        dismiss()
    }

    private func ask(_ question: String) {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !model.isResponding else { return }
        searchTask?.cancel()
        showingConversation = true
        query = ""
        selection = 0
        model.send(value)
        inputFocused = true
    }

    private func showRecall() {
        query = ""
        selection = 0
        showingConversation = false
        savedMoments = app.activityStore.savedMoments(limit: 200)
        inputFocused = true
    }

    private func openFullAsk() {
        app.openAsk()
        WindowAccess.shared.open("main")
        dismiss()
    }
}

private struct QuickRecallRow: View {
    let row: QuickRecallRowModel
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let snippet = row.snippet, !snippet.isEmpty {
                    Text(snippet).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? Brand.teal.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct QuickRecallRowModel: Identifiable {
    enum Destination {
        case screen(Int64)
        case meeting(SearchIndex.Hit)
        case ask(String)
    }

    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let snippet: String?
    let destination: Destination

    static func screen(snapshotID: Int64, title: String, subtitle: String,
                       snippet: String?) -> Self {
        .init(id: "screen.\(snapshotID)", icon: "rectangle.on.rectangle",
              title: title, subtitle: subtitle, snippet: snippet,
              destination: .screen(snapshotID))
    }

    static func meeting(hit: SearchIndex.Hit, title: String, subtitle: String,
                        snippet: String?) -> Self {
        .init(id: "meeting.\(hit.meetingID).\(hit.kind.rawValue).\(hit.start)",
              icon: "waveform", title: title, subtitle: subtitle,
              snippet: snippet, destination: .meeting(hit))
    }

    static func ask(query: String, title: String, subtitle: String,
                    snippet: String?) -> Self {
        .init(id: "ask.\(query)", icon: "sparkles", title: title,
              subtitle: subtitle, snippet: snippet, destination: .ask(query))
    }
}
