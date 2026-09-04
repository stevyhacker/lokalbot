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
    /// Mirrors the current split controller for the app-owned toolbar label.
    /// AppKit owns the actual collapse animation through the responder chain.
    @SceneStorage("workspace.sidebar.visible") private var sidebarVisible = true
    @SceneStorage("workspace.meetings.width") private var meetingColumnWidth = 300.0
    @SceneStorage("workspace.conversations.width") private var conversationColumnWidth = 250.0
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
            if app.navSection == .timeline, app.evidenceReturnSection != nil {
                ToolbarItem(placement: .navigation) {
                    Button(action: app.returnFromEvidence) {
                        Label("Back", systemImage: "chevron.left")
                    }.help("Return to the source search or conversation")
                }
            }
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
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.34), in: Circle())
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.08)) }
                .contentShape(Circle())
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
    private var navigation: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly })) {
            sidebar
        } detail: {
            workspace
                .workspaceSurface()
                .safeAreaInset(edge: .bottom) {
                    if !app.outcomeIndex.statusUndo.isEmpty {
                        HStack {
                            Text("Updated \(app.outcomeIndex.statusUndo.count) action(s)")
                            Button("Undo") { app.outcomeIndex.undoStatusChange() }
                                .accessibilityIdentifier("outcomes.undo")
                            Spacer()
                            Button("Dismiss") { app.outcomeIndex.dismissUndo() }
                        }
                        .font(WorkspaceTypography.control)
                        .padding(12).background(.bar)
                    }
                }
        }
    }

    @ViewBuilder private var workspace: some View {
        switch app.navSection {
        case .today:
            if app.showingActions { ActionsWorkspaceView() } else { TodayView() }
        case .timeline:
            TimelineContentView(model: capture)
        case .meetings:
            HSplitView {
                MeetingListView(pendingDelete: $pendingDelete)
                    .frame(minWidth: 240, idealWidth: meetingColumnWidth, maxWidth: 440)
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { meetingColumnWidth = $0 }
                MeetingLibraryDetailView(pendingDelete: $pendingDelete)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        case .type:
            TypeView()
        case .ask:
            HSplitView {
                if app.askMode == .ask {
                    ChatConversationList()
                        .frame(minWidth: 200, idealWidth: conversationColumnWidth, maxWidth: 340)
                        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { conversationColumnWidth = $0 }
                }
                AskView().frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        case .agent:
            AgentView(sessions: app.agentSessions, installer: app.agentInstaller)
        case .settings:
            SettingsView()
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            sidebarDestination(
                "Today", systemImage: "sun.max", section: .today,
                identifier: "sidebar.today")
            Section {
                sidebarDestination(
                    "Meetings", systemImage: "waveform.circle", section: .meetings,
                    identifier: "sidebar.meetings")
                sidebarDestination(
                    "Timeline",
                    systemImage: "calendar.day.timeline.left",
                    section: .timeline,
                    identifier: "sidebar.timeline")
                sidebarDestination(
                    "Ask", systemImage: "sparkle.magnifyingglass", section: .ask,
                    identifier: "sidebar.ask")
            } header: {
                sidebarSectionHeader("Remember")
            }
            Section {
                sidebarDestination(
                    "Write", systemImage: "keyboard", section: .type,
                    identifier: "sidebar.type")
                sidebarDestination(
                    "Agent", systemImage: "wand.and.sparkles", section: .agent,
                    identifier: "sidebar.agent")
            } header: {
                sidebarSectionHeader("Tools")
            }
            sidebarDestination(
                "Settings", systemImage: "gearshape", section: .settings,
                identifier: "sidebar.settings")
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
        // Keep the sidebar attached to the window edge even if macOS restores
        // or accepts a wider split column. Capping this child at 190 points
        // centers it inside the oversized column and creates blank gutters.
        .frame(minWidth: 167, idealWidth: 167, maxWidth: .infinity, alignment: .leading)
        .navigationSplitViewColumnWidth(min: 167, ideal: 167, max: 190)
        // The system toggle is only removable from the sidebar column's own
        // content — applied outside the NavigationSplitView the removal is a
        // no-op and the generated toggle duplicates the owned one in the
        // window toolbar.
        .toolbar(removing: .sidebarToggle)
    }

    /// Native source-list selection gives VoiceOver and keyboard navigation
    /// one semantic destination per row. Section headings remain static text.
    private var sidebarSelection: Binding<AppState.NavSection?> {
        Binding(
            get: { app.navSection },
            set: { selection in
                if let selection {
                    if selection == .today { app.showingActions = false }
                    app.evidenceReturnSection = nil
                    app.navSection = selection
                }
            })
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
        sidebarLabel(title, systemImage: systemImage, section: section)
        .tag(section)
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
        .padding(.top, section == .ask || section == .settings ? 13 : 0)
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
            .accessibilityAddTraits(.isHeader)
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

    private var destination: InferencePresentation { InferencePresentation(settings: app.settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusDot(color: destination == .onDevice ? Brand.teal : Brand.amber, size: 7)
                Text("Memory stored on this Mac")
                    .font(WorkspaceTypography.editorialBodyEmphasis)
                    .foregroundStyle(.primary)
            }
            Text(destination.label)
                .workspaceTextRole(.supporting)
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
                .clipShape(RoundedRectangle(
                    cornerRadius: Brand.Radius.row, style: .continuous))

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
