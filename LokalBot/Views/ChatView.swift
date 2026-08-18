import SwiftUI
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { message in
                        EditorialTurn(message: message, model: model).id(message.id)
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
            .onChange(of: model.messages.count) { scrollToEnd(proxy) }
            .onChange(of: model.messages.last?.text) { scrollToEnd(proxy) }
            .onChange(of: model.messages.last?.activity.count) { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = model.messages.last?.id else { return }
        withAnimation(WorkspaceMotion.animation(.autoScroll, reduceMotion: reduceMotion)) {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

private struct EditorialTurn: View {
    @EnvironmentObject var app: AppState
    let message: ChatMessage
    @ObservedObject var model: ChatViewModel
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var speechPlayer: AVAudioPlayer?
    @State private var speechError: String?
    @State private var preparingSpeech = false
    @State private var readingSpeech = false
    @State private var speechTask: Task<Void, Never>?
    @State private var speechSessionID: UUID?

    var body: some View {
        Group {
            if message.role == .user { userRow } else { assistantBlock }
        }
        .accessibilityIdentifier(message.role == .user ? "chat.message.user"
                                                       : "chat.message.assistant")
        .onDisappear {
            stopAssistantSpeech(clearError: false)
        }
    }

    private var userRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle")
                Text("Answered just now")
            }
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
            Text(message.text)
                .font(WorkspaceTypography.conversationTitle)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var assistantBlock: some View {
        let parsed = ChatCitationParser.extract(message.text)
        VStack(alignment: .leading, spacing: 6) {
            if message.activity.contains(where: { !$0.done }) {
                WorkedLine(activities: message.activity)
            }
            if message.isPending && message.text.isEmpty {
                ModelPreparationView(
                    presentation: assistantPreparation,
                    style: .standard)
            } else if message.isError {
                ModelPreparationView(
                    presentation: .init(
                        state: .failed,
                        title: "Assistant needs attention",
                        status: message.text,
                        actionTitle: model.canRetry(message.id) ? "Retry" : nil),
                    style: .standard,
                    action: model.canRetry(message.id) ? { model.retry(message.id) } : nil)
            } else {
                if !parsed.display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownText(parsed.display, style: .editorial)
                        .textSelection(.enabled)
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
                if !parsed.citations.isEmpty {
                    CitationRow(citations: parsed.citations)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Numbered source table matching inline `[n]` references in the answer.
private struct CitationRow: View {
    @EnvironmentObject var app: AppState
    let citations: [ChatCitation]
    @State private var explanationExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 18)
            Text("Sources")
                .font(WorkspaceTypography.editorialSectionTitle)
                .padding(.bottom, 6)
            ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                sourceRow(number: index + 1, citation: citation)
                if index != citations.count - 1 { Divider() }
            }
            WorkspaceDisclosure(
                isExpanded: $explanationExpanded,
                identifier: "chat.answerExplanation") {
                Text("LokalBot used only the sources enabled for this question. Citation numbers remain stable even when a local source is later removed.")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
            } label: {
                Text("How this answer was built")
                    .font(WorkspaceTypography.control)
            }
            .padding(.top, 20)
        }
        .accessibilityIdentifier("chat.sources")
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
                HStack(spacing: 8) {
                    Text(source.available ? "Jump to evidence" : "Source unavailable")
                    if source.available { Image(systemName: "arrow.up.right.square") }
                }
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.13))
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!source.available)
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

/// The Chat section's conversation history — a selectable list of saved
/// conversations plus a "New chat" action. Selecting one loads it into the
/// transcript; conversations persist across launches via `ChatStore`.
struct ChatConversationList: View {
    @EnvironmentObject var app: AppState
    var body: some View { ConversationListContent(model: app.chat) }
}

private struct ConversationListContent: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.conversations) { conversation in
                    Button {
                        model.select(conversation.id)
                    } label: {
                        row(conversation, selected: model.currentID == conversation.id)
                    }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            model.currentID == conversation.id ? .isSelected : [])
                        .contextMenu {
                            Button(role: .destructive) { model.delete(conversation.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
        }
        .background(WorkspacePalette.conversationColumn(for: colorScheme))
        // One native title owns both the visible toolbar label and the window's
        // accessibility title. The detail column deliberately adds no second
        // Ask label.
        .navigationTitle("Ask")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newConversation() } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .help("Start a new conversation")
                .accessibilityIdentifier("chat.new")
            }
        }
        .accessibilityIdentifier("chat.conversationList")
    }

    private func row(_ conversation: Conversation, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title.isEmpty ? ChatViewModel.newChatTitle : conversation.title)
                .font(WorkspaceTypography.rowTitle).lineLimit(2)
            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 9)
        .background(
            selected ? Color.primary.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: Brand.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityIdentifier("chat.conversation.\(conversation.id.uuidString)")
    }
}
