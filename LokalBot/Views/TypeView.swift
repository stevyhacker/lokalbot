import SwiftUI

/// The Type pillar — dictation and cotyping merged into one writing-tools
/// surface (spec §2.4): a shared slate status header showing both features'
/// live state, then a segmented control hosting the existing forms intact.
struct TypeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TypeStatusHeader(coordinator: app.cotyping, dictation: app.dictation)
                Picker("Tool", selection: $app.typeTab) {
                    Text("Dictation").tag(AppState.TypeTab.dictation)
                    Text("Cotyping").tag(AppState.TypeTab.cotyping)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("type.tab")
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            switch app.typeTab {
            case .dictation: DictationView(dictation: app.dictation)
            case .cotyping: CotypingView()
            }
        }
        .navigationTitle("Type")
    }
}

/// One card, both features: dictation shortcut + live state on the left,
/// cotyping state + acceptance stats on the right, permission chips below.
/// They share the Accessibility grant; the mic is dictation-only.
private struct TypeStatusHeader: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var coordinator: CotypingCoordinator
    @ObservedObject var dictation: DictationCoordinator
    @ObservedObject private var stats = CotypingStatsStore.shared
    @ObservedObject private var permissions = PermissionManager.shared

    var body: some View {
        HeroPanel(radius: Brand.Radius.card) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 20) {
                    featureColumn(icon: "mic.badge.plus",
                                  title: "Dictation",
                                  status: dictationStatus,
                                  live: app.dictation.state.isRecording,
                                  toggleLabel: "Global shortcut",
                                  isOn: $app.settings.dictationEnabled,
                                  toggleID: "type.header.dictation")
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                    featureColumn(icon: "text.cursor",
                                  title: "Cotyping",
                                  status: cotypingStatus,
                                  live: app.settings.cotypingEnabled && coordinator.isRunning,
                                  toggleLabel: "Inline suggestions",
                                  isOn: $app.settings.cotypingEnabled,
                                  toggleID: "type.header.cotyping")
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    StatTile(icon: "text.badge.plus",
                             value: "\(stats.stats.generations)",
                             label: "suggested")
                    StatTile(icon: "checkmark",
                             value: "\(stats.stats.accepts)",
                             label: "accepted")
                    Spacer()
                    permissionChip(.accessibility)
                    permissionChip(.inputMonitoring)
                    if app.typeTab == .dictation {
                        permissionChip(.microphone)
                    }
                }
                // Slate stays dark in both appearances, so the system-styled
                // tiles/chips must resolve their semantic colors dark-side.
                .environment(\.colorScheme, .dark)
            }
        }
        .accessibilityIdentifier("type.header")
    }

    private func featureColumn(icon: String, title: String, status: String,
                               live: Bool, toggleLabel: String,
                               isOn: Binding<Bool>, toggleID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.tealBright)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if live { LiveWaveform(barCount: 5, barWidth: 2.5, maxHeight: 10) }
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(2, reservesSpace: true)
            Toggle(toggleLabel, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
                .foregroundStyle(.white)
                .tint(Brand.tealBright)
                .accessibilityIdentifier(toggleID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func permissionChip(_ permission: AppPermission) -> some View {
        let granted = permissions.granted[permission] ?? false
        let chip = HStack(spacing: 3) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(permission.title)
                .foregroundStyle(.white.opacity(0.65))
        }
        .font(.caption2)

        if granted {
            chip.help("\(permission.title): granted")
        } else {
            Button {
                PermissionGuidanceController.shared.requestAccess(for: permission)
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .help(permission.guidanceHint)
            .accessibilityLabel("Grant \(permission.title) access")
        }
    }

    private var dictationStatus: String {
        if app.dictation.isStarting { return "Starting the microphone…" }
        switch app.dictation.state {
        case .recording: return "Listening \(app.dictation.timerLabel)"
        case .transcribing: return "Transcribing \(app.dictation.timerLabel)"
        case .composing: return "Composing \(app.dictation.timerLabel)"
        case .idle:
            guard app.settings.dictationEnabled else {
                return "Ready from this screen. Turn on the shortcut for system-wide use."
            }
            return app.dictation.isShortcutMonitoringActive
                ? "Ready — hold \(DictationShortcut.label) to compose."
                : "Shortcut inactive."
        }
    }

    private var cotypingStatus: String {
        guard app.settings.cotypingEnabled else {
            return "Off — turn it on to suggest as you type, in almost any app."
        }
        if coordinator.isRunning {
            return "Active — \(coordinator.state.label.lowercased())"
        }
        return coordinator.state.label
    }
}
