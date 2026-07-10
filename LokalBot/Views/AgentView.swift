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
                    AgentSessionView(controller: tab.controller)
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
            Text("An on-device coding and file agent (pi) powered by your Main LLM engine. It runs entirely on this Mac — the one-time ~50 MB runtime download below is the only network access the agent itself ever makes. Commands you approve run with your full permissions and can do anything you could — including accessing the network.")
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

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(sessions.tabs) { tab in
                        AgentSessionTabItem(
                            tab: tab,
                            isSelected: sessions.selectedID == tab.id,
                            select: { sessions.select(tab.id) },
                            close: { Task { await sessions.close(tab.id) } })
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("agent.tabs")

            Button {
                sessions.addSession()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("New Agent Session")
            .accessibilityLabel("New Agent Session")
            .accessibilityIdentifier("agent.newSession")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial)
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
            .accessibilityLabel("Open \(tab.title)")
            .accessibilityIdentifier("agent.tab.\(tab.id.uuidString)")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
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
}
