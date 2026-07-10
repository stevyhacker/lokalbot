import SwiftUI
import UniformTypeIdentifiers

/// One live Agent Mode tab. Its local draft and view state stay mounted while
/// another tab is selected; its controller owns the independent pi process.
struct AgentSessionView: View {
    @ObservedObject var controller: AgentSessionController
    @State private var draft = ""
    @State private var pickingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .task { await controller.start() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                pickingFolder = true
            } label: {
                Label(controller.workspace.lastPathComponent.isEmpty
                      ? controller.workspace.path : controller.workspace.lastPathComponent,
                      systemImage: "folder")
            }
            .help(controller.workspace.path)
            .fileImporter(isPresented: $pickingFolder,
                          allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    controller.workspace = url
                    Task { await controller.shutdown(); await controller.start() }
                }
            }
            .accessibilityIdentifier("agent.workspace")

            statusBadge
            if case .failed = controller.state {
                Button("Restart") {
                    Task { await controller.shutdown(); await controller.start() }
                }
                .accessibilityIdentifier("agent.restart")
            }
            Spacer()
            Toggle("Auto-approve", isOn: $controller.autoApproveSession)
                .toggleStyle(.switch).controlSize(.small)
                .help("Approve every file edit and shell command this session without asking")
                .accessibilityIdentifier("agent.autoApprove")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var statusBadge: some View {
        switch controller.state {
        case .idle, .starting:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Starting…") }
                .font(.caption).foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .running:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Working…") }
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(1).help(message)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.items) { item in
                        row(for: item).id(item.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: controller.items.count) {
                if let last = controller.items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.transcript")
    }

    @ViewBuilder private func row(for item: AgentTranscriptItem) -> some View {
        switch item {
        case .user(_, let text):
            Text(text)
                .padding(10)
                .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant(_, let text, let isStreaming):
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(text))   // renders markdown
                    .textSelection(.enabled)
                if isStreaming {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(_, let name, let argsJSON, let output, let status):
            toolCard(name: name, argsJSON: argsJSON, output: output, status: status)
        case .approval(let id, let tool, let argsJSON):
            approvalCard(id: id, tool: tool, argsJSON: argsJSON)
        case .notice(_, let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.caption)
                .foregroundStyle(isError ? .orange : .secondary)
        }
    }

    private func toolCard(name: String, argsJSON: String, output: String, status: AgentToolStatus) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if !argsJSON.isEmpty {
                    Text(argsJSON).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(12)
                }
                if !output.isEmpty {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                switch status {
                case .running: ProgressView().controlSize(.mini)
                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                Text(name).font(.callout.weight(.medium).monospaced())
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func approvalCard(id: String, tool: String, argsJSON: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The agent wants to run \(tool)", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
            if !argsJSON.isEmpty {
                Text(argsJSON).font(.caption.monospaced())
                    .lineLimit(8).textSelection(.enabled)
            }
            HStack {
                Button("Allow Once") {
                    Task { await controller.respondToApproval(id: id, approved: true, scope: .once) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agent.approve.once")
                Button("Allow \(tool) This Session") {
                    Task { await controller.respondToApproval(id: id, approved: true, scope: .session) }
                }
                .accessibilityIdentifier("agent.approve.session")
                Button("Deny", role: .destructive) {
                    Task { await controller.respondToApproval(id: id, approved: false, scope: .once) }
                }
                .accessibilityIdentifier("agent.approve.deny")
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.4)))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit(submit)
                .accessibilityIdentifier("agent.composer")
            if controller.state == .running {
                Button("Stop") { Task { await controller.abort() } }
                    .accessibilityIdentifier("agent.stop")
            }
            Button("Send", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !(controller.state == .ready || controller.state == .running))
                .accessibilityIdentifier("agent.send")
        }
        .padding(12)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await controller.send(prompt: text) }
    }
}
