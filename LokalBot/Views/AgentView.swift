import SwiftUI

/// Agent Mode root: global runtime setup followed by a desktop tab strip.
/// Each live tab owns an independent AgentSessionController and pi process.
struct AgentView: View {
    @ObservedObject var sessions: AgentSessionTabs
    @ObservedObject var installer: AgentRuntimeInstaller

    var body: some View {
        Group {
            if installer.phase == .installed {
                sessionTabs
            } else {
                installCard
            }
        }
        .navigationTitle("Agent")
    }

    private var sessionTabs: some View {
        VStack(spacing: 0) {
            AgentSessionTabBar(sessions: sessions)
            Divider()
            ZStack {
                // Keep every tab mounted so its draft, scroll position, task,
                // approvals, and live process continue while another is shown.
                ForEach(sessions.tabs) { tab in
                    AgentSessionView(
                        controller: tab.controller,
                        isSelected: sessions.selectedID == tab.id)
                        .opacity(sessions.selectedID == tab.id ? 1 : 0)
                        .allowsHitTesting(sessions.selectedID == tab.id)
                        .accessibilityHidden(sessions.selectedID != tab.id)
                        .zIndex(sessions.selectedID == tab.id ? 1 : 0)
                }
            }
        }
    }

    // MARK: - Install card

    private var installCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles").font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Agent Mode").font(.title2.bold())
            Text("An on-device coding and file agent powered by your Main LLM engine. Setup downloads about 50 MB and uses about 225 MB after installation. Agent sessions stay local; commands you approve run with your Mac user permissions and may access files or the network.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            switch installer.phase {
            case .idle:
                Button("Download & Enable Agent Mode") {
                    Task { await installer.installIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agent.install")
            case .downloading(let name, let progress):
                ProgressView(value: progress >= 0 ? progress : nil)
                    .frame(maxWidth: 320)
                Text("Downloading \(name)…").font(.caption).foregroundStyle(.secondary)
            case .installing(let name):
                ProgressView().controlSize(.small)
                Text("Installing \(name)…").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: 420)
                Button("Try Again") { Task { await installer.installIfNeeded() } }
                    .accessibilityIdentifier("agent.installRetry")
            case .installed:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentSessionTabBar: View {
    @ObservedObject var sessions: AgentSessionTabs
    @State private var pendingClose: UUID?
    @State private var confirmingHistoryClear = false
    @State private var historyClearError: String?

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(sessions.tabs) { tab in
                        AgentSessionTabItem(
                            tab: tab,
                            isSelected: sessions.selectedID == tab.id,
                            select: { sessions.select(tab.id) },
                            close: { requestClose(tab) })
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("agent.tabs")

            Button {
                sessions.addSession()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("New Agent Session")
            .accessibilityLabel("New Agent Session")
            .accessibilityIdentifier("agent.newSession")

            Menu {
                Button("Clear Saved Agent History…", role: .destructive) {
                    confirmingHistoryClear = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Agent session options")
            .accessibilityLabel("Agent session options")
            .accessibilityIdentifier("agent.sessionOptions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .confirmationDialog(
            "Close \(pendingTab?.title ?? "this session")?",
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } })) {
            Button("Close Session", role: .destructive) {
                guard let id = pendingClose else { return }
                pendingClose = nil
                Task { await sessions.close(id) }
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text("Its conversation, pending work, and unsent draft will be discarded.")
        }
        .confirmationDialog(
            "Clear all saved Agent history?",
            isPresented: $confirmingHistoryClear) {
            Button("Clear History", role: .destructive) {
                Task {
                    do {
                        try await sessions.clearSavedHistory()
                    } catch {
                        historyClearError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This closes every Agent session and permanently removes their local conversations and drafts. Your meeting library is not affected.")
        }
        .alert("Couldn’t Clear Agent History", isPresented: Binding(
            get: { historyClearError != nil },
            set: { if !$0 { historyClearError = nil } })) {
            Button("OK") { historyClearError = nil }
        } message: {
            Text(historyClearError ?? "Unknown error")
        }
    }

    private var pendingTab: AgentSessionTabs.Tab? {
        sessions.tabs.first { $0.id == pendingClose }
    }

    private func requestClose(_ tab: AgentSessionTabs.Tab) {
        if tab.controller.requiresCloseConfirmation {
            pendingClose = tab.id
        } else {
            Task { await sessions.close(tab.id) }
        }
    }
}

private struct AgentSessionTabItem: View {
    let tab: AgentSessionTabs.Tab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @ObservedObject private var controller: AgentSessionController

    init(tab: AgentSessionTabs.Tab,
         isSelected: Bool,
         select: @escaping () -> Void,
         close: @escaping () -> Void) {
        self.tab = tab
        self.isSelected = isSelected
        self.select = select
        self.close = close
        _controller = ObservedObject(wrappedValue: tab.controller)
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(tab.title)
                        .font(.callout)
                        .lineLimit(1)
                }
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(tab.title), \(statusLabel)")
            .accessibilityIdentifier("agent.tab.\(tab.id.uuidString)")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(tab.title)")
            .accessibilityLabel("Close \(tab.title)")
            .accessibilityIdentifier("agent.tab.close.\(tab.id.uuidString)")
        }
        .padding(.vertical, 2)
        .padding(.trailing, 3)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.32) : Color.secondary.opacity(0.16))
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .idle, .starting: return .secondary
        case .ready: return .green
        case .running: return .blue
        case .failed: return .orange
        }
    }

    private var statusLabel: String {
        switch controller.state {
        case .idle, .starting: return "starting"
        case .ready: return "ready"
        case .running: return "working"
        case .failed: return "needs attention"
        }
    }
}
