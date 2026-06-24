import SwiftUI

/// The "Chat" section: a conversational assistant over the user's meetings.
/// Reuses the summarisation `TextEngine` and a small ReAct agent (`ChatAgent`)
/// that can search transcripts, list meetings, and read a meeting's summary or
/// transcript via tool calls — all on-device.
struct ChatView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ChatContent(model: app.chat)
            .navigationTitle("Assistant")
    }
}

private struct ChatContent: View {
    @ObservedObject var model: ChatViewModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            inputBar
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { model.clear() } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .disabled(model.messages.isEmpty || model.isResponding)
                .help("Clear the conversation")
                .accessibilityIdentifier("chat.clear")
            }
        }
        .onAppear { inputFocused = true }
    }

    // MARK: - Transcript

    @ViewBuilder private var transcript: some View {
        if model.messages.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages) { message in
                            ChatBubble(message: message).id(message.id)
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
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = model.messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40)).foregroundStyle(.tint)
            Text("Chat with your meetings").font(.title2.bold())
            Text("Ask about anything from your recorded meetings — decisions, action items, who said what. Everything stays on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
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
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("chat.empty")
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("Ask about your meetings…", text: $model.draft)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit { model.send() }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("chat.input")

            if model.isResponding {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Stop")
                .accessibilityIdentifier("chat.stop")
            } else {
                Button { model.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .disabled(!model.canSend)
                .accessibilityIdentifier("chat.send")
            }
        }
        .padding(12)
    }
}

// MARK: - Bubble

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if !message.activity.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.activity) { ActivityRow(activity: $0) }
                    }
                }
                content
            }
            if message.role == .assistant { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .accessibilityIdentifier(message.role == .user ? "chat.message.user" : "chat.message.assistant")
    }

    @ViewBuilder private var content: some View {
        if message.role == .user {
            Text(message.text)
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.tint, in: RoundedRectangle(cornerRadius: 12))
        } else if message.isPending && message.text.isEmpty {
            TypingIndicator()
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        } else {
            MarkdownText(message.text)
                .textSelection(.enabled)
                .foregroundStyle(message.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(message.isError
                            ? AnyShapeStyle(Color.red.opacity(0.08))
                            : AnyShapeStyle(.quaternary.opacity(0.5)),
                            in: RoundedRectangle(cornerRadius: 12))
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
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }
}

/// Three pulsing dots shown while the assistant's first token is pending.
private struct TypingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle().frame(width: 6, height: 6).opacity(phase == index ? 1 : 0.3)
            }
        }
        .foregroundStyle(.secondary)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
        .accessibilityLabel("Assistant is thinking")
    }
}
