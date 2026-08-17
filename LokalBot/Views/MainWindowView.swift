import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Lets the screenshot script cap the middle column so the inspector keeps a
/// useful share of wide marketing captures. Production launches never set it.
private struct ScriptedCaptureContentWidth: ViewModifier {
    let maximum: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let maximum {
            content.navigationSplitViewColumnWidth(
                min: 300, ideal: min(380, maximum), max: maximum)
        } else {
            content.navigationSplitViewColumnWidth(min: 300, ideal: 380)
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    /// One window-scoped source of truth shared by every split-view topology.
    /// Without this, each section's NavigationSplitView owns a separate hidden
    /// state and the system sidebar toggle becomes unreliable after navigation.
    @SceneStorage("mainWindow.sidebarVisible") private var sidebarVisible = true
    @State private var pendingDelete: Set<Meeting.ID>?
    /// Shared by Timeline's chronology and bounded context panel.
    @StateObject private var capture = CaptureModel()

    var body: some View {
        navigation
        .confirmationDialog(
            "Delete \(pendingDelete?.count ?? 0) meeting\((pendingDelete?.count ?? 0) == 1 ? "" : "s")?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete (removes recordings & transcripts)", role: .destructive) {
                if let ids = pendingDelete { app.deleteMeetings(ids) }
                pendingDelete = nil
            }
        } message: {
            Text("This permanently deletes the audio, transcript and summary files.")
        }
        // NavigationSplitView's generated sidebar item can drift away from the
        // explicit `sidebarVisible` binding when this view swaps between its
        // two- and three-column topologies. Own the command so the toolbar,
        // keyboard shortcut, and split-view state always use one source of
        // truth. (The generated item itself is removed inside `sidebar` —
        // the only attachment point where SwiftUI honors the removal.)
        .toolbar {
            sidebarToolbarItem
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.isRecording
                        ? app.stopRecording()
                        : app.startRecording(context: app.recordingContext(for: app.detector.activeApp))
                } label: {
                    Label(app.isRecording ? "Stop recording" : "Record now",
                          systemImage: app.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(app.isRecording ? .red : nil)
                .accessibilityIdentifier("toolbar.record")
            }
        }
        .overlay(alignment: .bottom) {
            if app.micRecoveryNeeded {
                ErrorToast(
                    message: "Microphone access is off for LokalBot. Turn it on in System Settings to record.",
                    actionTitle: "Open System Settings",
                    action: {
                        PermissionManager.shared.openSettings(for: .microphone)
                        app.micRecoveryNeeded = false
                    }) { app.micRecoveryNeeded = false }
            } else if let error = app.lastError {
                ErrorToast(message: error) { app.lastError = nil }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if !app.isRecording, let process = app.audioMonitor.detectedProcess {
                    AudioSourceBanner(process: process,
                                      onRecord: {
                                          let detected = MeetingDetector.DetectedApp(
                                              name: process.name,
                                              bundleID: process.bundleID ?? "",
                                              pid: process.id)
                                          app.audioMonitor.accept()
                                          app.startRecording(context: app.recordingContext(for: detected), source: "banner")
                                      },
                                      onDismiss: { app.audioMonitor.dismiss() })
                }
            }
            .padding(12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .task {
            // Let non-View code (menu bar, AppDelegate reopen) open windows.
            // First-run permission onboarding is now triggered from AppState.
            WindowAccess.shared.register { openWindow(id: $0) }
        }
    }

    /// macOS 26 automatically groups navigation items into a Liquid Glass
    /// capsule. The approved reference uses a quiet standalone control, so
    /// hide only that shared background while retaining the native toolbar.
    @ToolbarContentBuilder
    private var sidebarToolbarItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                sidebarToggleButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                sidebarToggleButton
            }
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            sidebarVisible.toggle()
        } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: 86, height: 1)
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.34), in: Circle())
                    .overlay { Circle().strokeBorder(Color.primary.opacity(0.08)) }
            }
            .padding(.trailing, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .keyboardShortcut("s", modifiers: [.command, .control])
        .accessibilityIdentifier("toolbar.sidebarToggle")
    }

    /// Timeline is one day-explorer workspace inside the global shell. Its
    /// chronology/context split belongs to that workspace, rather than
    /// becoming two more global navigation columns. Meetings and Ask retain
    /// their native three-column information architecture.
    @ViewBuilder private var navigation: some View {
        if app.navSection == .today {
            NavigationSplitView(columnVisibility: twoColumnVisibility) {
                sidebar
            } detail: {
                TodayView()
                    .workspaceSurface()
            }
        } else if app.navSection == .timeline {
            NavigationSplitView(columnVisibility: twoColumnVisibility) {
                sidebar
            } detail: {
                TimelineContentView(model: capture)
                    .workspaceSurface()
            }
        } else if app.navSection == .meetings {
            NavigationSplitView(columnVisibility: threeColumnVisibility) {
                sidebar
            } content: {
                MeetingListView(pendingDelete: $pendingDelete)
                    .navigationTitle("Meetings")
                    .modifier(ScriptedCaptureContentWidth(
                        maximum: scriptedCaptureContentMaximum))
            } detail: {
                MeetingLibraryDetailView(pendingDelete: $pendingDelete)
                    .workspaceSurface()
            }
        } else if app.navSection == .type {
            NavigationSplitView(columnVisibility: twoColumnVisibility) {
                sidebar
            } detail: {
                TypeView()
                    .workspaceSurface()
            }
        } else if app.navSection == .ask {
            NavigationSplitView(columnVisibility: threeColumnVisibility) {
                sidebar
            } content: {
                ChatConversationList()
                    .frame(minWidth: 250, idealWidth: 250, maxWidth: 280)
                    .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 280)
            } detail: {
                AskView()
                    .frame(minWidth: 420)
                    .workspaceSurface()
                    .navigationSplitViewColumnWidth(min: 420, ideal: 680)
            }
        } else if app.navSection == .agent {
            NavigationSplitView(columnVisibility: twoColumnVisibility) {
                sidebar
            } detail: {
                AgentView(sessions: app.agentSessions, installer: app.agentInstaller)
                    .workspaceSurface()
            }
        } else {
            NavigationSplitView(columnVisibility: twoColumnVisibility) {
                sidebar
            } detail: {
                SettingsView()
                    .workspaceSurface()
            }
        }
    }

    /// A hidden three-column sidebar leaves content + detail visible.
    private var threeColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .doubleColumn },
            set: { visibility in
                guard visibility != .automatic else { return }
                sidebarVisible = visibility == .all
            })
    }

    /// A hidden two-column sidebar leaves only its detail surface visible.
    private var twoColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { visibility in
                guard visibility != .automatic else { return }
                sidebarVisible = visibility != .detailOnly
            })
    }

    private var sidebar: some View {
        List {
            Section {
                sidebarDestination(
                    "Today", systemImage: "sun.max", section: .today,
                    identifier: "sidebar.today")
            }
            Section {
                sidebarDestination(
                    "Timeline",
                    systemImage: "calendar.day.timeline.left",
                    section: .timeline,
                    identifier: "sidebar.timeline")
                sidebarDestination(
                    "Meetings", systemImage: "waveform.circle", section: .meetings,
                    identifier: "sidebar.meetings")
                sidebarDestination(
                    "Ask", systemImage: "sparkle.magnifyingglass", section: .ask,
                    identifier: "sidebar.ask")
            } header: {
                sidebarSectionHeader("Remember")
            }
            Section {
                sidebarDestination(
                    "Type", systemImage: "keyboard", section: .type,
                    identifier: "sidebar.type")
                sidebarDestination(
                    "Agent", systemImage: "wand.and.sparkles", section: .agent,
                    identifier: "sidebar.agent")
            } header: {
                sidebarSectionHeader("Write & act")
            }
            Section {
                sidebarDestination(
                    "Settings", systemImage: "gearshape", section: .settings,
                    identifier: "sidebar.settings")
            }
        }
        .listStyle(.sidebar)
        .tint(Brand.teal)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarBrandHeader()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarPrivacyFooter()
        }
        .scrollContentBackground(.hidden)
        .background(WorkspacePalette.sidebar(for: colorScheme))
        // 167 points is the measured first-column width in the approved Ask
        // reference. An explicit frame is needed because macOS otherwise
        // compresses a List sidebar below its column-width preference.
        .frame(minWidth: 167, idealWidth: 167, maxWidth: 190)
        .navigationSplitViewColumnWidth(min: 167, ideal: 167, max: 190)
        // The system toggle is only removable from the sidebar column's own
        // content — applied outside the NavigationSplitView the removal is a
        // no-op and the generated toggle duplicates the owned one in the
        // window toolbar.
        .toolbar(removing: .sidebarToggle)
    }

    /// `cacheDisplay` does not flatten the sidebar's vibrancy text correctly:
    /// AppKit gives the offscreen bitmap the mask color (black) instead of the
    /// composited label color. Use resolved colors only for scripted exports;
    /// normal app and UI-test windows keep the native sidebar rendering.
    @ViewBuilder
    private func sidebarDestination(
        _ title: String,
        systemImage: String,
        section: AppState.NavSection,
        identifier: String
    ) -> some View {
        let selected = app.navSection == section
        Button {
            app.navSection = section
        } label: {
            sidebarLabel(title, systemImage: systemImage, section: section)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: -5))
        .listRowBackground(Color.clear)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func sidebarLabel(
        _ title: String,
        systemImage: String,
        section: AppState.NavSection
    ) -> some View {
        let selected = app.navSection == section

        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    selected
                        ? Brand.teal
                        : (isScriptedCapture ? scriptedSidebarHeaderColor : Color.secondary))
                .frame(width: 18)

            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(
                    selected
                        ? Brand.teal
                        : (isScriptedCapture ? scriptedSidebarLabelColor : Color.primary))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            selected ? Brand.teal.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .padding(.top, section == .ask ? 13 : 0)
        .offset(y: section == .today ? -2 : 0)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(isScriptedCapture ? scriptedSidebarHeaderColor : Color.secondary)
            .padding(.leading, 11)
            .padding(.top, title == "Remember" ? 3 : 8)
            .padding(.bottom, title == "Remember" ? 10 : 5)
            .accessibilityIdentifier(
                title == "Remember" ? "sidebar.section.remember" : "sidebar.section.writeAct")
    }

    private var scriptedSidebarLabelColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.90) : Color.black.opacity(0.84)
    }

    private var scriptedSidebarHeaderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.56) : Color.black.opacity(0.50)
    }

    private var isScriptedCapture: Bool {
#if LOKALBOT_UI_TEST_HOST
        ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_FILE"] != nil
#else
        false
#endif
    }

    private var scriptedCaptureContentMaximum: CGFloat? {
#if LOKALBOT_UI_TEST_HOST
        guard let raw = ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_CONTENT_MAX"],
              let value = Double(raw), value >= 300 else { return nil }
        return CGFloat(value)
#else
        return nil
#endif
    }

}

/// Reflects the *actual* privacy posture instead of a hardcoded claim: with a
/// remote Think backend configured, "No data leaves your Mac" would be false —
/// meeting and workday text goes to the approved origin.
private struct SidebarPrivacyFooter: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var remoteThink: Bool { app.settings.usesRemoteMainLLM }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusDot(color: remoteThink ? Brand.amber : .green, size: 7)
                Text(remoteThink ? "Memory is stored locally" : "All memory is local")
                    .font(.system(size: 11, weight: .medium))
            }
            Text(remoteThink ? "Think uses an approved remote server" : "No data leaves your Mac")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 22)
        .background(WorkspacePalette.sidebar(for: colorScheme))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.localPrivacy")
    }
}

private struct SidebarBrandHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("LokalBot")
                    .font(.system(size: 14, weight: .semibold))
                Text("Private work\nmemory")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 17)
        .background(WorkspacePalette.sidebar(for: colorScheme))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}
