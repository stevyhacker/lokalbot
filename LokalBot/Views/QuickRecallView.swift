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
    @State private var recalledQuery = ""
    @State private var isSearching = false
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
        if trimmedQuery.isEmpty, sections.isEmpty {
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
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let askRow {
                        displayedRow(askRow)
                            .padding(.bottom, 4)
                    }

                    if isSearching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching your local memory…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("quickRecall.searching")
                    } else if !trimmedQuery.isEmpty, sections.isEmpty {
                        noMatchesState
                    }

                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.rows) { row in
                            displayedRow(row)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var askRow: QuickRecallRowModel? {
        guard !trimmedQuery.isEmpty else { return nil }
        return .ask(
            query: trimmedQuery,
            title: "Ask about “\(trimmedQuery)”",
            subtitle: "Answer from your meetings and screen")
    }

    private var sections: [QuickRecallSection] {
        let saved: [QuickRecallRowModel]
        if trimmedQuery.isEmpty {
            saved = savedMoments.prefix(12).map(savedRow)
        } else {
            saved = savedMoments.filter { moment in
                [moment.note, moment.app, moment.windowTitle]
                    .contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
            }.map(savedRow)
        }

        let savedIDs = Set(saved.compactMap(\.snapshotID))
        let screens = screenHits.filter { !savedIDs.contains($0.snapshotID) }.map { hit in
            let title = hit.windowTitle.isEmpty ? hit.app : hit.windowTitle
            return QuickRecallRowModel.screen(
                snapshotID: hit.snapshotID,
                appName: hit.app,
                title: title,
                subtitle: hit.app,
                snippet: SnippetCleaner.withoutTitleEcho(hit.snippet, title: title),
                timestamp: hit.ts,
                captureCount: hit.captureCount)
        }
        let meetings = meetingHits.map { hit in
            let meeting = app.meetings.first(where: { $0.id == hit.meetingID })
            let kind = hit.kind == .segment ? "Transcript" : hit.kind.rawValue.capitalized
            let appName = meeting?.appName ?? "Meeting"
            return QuickRecallRowModel.meeting(
                hit: hit,
                appName: appName,
                title: meeting?.title ?? "Meeting",
                subtitle: "\(appName) · \(kind)",
                snippet: hit.snippet,
                timestamp: meeting?.startedAt)
        }

        return [
            QuickRecallSection(id: "saved", title: "Saved", rows: saved),
            QuickRecallSection(id: "screen", title: "Screen", rows: screens),
            QuickRecallSection(id: "meetings", title: "Meetings", rows: meetings),
        ].filter { !$0.rows.isEmpty }
    }

    private func savedRow(_ moment: ActivityStore.SavedMoment) -> QuickRecallRowModel {
        .screen(
            snapshotID: moment.snapshotID,
            appName: moment.app,
            title: moment.note.isEmpty
                ? (moment.windowTitle.isEmpty ? moment.app : moment.windowTitle)
                : moment.note,
            subtitle: moment.app,
            snippet: nil,
            timestamp: moment.ts,
            isSaved: true)
    }

    private var rows: [QuickRecallRowModel] {
        [askRow].compactMap { $0 } + sections.flatMap(\.rows)
    }

    private func displayedRow(_ row: QuickRecallRowModel) -> some View {
        let index = rows.firstIndex(where: { $0.id == row.id }) ?? 0
        return QuickRecallRow(row: row, selected: selection == index)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { selection = index }
            }
            .onTapGesture { run(row) }
            .accessibilityIdentifier("quickRecall.row.\(row.id)")
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Label("No local matches", systemImage: "magnifyingglass")
                .font(.headline)
            Text("Nothing in saved moments, captured screens, or meetings matches this search.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { ask(trimmedQuery) } label: {
                Label("Ask instead", systemImage: "return")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("quickRecall.askInstead")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("quickRecall.noMatches")
    }

    private func search() {
        searchTask?.cancel()
        let currentQuery = trimmedQuery
        guard !showingConversation, !currentQuery.isEmpty else {
            meetingHits = []
            screenHits = []
            isSearching = false
            return
        }
        meetingHits = []
        screenHits = []
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, currentQuery == trimmedQuery else { return }
            screenHits = app.activityStore.searchOCR(currentQuery, limit: 12)
            meetingHits = app.searchIndex.search(currentQuery, limit: 10)
            guard !Task.isCancelled, currentQuery == trimmedQuery else { return }
            isSearching = false
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
            run(.ask(query: value, title: value, subtitle: ""))
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
        if !showingConversation {
            recalledQuery = query
        }
        isSearching = false
        showingConversation = true
        query = ""
        selection = 0
        model.send(value)
        inputFocused = true
    }

    private func showRecall() {
        showingConversation = false
        query = recalledQuery
        selection = 0
        savedMoments = app.activityStore.savedMoments(limit: 200)
        search()
        inputFocused = true
    }

    private func openFullAsk() {
        app.openAsk()
        WindowAccess.shared.open("main")
        dismiss()
    }
}

private struct QuickRecallSection: Identifiable {
    let id: String
    let title: String
    let rows: [QuickRecallRowModel]
}

private struct QuickRecallRow: View {
    let row: QuickRecallRowModel
    let selected: Bool

