import SwiftUI

/// Outcome-first Autocomplete home. Advanced tuning lives in Settings;
/// rehearsal and preview call the real completion engine but intentionally do
/// not touch production acceptance statistics or the learning store.
struct AutocompleteExperienceView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var stats = CotypingStatsStore.shared

    @State private var text = "Hi Sarah, thanks for the update. I wanted to follow"
#if LOKALBOT_UI_TEST_HOST
    @State private var suggestion = ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1"
        ? " up on the migration timeline we scoped yesterday." : ""
#else
    @State private var suggestion = ""
#endif
    @State private var generating = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var rehearsalStep = 0
    @State private var rehearsalActive = false

    private let rehearsalPrompt = "Reply to the team: Thanks for reviewing the proposal. Next"

    private var selectedModel: ModelCatalog.Entry? {
        ModelCatalog.entry(
            id: app.settings.cotypingBuiltInModelID,
            custom: app.settings.customBuiltInModels)
    }

    private var modelReady: Bool {
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1" { return true }
#endif
        return selectedModel.flatMap { ModelCatalog.localURL(for: $0, storage: app.storage) } != nil
    }

    private var demoReady: Bool {
#if LOKALBOT_UI_TEST_HOST
        ProcessInfo.processInfo.environment["LOKALBOT_COTYPING_DEMO"] == "1"
#else
        false
#endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                header
                readiness
                preview
                rehearsal
                privacy
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task {
            permissions.startPolling()
            if app.settings.cotypingBuiltInModelID.isEmpty {
                app.settings.cotypingBuiltInModelID = ModelCatalog.recommendedCotypingID
            }
        }
        .onDisappear {
            permissions.stopPolling()
            task?.cancel()
        }
        .navigationTitle("Autocomplete")
        .accessibilityIdentifier("autocomplete.home")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Autocomplete").font(WorkspaceTypography.display)
                Text("Fast, private sentence completion in almost any Mac app.")
                    .font(WorkspaceTypography.body).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enable", isOn: $app.settings.cotypingEnabled)
                .toggleStyle(.switch)
            Button {
                app.openSettings(tab: .general)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private var readiness: some View {
        WorkspaceSection(title: "Ready to type", icon: "checkmark.circle") {
            HStack(spacing: 16) {
                readinessItem(
                    "Model",
                    selectedModel?.displayName ?? "LFM2.5 1.2B Instruct",
                    ready: modelReady)
                Divider().frame(height: 34)
                readinessItem(
                    "Accessibility",
                    permissionLabel(.accessibility),
                    ready: demoReady || (permissions.granted[.accessibility] ?? false))
                Divider().frame(height: 34)
                readinessItem(
                    "Input Monitoring",
                    permissionLabel(.inputMonitoring),
                    ready: demoReady || (permissions.granted[.inputMonitoring] ?? false))
                Spacer()
                StatTile(icon: "text.badge.plus", value: "\(stats.stats.generations)",
                         label: "suggested")
                StatTile(icon: "checkmark", value: "\(stats.stats.accepts)", label: "accepted")
            }
            if !modelReady {
                CotypingModelPreparationView(compact: true)
            }
        }
    }

    private func readinessItem(_ title: String, _ detail: String, ready: Bool) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: ready ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                Text(detail).font(WorkspaceTypography.rowTitle).lineLimit(1)
            }
        }
    }

    private func permissionLabel(_ permission: AppPermission) -> String {
        (demoReady || (permissions.granted[permission] ?? false)) ? "Granted" : "Needs permission"
    }

    private var preview: some View {
        WorkspaceSection(title: "Try the real autocomplete", icon: "text.cursor") {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    .font(WorkspaceTypography.body)
                    .frame(minHeight: 120)
                    .padding(8)
                    .workspaceControl()
                    .onChange(of: text) { _, _ in schedule() }

                HStack {
                    Text("Suggestion")
                        .font(WorkspaceTypography.metadataEmphasis)
                        .foregroundStyle(.secondary)
                    if generating { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Accept \(app.settings.cotypingAcceptKey.label)", action: accept)
                        .buttonStyle(.borderedProminent)
                        .disabled(suggestion.isEmpty)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Brand.error)
                } else {
                    Text(previewAttributed)
                        .font(WorkspaceTypography.body)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.25),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var previewAttributed: AttributedString {
        var value = AttributedString(String(text.suffix(110)))
        var ghost = AttributedString(suggestion)
        ghost.foregroundColor = Brand.teal
        value.append(ghost)
        return value
    }

    private var rehearsal: some View {
        WorkspaceSection(title: "Two-step rehearsal", icon: "figure.walk") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Practice generation and acceptance here before enabling it system-wide.")
                    .font(WorkspaceTypography.body).foregroundStyle(.secondary)
                rehearsalRow(
                    number: 1,
                    title: "Generate a real suggestion",
                    state: rehearsalStep >= 1 ? "Detected" : "Not started",
                    complete: rehearsalStep >= 1) {
                        rehearsalActive = true
                        rehearsalStep = 0
                        text = rehearsalPrompt
                        suggestion = ""
                        schedule()
                    }
                rehearsalRow(
                    number: 2,
                    title: "Accept with \(app.settings.cotypingAcceptKey.label)",
                    state: rehearsalStep >= 2 ? "Accepted" : "Waiting",
                    complete: rehearsalStep >= 2)
                if rehearsalStep == 2 {
                    Label("Rehearsal complete", systemImage: "checkmark.seal.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(Brand.teal)
                }
                Text("Rehearsal is excluded from production stats and learned writing data.")
                    .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            }
        }
    }

    private func rehearsalRow(number: Int, title: String, state: String,
                              complete: Bool, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(complete ? Brand.teal : .secondary)
            Text(title)
            Spacer()
            Text(state).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            if let action {
                Button(rehearsalActive ? "Restart" : "Start", action: action)
            }
        }
    }

    private var privacy: some View {
        WorkspaceSection(title: "Private by design", icon: "lock.shield") {
            HStack(alignment: .top, spacing: 12) {
                Label("Generated on this Mac", systemImage: "memorychip")
                Label("Never runs in password fields", systemImage: "key")
                Label("Apps and sites can be excluded", systemImage: "nosign")
                Spacer()
            }
            .font(WorkspaceTypography.body).foregroundStyle(.secondary)
        }
    }

    private func schedule() {
        task?.cancel()
        suggestion = ""
        error = nil
        let context = text
        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(app.settings.cotypingDebounceMs))
            guard !Task.isCancelled else { return }
            generating = true
            defer { generating = false }
            do {
                let result = try await app.cotyping.previewSuggestion(precedingText: context)
                if !Task.isCancelled {
                    suggestion = result
                    if rehearsalActive, !result.isEmpty { rehearsalStep = max(rehearsalStep, 1) }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func accept() {
        guard !suggestion.isEmpty else { return }
        text += suggestion
        suggestion = ""
        if rehearsalActive, rehearsalStep >= 1 { rehearsalStep = 2 }
    }
}
