import SwiftUI

/// The Cotyping section: enable + permission control center, model info, a live
/// in-app preview (runs the real pipeline with no system grants), and tips.
struct CotypingView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        CotypingContent(coordinator: app.cotyping)
            .environmentObject(app)
            .navigationTitle("Cotyping")
    }
}

private struct CotypingContent: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var coordinator: CotypingCoordinator
    @StateObject private var permissions = PermissionManager.shared

    @State private var previewText = "Hi Sarah, thanks for the update. I wanted to follow"
    @State private var ghost = ""
    @State private var previewError: String?
    @State private var previewing = false
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        Form {
            headerSection
            if app.settings.cotypingEnabled { permissionsSection }
            modelSection
            previewSection
            tipsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling(); previewTask?.cancel() }
        .onChange(of: permissions.granted) { _, _ in
            if app.settings.cotypingEnabled { app.cotyping.applySettings() }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Inline AI autocomplete").font(.headline)
                    Text("As you type in almost any app, a gray suggestion appears next to your cursor. Press Tab to accept it, or keep typing to ignore it. Runs on the same on-device model as your summaries — nothing leaves this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Toggle("Enable cotyping", isOn: $app.settings.cotypingEnabled)
            statusRow
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).foregroundStyle(.secondary).font(.callout)
            Spacer()
        }
    }

    private var statusColor: Color {
        guard app.settings.cotypingEnabled else { return .secondary }
        switch coordinator.state {
        case .ready, .generating: return .green
        case .debouncing, .idle: return coordinator.isRunning ? .green : .orange
        case .disabled: return .orange
        case .failed: return .red
        }
    }

    private var statusText: String {
        guard app.settings.cotypingEnabled else { return "Off — turn it on to start suggesting." }
        if coordinator.isRunning {
            return "Active — \(coordinator.state.label.lowercased())"
        }
        return coordinator.state.label
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow(.accessibility,
                          why: "Reads the text and caret position in the field you're typing in.")
            permissionRow(.inputMonitoring,
                          why: "Notices your keystrokes so it knows when to suggest, and catches the Tab key.")
            if !(permissions.granted[.accessibility] ?? false) {
                Text("Accessibility grants apply at launch — you may need to quit and reopen LokalBot after granting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ permission: AppPermission, why: String) -> some View {
        let granted = permissions.granted[permission] ?? permission.isGranted
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…") {
                    PermissionManager.shared.request(permission)
                    PermissionManager.shared.openSettings(for: permission)
                }
            }
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Engine") {
                Text(engineDescription).foregroundStyle(.secondary)
            }
            Text("Cotyping reuses your Summarization backend and model (change it in Settings → Summarization). A small, fast model gives the snappiest suggestions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var engineDescription: String {
        switch app.settings.summarizerBackend {
        case .builtIn:
            return ModelCatalog.entry(id: app.settings.builtInModelID,
                                      custom: app.settings.customBuiltInModels)?.displayName
                ?? "Built-in model"
        case .appleIntelligence: return "Apple Intelligence"
        case .ollama:
            return "Ollama — " + (app.settings.ollamaModel.isEmpty ? "no model selected" : app.settings.ollamaModel)
        case .openAICompatible:
            return "OpenAI-compatible — " + (app.settings.openAIModel.isEmpty ? "no model selected" : app.settings.openAIModel)
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        Section("Try it") {
            Text("Type below and pause — the same engine that powers system-wide cotyping suggests a continuation right here, no permissions needed.")
                .font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $previewText)
                .font(.system(size: 13))
                .frame(minHeight: 70)
                .onChange(of: previewText) { _, _ in schedulePreview() }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Suggestion").font(.caption).foregroundStyle(.secondary)
                    if previewing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Accept ⇥") { acceptPreview() }
                        .controlSize(.small)
                        .disabled(ghost.isEmpty)
                }
                Group {
                    if let previewError {
                        Label(previewError, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    } else if ghost.isEmpty {
                        Text(previewing ? "Thinking…" : "Pause typing to see a suggestion.")
                            .font(.callout).foregroundStyle(.tertiary)
                    } else {
                        Text(previewAttributed)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Show only the tail of the typed text so the ghost stays visible.
    private var previewTextTail: String {
        let tail = previewText.suffix(80)
        return previewText.count > 80 ? "…" + tail : String(tail)
    }

    /// The typed tail plus the ghost continuation (ghost in accent color) as one
    /// wrapping paragraph. AttributedString avoids the deprecated `Text` `+`.
    private var previewAttributed: AttributedString {
        var result = AttributedString(previewTextTail)
        var continuation = AttributedString(ghost)
        continuation.foregroundColor = .accentColor
        result.append(continuation)
        return result
    }

    private func schedulePreview() {
        previewTask?.cancel()
        ghost = ""
        previewError = nil
        let text = previewText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            previewing = true
            defer { previewing = false }
            do {
                let suggestion = try await app.cotyping.previewSuggestion(precedingText: text)
                if !Task.isCancelled { ghost = suggestion }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    previewError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func acceptPreview() {
        guard !ghost.isEmpty else { return }
        previewText += ghost
        ghost = ""
        schedulePreview()
    }

    // MARK: Tips

    private var tipsSection: some View {
        Section("How it works") {
            tip("keyboard", "Type and pause — a suggestion appears next to your cursor.")
            tip("return", "Press Tab to accept, Esc or keep typing to dismiss.")
            tip("hand.raised", "Never runs in password fields, and skips the apps you exclude in Settings → Cotyping.")
            tip("lock.shield", "Suggestions are generated on-device by your local model. Nothing is sent anywhere.")
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }
}
