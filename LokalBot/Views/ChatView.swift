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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.messages) { message in
                        EditorialTurn(message: message, model: model).id(message.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("chat.messages")
            .onChange(of: model.messages.count) { scrollToEnd(proxy) }
            .onChange(of: model.messages.last?.text) { scrollToEnd(proxy) }
            .onChange(of: model.messages.last?.activity.count) { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = model.messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
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
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Brand.teal)
                .frame(width: 3)
            Text(message.text)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Brand.teal.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var assistantBlock: some View {
        let parsed = ChatCitationParser.extract(message.text)
        VStack(alignment: .leading, spacing: 6) {
            if !message.activity.isEmpty {
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
                    HStack(spacing: 6) {
                        Button {
                            toggleAssistantSpeech(parsed.display)
                        } label: {
                            Image(systemName: assistantSpeechIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(readingSpeech ? "Stop reading aloud" : "Read aloud")
                        if let speechError {
                            Text(speechError)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                MarkdownText(parsed.display)
                    .textSelection(.enabled)
                    .foregroundStyle(message.isError ? AnyShapeStyle(.red)
                                                     : AnyShapeStyle(.primary))
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

/// Visual sources parsed from the assistant's meeting and screen citation
/// markers. Meetings stay compact chips; screen sources carry a private local
/// thumbnail and open Timeline at the exact captured moment.
private struct CitationRow: View {
    @EnvironmentObject var app: AppState
    let citations: [ChatCitation]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(citations) { citation in
                    switch citation.kind {
                    case .meeting:
                        Button {
                            app.openCitation(citation)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "quote.opening").font(.caption2)
                                Text(label(for: citation)).font(.caption).lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                            .chipChrome()
                        }
                        .buttonStyle(.plain)
                        .help("Open this meeting")
                        .accessibilityIdentifier("chat.citation.meeting.\(citation.meetingID)")
                    case .screen:
                        if let snapshotID = citation.snapshotID {
                            ScreenCitationCard(snapshotID: snapshotID)
                        }
                    }
                }
            }
        }
    }

    private func label(for citation: ChatCitation) -> String {
        let meeting = (try? SessionLookup.find(id: citation.meetingID, in: app.meetings)) ?? nil
        let title = meeting?.title ?? "Meeting \(citation.meetingID)"
        guard let stamp = citation.stampText else { return title }
        return "\(title) · \(stamp)"
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
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                        Text(current.text)
                    } else {
                        Image(systemName: "checkmark.circle").font(.caption2)
                        Text("worked: " + activities.map(\.text).joined(separator: " · "))
                            .lineLimit(1)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                }
                .font(.caption)
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
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            }
            Text(activity.text).font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        List(selection: Binding(
            get: { model.currentID },
            set: { if let id = $0 { model.select(id) } })) {
            ForEach(model.conversations) { conversation in
                row(conversation)
                    .tag(conversation.id)
                    .contextMenu {
                        Button(role: .destructive) { model.delete(conversation.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem {
                Button { model.newConversation() } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .help("Start a new conversation")
                .accessibilityIdentifier("chat.new")
            }
        }
        .accessibilityIdentifier("chat.conversationList")
    }

    private func row(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title.isEmpty ? ChatViewModel.newChatTitle : conversation.title)
                .font(.body).lineLimit(1)
            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("chat.conversation.\(conversation.id.uuidString)")
    }
}