    @ViewBuilder var body: some View {
        if row.isAsk {
            askRow
        } else {
            evidenceRow
        }
    }

    private var askRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Brand.teal.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "return")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .opacity(selected ? 1 : 0)
                .frame(width: 14, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Brand.teal.opacity(selected ? 0.19 : 0.08),
            in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                .strokeBorder(Brand.teal.opacity(selected ? 0.34 : 0.18))
        }
    }

    private var evidenceRow: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingVisual
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let timestamp = row.timestamp {
                        // The timestamp never compresses; the title truncates.
                        Text(QuickRecallDateLabel.string(for: timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    // Slot is always reserved so selection doesn't reflow the line.
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .opacity(selected ? 1 : 0)
                        .frame(width: 14, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 5) {
                    if let appName = row.appName {
                        QuickRecallApplicationIcon(appName: appName, size: 14)
                    }
                    Text(row.subtitle)
                        .lineLimit(1)
                    if row.captureCount > 1 {
                        Text("· \(row.captureCount) captures")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let snippet = row.snippet, !snippet.isEmpty {
                    highlighted(snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            selected ? Brand.teal.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
    }

    @ViewBuilder private var leadingVisual: some View {
        if let snapshotID = row.snapshotID {
            ZStack(alignment: .bottomTrailing) {
                ScreenThumbnailView(snapshotID: snapshotID, height: 56)
                    .frame(width: 90)
                    .overlay {
                        RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                            .strokeBorder(.quaternary)
                    }
                if row.isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(Brand.amber)
                        .padding(4)
                        .background(.regularMaterial, in: Circle())
                        .padding(3)
                }
            }
        } else {
            Image(systemName: row.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func highlighted(_ snippet: String) -> Text {
        SnippetHighlighter.segments(snippet).reduce(Text("")) { text, segment in
            text + (segment.isMatch
                ? Text(segment.text).bold().foregroundStyle(.primary)
                : Text(segment.text))
        }
    }
}

@MainActor
private enum QuickRecallApplicationIconResolver {
    private static let cache = NSCache<NSString, NSImage>()
    private static var missing: Set<String> = []

    static func icon(for appName: String) -> NSImage? {
        let key = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard !missing.contains(key) else { return nil }

        if let icon = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare(key) == .orderedSame
        })?.icon {
            cache.setObject(icon, forKey: key as NSString)
            return icon
        }

        let name = key.hasSuffix(".app") ? String(key.dropLast(4)) : key
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        for root in roots {
            let applicationURL = root.appendingPathComponent(name).appendingPathExtension("app")
            guard FileManager.default.fileExists(atPath: applicationURL.path) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            cache.setObject(icon, forKey: key as NSString)
            return icon
        }
        missing.insert(key)
        return nil
    }
}

private struct QuickRecallApplicationIcon: View {
    let appName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = QuickRecallApplicationIconResolver.icon(for: appName) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
                    .padding(1)
            }
        }
        .frame(width: size, height: size)
        .help(appName)
        .accessibilityHidden(true)
    }
}

private enum QuickRecallDateLabel {
    static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let dateDay = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let distance = calendar.dateComponents([.day], from: dateDay, to: today).day ?? .max
        let day: String
        switch distance {
        case 0:
            day = "Today"
        case 1:
            day = "Yesterday"
        case 2...6:
            day = date.formatted(.dateTime.weekday(.abbreviated))
        default:
            day = date.formatted(.dateTime.day().month(.abbreviated))
        }
        return "\(day) · \(time)"
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
    let appName: String?
    let title: String
    let subtitle: String
    let snippet: String?
    let timestamp: Date?
    let captureCount: Int
    let isSaved: Bool
    let destination: Destination

    var snapshotID: Int64? {
        guard case .screen(let snapshotID) = destination else { return nil }
        return snapshotID
    }

    var isAsk: Bool {
        guard case .ask = destination else { return false }
        return true
    }

    static func screen(
        snapshotID: Int64,
        appName: String,
        title: String,
        subtitle: String,
        snippet: String?,
        timestamp: Date,
        captureCount: Int = 1,
        isSaved: Bool = false
    ) -> Self {
        .init(
            id: "screen.\(snapshotID)",
            icon: "rectangle.on.rectangle",
            appName: appName,
            title: title,
            subtitle: subtitle,
            snippet: snippet,
            timestamp: timestamp,
            captureCount: max(1, captureCount),
            isSaved: isSaved,
            destination: .screen(snapshotID))
    }

    static func meeting(
        hit: SearchIndex.Hit,
        appName: String,
        title: String,
        subtitle: String,
        snippet: String?,
        timestamp: Date?
    ) -> Self {
        .init(
            id: "meeting.\(hit.meetingID).\(hit.kind.rawValue).\(hit.start)",
            icon: "waveform",
            appName: appName,
            title: title,
            subtitle: subtitle,
            snippet: snippet,
            timestamp: timestamp,
            captureCount: 1,
            isSaved: false,
            destination: .meeting(hit))
    }

    static func ask(query: String, title: String, subtitle: String) -> Self {
        .init(
            id: "ask.\(query)",
            icon: "sparkles",
            appName: nil,
            title: title,
            subtitle: subtitle,
            snippet: nil,
            timestamp: nil,
            captureCount: 1,
            isSaved: false,
            destination: .ask(query))
    }
}
