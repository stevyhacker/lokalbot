import SwiftUI
import AppKit
import AVFoundation

// The assistant's conversation surfaces: the editorial transcript embedded
// by the Ask section (spec §2.3), and the saved-conversation list shown in
// Ask's content column. The assistant itself is a small ReAct agent
// (`ChatAgent`) over the summarisation `TextEngine` that can search
// transcripts, list meetings, and read a meeting's summary or transcript
// via tool calls — all on-device.

// MARK: - Editorial transcript

/// The conversation transcript, restyled from chat bubbles to an editorial
/// layout (spec §2.3): user turns as compact teal-tinted rows, assistant
/// turns as full-width flat text with tool activity collapsed to one
/// "worked: …" line. Embedded by the Ask surface.
struct ChatTranscriptView: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isNearBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            EditorialTurn(
                                message: message,
                                model: model,
                                startsQuestion: index > 0 && message.role == .user)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, WorkspaceMetric.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, WorkspaceMetric.pagePadding)
                    .workspaceReadingWidth()
                    .frame(maxWidth: .infinity, alignment: .top)
                    .accessibilityIdentifier("chat.readingColumn")
                }
                .accessibilityIdentifier("chat.messages")
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let remaining = geometry.contentSize.height - geometry.visibleRect.maxY
                    return remaining < 96
                } action: { _, nearBottom in
                    isNearBottom = nearBottom
                }

                if !isNearBottom {
                    Button {
                        scrollToEnd(proxy, animated: true, force: true)
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(16)
                    .accessibilityIdentifier("chat.jumpToLatest")
                }
            }
            .onChange(of: model.messages.count) {
                scrollToEnd(proxy, animated: true)
            }
            .onChange(of: model.messages.last?.text) { previousText, currentText in
                let answerStarted = (previousText ?? "").isEmpty
                    && !(currentText ?? "").isEmpty
                    && model.messages.last?.role == .assistant
                if answerStarted, isNearBottom, let id = model.messages.last?.id {
                    scrollToTurn(proxy, id: id, anchor: .top, animated: true)
                } else {
                    scrollToEnd(proxy, animated: false)
                }
            }
            .onChange(of: model.messages.last?.activity.count) {
                scrollToEnd(proxy, animated: false)
            }
            .onChange(of: model.currentID) {
                isNearBottom = true
                scrollToEnd(proxy, animated: false, force: true)
            }
        }
    }

    private func scrollToEnd(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        force: Bool = false
    ) {
        guard force || isNearBottom else { return }
        guard let last = model.messages.last?.id else { return }
        if animated {
            withAnimation(WorkspaceMotion.animation(.autoScroll, reduceMotion: reduceMotion)) {
                proxy.scrollTo(last, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private func scrollToTurn(
        _ proxy: ScrollViewProxy,
        id: UUID,
        anchor: UnitPoint,
        animated: Bool
    ) {
        if animated {
            withAnimation(WorkspaceMotion.animation(.autoScroll, reduceMotion: reduceMotion)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }
}

private struct EditorialTurn: View {
    @EnvironmentObject var app: AppState
    let message: ChatMessage
    @ObservedObject var model: ChatViewModel
    let startsQuestion: Bool
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var speechPlayer: AVAudioPlayer?
    @State private var speechError: String?
    @State private var preparingSpeech = false
    @State private var readingSpeech = false
    @State private var speechTask: Task<Void, Never>?
    @State private var speechSessionID: UUID?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if startsQuestion {
                Divider()
            }
            Group {
                if message.role == .user { userRow } else { assistantBlock }
            }
        }
        .accessibilityIdentifier(message.role == .user ? "chat.message.user"
                                                       : "chat.message.assistant")
        .onDisappear {
            stopAssistantSpeech(clearError: false)
        }
    }

    private var userRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            turnMetadata("You asked", systemImage: "person.crop.circle")
            if let scopeSummary = questionScopeSummary {
                Label(scopeSummary, systemImage: "scope")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Question scope: \(scopeSummary)")
            }
            Text(message.text)
                .font(WorkspaceTypography.conversationTitle)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var assistantBlock: some View {
        let parsed = ChatCitationParser.extract(message.text)
        VStack(alignment: .leading, spacing: 10) {
            turnMetadata(assistantTurnLabel, systemImage: "sparkles")
            if message.activity.contains(where: { !$0.done }) {
                WorkedLine(activities: message.activity)
            }
            if message.isPending && message.text.isEmpty {
                ModelPreparationView(
                    presentation: assistantPreparation,
                    style: .standard)
                answerActions(copyText: "", allowsSpeech: false)
            } else if message.isError {
                ModelPreparationView(
                    presentation: .init(
                        state: .failed,
                        title: "Assistant needs attention",
                        status: message.text),
                    style: .standard)
                answerActions(copyText: message.text, allowsSpeech: false)
            } else {
                if !parsed.display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SelectableDigestText(parsed.display, style: .editorial)
                        .foregroundStyle(message.isError ? AnyShapeStyle(.red)
                                                         : AnyShapeStyle(.primary))
                        .contextMenu {
                            Button {
                                toggleAssistantSpeech(parsed.display)
                            } label: {
                                Label(readingSpeech ? "Stop reading aloud" : "Read aloud",
                                      systemImage: assistantSpeechIcon)
                            }
                        }
                        .accessibilityAction(
                            named: Text(readingSpeech ? "Stop reading aloud" : "Read aloud")) {
                                toggleAssistantSpeech(parsed.display)
                            }
                    if let speechError {
                        Text(speechError)
                            .font(.caption2)
                            .foregroundStyle(Brand.error)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                answerActions(copyText: parsed.display, allowsSpeech: true)
                if !parsed.citations.isEmpty {
                    EvidenceDisclosure(citations: parsed.citations)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantTurnLabel: String {
        if message.isPending { return "LokalBot is answering" }
        if message.isError { return "LokalBot could not answer" }
        return "LokalBot answered"
    }

    private var questionScopeSummary: String? {
        guard message.role == .user,
              !message.sourceScopes.isEmpty || message.dayScopeKey != nil else { return nil }
        let selected = Set(message.sourceScopes)
        let sourceText: String
        if selected == AskSourceScope.defaults {
            sourceText = "All sources"
        } else {
            sourceText = AskSourceScope.allCases
                .filter(selected.contains)
                .map(\.displayName)
                .joined(separator: ", ")
        }
        var parts = [sourceText]
        if let dayKey = message.dayScopeKey {
            let dayText: String
            if let day = AskDayScope.date(for: dayKey) {
                dayText = Calendar.current.isDateInToday(day)
                    ? "Today"
                    : day.formatted(date: .abbreviated, time: .omitted)
            } else {
                dayText = dayKey
            }
            parts.append(dayText)
        }
        if !message.attachedScreenDayKeys.isEmpty {
            let days = message.attachedScreenDayKeys.map { key in
                AskDayScope.date(for: key)?.formatted(date: .abbreviated, time: .omitted)
                    ?? key
            }.joined(separator: ", ")
            parts.append("attached screen: \(days)")
        }
        return parts.joined(separator: " · ")
    }

    private func turnMetadata(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .frame(width: 14)
            Text(title)
                .font(WorkspaceTypography.metadataEmphasis)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(message.createdAtIsEstimated
                 ? "Earlier conversation"
                 : message.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(WorkspaceTypography.metadata.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func answerActions(copyText: String, allowsSpeech: Bool) -> some View {
        HStack(spacing: 14) {
            if !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    copyAnswer(copyText)
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(copied)
                .help("Copy this answer")
                .accessibilityIdentifier("chat.answer.copy")
            }

            if allowsSpeech {
                Button {
                    toggleAssistantSpeech(copyText)
                } label: {
                    Label(readingSpeech ? "Stop reading" : "Read aloud",
                          systemImage: assistantSpeechIcon)
                }
                .help(readingSpeech ? "Stop reading aloud" : "Read this answer aloud")
                .accessibilityIdentifier("chat.answer.readAloud")
            }

            if model.canRetry(message.id) {
                Button {
                    model.retry(message.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .help("Try this question again")
                .accessibilityIdentifier("chat.answer.retry")
            }

            if message.isPending && model.isResponding {
                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(.cancelAction)
                .help("Stop answering (Esc)")
                .accessibilityIdentifier("chat.answer.stop")
            }
        }
        .font(WorkspaceTypography.metadata)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func copyAnswer(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var assistantPreparation: ModelPreparationPresentation {
        if app.settings.summarizerBackend == .builtIn,
           let entry = ModelCatalog.entry(
                id: app.settings.builtInModelID,
                custom: app.settings.customBuiltInModels),
           let progress = downloads.progress[entry.id] {
            return .init(
                state: .preparing,
                title: "Preparing \(entry.displayName)",
                status: "Downloading the on-device model — \(Int(progress * 100))%",
                progress: progress)
        }

        switch model.responsePhase {
        case .preparingEngine:
            return .init(
                state: .preparing,
                title: "Preparing the assistant",
                status: app.settings.summarizerBackend == .builtIn
                    ? "Checking the selected on-device model…"
                    : "Connecting to the selected model…")
        case .startingAssistant:
            return .init(
                state: .preparing,
                title: "Starting the assistant",
                status: app.settings.summarizerBackend == .builtIn
                    ? "Loading the model into memory…"
                    : "Waiting for the first response…")
        case nil:
            return .init(
                state: .preparing,
                title: "Preparing the assistant",
                status: "Starting the selected model…")
        }
    }

    private var assistantSpeechIcon: String {
        if readingSpeech { return "stop.fill" }
        if preparingSpeech { return "hourglass" }
        return "speaker.wave.2"
    }

    private func toggleAssistantSpeech(_ text: String) {
        if readingSpeech {
            stopAssistantSpeech()
        } else {
            readAssistantTurn(text)
        }
    }

    private func readAssistantTurn(_ text: String) {
        stopAssistantSpeech(clearError: false)
        speechError = nil
        let sessionID = UUID()
        speechSessionID = sessionID
        preparingSpeech = true
        readingSpeech = true
        speechTask = Task {
            defer { finishAssistantSpeech(sessionID) }
            do {
                let url = try await KokoroSpeechEngine.shared.synthesize(.init(
                    text: text,
                    voice: app.settings.speechVoice,
                    speed: app.settings.speechSpeed,
                    outputURL: nil))
                try Task.checkCancellation()
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                guard speechSessionID == sessionID else { return }
                speechPlayer = player
                preparingSpeech = false
                guard player.play() else {
                    throw NSError(
                        domain: "LokalBot.SpeechPlayback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not start speech playback."])
                }
                try await Task.sleep(
                    nanoseconds: UInt64(max(player.duration, 0.1) * 1_000_000_000))
            } catch is CancellationError {
            } catch {
                if speechSessionID == sessionID {
                    speechError = error.localizedDescription
                }
            }
        }
    }

    private func stopAssistantSpeech(clearError: Bool = true) {
        speechSessionID = nil
        speechTask?.cancel()
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        preparingSpeech = false
        readingSpeech = false
        if clearError {
            speechError = nil
        }
    }

    private func finishAssistantSpeech(_ sessionID: UUID) {
        guard speechSessionID == sessionID else { return }
        speechSessionID = nil
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        preparingSpeech = false
        readingSpeech = false
    }
}

/// One compact evidence disclosure matching inline `[n]` references in the answer.
private struct EvidenceDisclosure: View {
    @EnvironmentObject var app: AppState
    let citations: [ChatCitation]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .padding(.top, 8)
            WorkspaceDisclosure(
                isExpanded: $isExpanded,
                identifier: "chat.evidence") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                        sourceRow(number: index + 1, citation: citation)
                        if index != citations.count - 1 { Divider() }
                    }
                }
                Text("LokalBot used only the sources enabled for this question. Citation numbers remain stable even when a local source is later removed.")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            } label: {
                HStack(spacing: 8) {
                    Label("Evidence", systemImage: "checkmark.shield")
                        .font(WorkspaceTypography.control)
                    Text(evidenceSummary)
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("chat.sources")
    }

    private var evidenceSummary: String {
        guard let first = citations.first else { return "No sources" }
        let keys = Set(citations.map { citation in
            switch citation.kind {
            case .meeting: "meeting:\(citation.meetingID)"
            case .screen: "screen:\(citation.snapshotID.map(String.init) ?? "unknown")"
            }
        })
        if citations.count == 1 {
            return "1 source · \(resolved(first).title)"
        }
        if keys.count == 1 {
            return "\(citations.count) moments from \(resolved(first).title)"
        }
        return "\(citations.count) moments from \(keys.count) sources"
    }

    @ViewBuilder private func sourceRow(number: Int, citation: ChatCitation) -> some View {
        let source = resolved(citation)
        Button {
            guard source.available else { return }
            switch citation.kind {
            case .meeting: app.openCitation(citation)
            case .screen:
                if let snapshotID = citation.snapshotID { app.openScreenSnapshot(snapshotID) }
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(WorkspaceTypography.metadataEmphasis.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Brand.teal, in: Circle())
                Image(systemName: source.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                        .font(WorkspaceTypography.rowTitle)
                        .foregroundStyle(source.available ? .primary : .secondary)
                        .lineLimit(1)
                    Text(source.detail)
                        .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                }
                Spacer()
                if source.available {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Unavailable")
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!source.available)
        .accessibilityHint(source.available
            ? "Opens the cited local evidence"
            : "The cited local source is no longer available")
    }

    private func resolved(_ citation: ChatCitation) -> (
        title: String, detail: String, icon: String, available: Bool
    ) {
        switch citation.kind {
        case .meeting:
            let meeting = (try? SessionLookup.find(
                id: citation.meetingID, in: app.meetings)) ?? nil
            guard let meeting else {
                return ("Meeting \(citation.meetingID)", "Local source missing", "person.2", false)
            }
            let stamp = citation.stampText.map { " · \($0)" } ?? ""
            return (
                meeting.displayTitle,
                "Meeting · \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))\(stamp)",
                "person.2",
                true)
        case .screen:
            guard let snapshotID = citation.snapshotID,
                  let shot = app.activityStore.screenshot(id: snapshotID) else {
                return ("Screen moment", "Local source missing", "display", false)
            }
            return (
                shot.windowTitle.isEmpty ? shot.app : shot.windowTitle,
                "Screen · \(shot.ts.formatted(date: .abbreviated, time: .shortened))",
                "display",
                true)
        }
    }

}

/// Tool activity collapsed to a single caption line ("worked: searched
/// transcripts · read summary"); expands to the per-step rows on click.
/// While a step is in flight it shows that step with a spinner instead.
private struct WorkedLine: View {
    let activities: [ChatMessage.Activity]
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inFlight: ChatMessage.Activity? { activities.first { !$0.done } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    if let current = inFlight {
                        LoadingStateLabel(current.text, controlSize: .mini)
                    } else {
                        Image(systemName: "checkmark.circle").font(.caption2)
                        Text("worked: " + activities.map(\.text).joined(separator: " · "))
                            .lineLimit(1)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                }
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(activities) { ActivityRow(activity: $0) }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: ChatMessage.Activity

    var body: some View {
        HStack(spacing: 6) {
            if activity.done {
                Image(systemName: activity.icon).font(.caption2).foregroundStyle(.secondary)
                Text(activity.text).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            } else {
                LoadingStateLabel(activity.text, controlSize: .mini)
            }
        }
        .chipChrome()
    }
}

/// The Ask section's question history — a selectable list of saved conversations
/// plus a visible "New Question" action. Selecting one loads it into the transcript;
/// conversations persist across launches via `ChatStore`.
struct ChatConversationList: View {
    @EnvironmentObject var app: AppState
    var body: some View { ConversationListContent(model: app.chat) }
}

private struct ConversationListContent: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var historyQuery = ""
    @State private var pendingDeletion: Conversation?

    var body: some View {
        List(selection: conversationSelection) {
            Section {
                Button {
                    model.newConversation()
                } label: {
                    Label("New Question", systemImage: "square.and.pencil")
                        .font(WorkspaceTypography.control)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.teal)
                .keyboardShortcut("n", modifiers: [.command])
                .help("Start a new question")
                .accessibilityIdentifier("chat.new")
            }

            if historySections.isEmpty {
                Text("No questions match “\(historyQuery)”.")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(historySections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.conversations) { conversation in
                            row(conversation)
                                .tag(conversation.id)
                                .accessibilityIdentifier(
                                    "chat.conversation.\(conversation.id.uuidString)")
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingDeletion = conversation
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(WorkspacePalette.conversationColumn(for: colorScheme))
        .searchable(text: $historyQuery, prompt: "Search questions")
        // One native title owns both the visible toolbar label and the window's
        // accessibility title. The detail column deliberately adds no second
        // Ask label.
        .navigationTitle("Ask")
        .accessibilityIdentifier("chat.conversationList")
        .alert(
            "Delete Question?",
            isPresented: deletionConfirmationPresented,
            presenting: pendingDeletion
        ) { conversation in
            Button("Delete", role: .destructive) {
                model.delete(conversation.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { conversation in
            Text("This removes “\(conversation.title)” from Ask history.")
        }
    }

    private var deletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in
                if !presented { pendingDeletion = nil }
            })
    }

    private var conversationSelection: Binding<Conversation.ID?> {
        Binding(
            get: { model.currentID },
            set: { selected in
                guard let selected else { return }
                model.select(selected)
            })
    }

    private var matchingConversations: [Conversation] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.conversations }
        return model.conversations.filter {
            $0.title.localizedStandardContains(query)
                || $0.messages.contains { $0.text.localizedStandardContains(query) }
        }
    }

    private var historySections: [(title: String, conversations: [Conversation])] {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let weekStart = calendar.date(byAdding: .day, value: -7,
                                      to: calendar.startOfDay(for: now)) ?? .distantPast
        let groups: [(String, (Conversation) -> Bool)] = [
            ("Today", { calendar.isDateInToday($0.updatedAt) }),
            ("Yesterday", { calendar.isDateInYesterday($0.updatedAt) }),
            ("Previous 7 Days", {
                !calendar.isDateInToday($0.updatedAt)
                    && !calendar.isDateInYesterday($0.updatedAt)
                    && $0.updatedAt >= weekStart
            }),
            ("Earlier", { $0.updatedAt < weekStart }),
        ]
        return groups.compactMap { title, includes in
            let conversations = matchingConversations.filter(includes)
            return conversations.isEmpty ? nil : (title, conversations)
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title.isEmpty ? ChatViewModel.newChatTitle : conversation.title)
                .font(WorkspaceTypography.rowTitle).lineLimit(2)
            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
