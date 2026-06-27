import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var pendingDelete: Set<Meeting.ID>?

    private enum ThreeColumnSection {
        case meetings, search

        init?(_ section: AppState.NavSection) {
            switch section {
            case .meetings: self = .meetings
            case .search: self = .search
            case .settings: return nil
            case .timeline: return nil
            case .cotyping: return nil
            case .chat: return nil
            case .models: return nil
            }
        }
    }

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
        .toolbar {
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
            if let error = app.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).lineLimit(2)
                    Button { app.lastError = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.4)))
                .padding(12)
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

    /// Timeline gets the full main area (sidebar + detail, two columns); every
    /// other section keeps the three-column master/detail split.
    @ViewBuilder private var navigation: some View {
        if app.navSection == .timeline {
            NavigationSplitView {
                sidebar
            } detail: {
                TimelineView()
            }
        } else if app.navSection == .cotyping {
            NavigationSplitView {
                sidebar
            } detail: {
                CotypingView()
            }
        } else if app.navSection == .chat {
            NavigationSplitView {
                sidebar
            } content: {
                ChatConversationList()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                ChatView()
            }
        } else if app.navSection == .models {
            NavigationSplitView {
                sidebar
            } detail: {
                ModelsView()
            }
        } else if app.navSection == .settings {
            NavigationSplitView {
                sidebar
            } detail: {
                SettingsAndPermissionsView()
            }
        } else {
            NavigationSplitView {
                sidebar
            } content: {
                if let section = ThreeColumnSection(app.navSection) {
                    contentPane(for: section)
                }
            } detail: {
                detailPane
            }
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Library") {
                Label("Meetings", systemImage: "waveform.circle")
                    .tag(AppState.NavSection.meetings)
                    .accessibilityIdentifier("sidebar.meetings")
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .tag(AppState.NavSection.chat)
                    .accessibilityIdentifier("sidebar.chat")
                Label("Timeline", systemImage: "calendar.day.timeline.left")
                    .tag(AppState.NavSection.timeline)
                    .accessibilityIdentifier("sidebar.timeline")
                Label("Search", systemImage: "magnifyingglass")
                    .tag(AppState.NavSection.search)
                    .accessibilityIdentifier("sidebar.search")
            }
            Section("Automation") {
                Label("Cotyping", systemImage: "text.cursor")
                    .tag(AppState.NavSection.cotyping)
                    .accessibilityIdentifier("sidebar.cotyping")
            }
            Section("Configure") {
                Label("Models", systemImage: "brain")
                    .tag(AppState.NavSection.models)
                    .accessibilityIdentifier("sidebar.models")
                Label("Settings", systemImage: "gearshape")
                    .tag(AppState.NavSection.settings)
                    .accessibilityIdentifier("sidebar.settings")
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }

    @ViewBuilder private func contentPane(for section: ThreeColumnSection) -> some View {
        switch section {
        case .meetings: meetingList
        case .search: SearchView().navigationTitle("Search")
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let meeting = app.selectedMeeting {
            MeetingDetailView(meeting: meeting)
                .id(meeting.id)
        } else if app.selectedMeetingIDs.count > 1 {
            ContentUnavailableView {
                Label("\(app.selectedMeetingIDs.count) meetings selected", systemImage: "checklist")
            } description: {
                Text("Press ⌫ or right-click to delete them.")
            } actions: {
                Button("Delete \(app.selectedMeetingIDs.count) meetings", role: .destructive) {
                    pendingDelete = app.selectedMeetingIDs
                }
            }
        } else {
            GettingStartedCard()
        }
    }

    private var sidebarSelection: Binding<AppState.NavSection?> {
        Binding(get: { app.navSection }, set: { app.navSection = $0 ?? .meetings })
    }

    /// Live recording first, then finished meetings, grouped by day.
    private var groupedMeetings: [(label: String, items: [Meeting])] {
        let calendar = Calendar.current
        let all = (app.currentMeeting.map { [$0] } ?? []) + app.meetings
        let groups = Dictionary(grouping: all) { calendar.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { day in
            (Self.dayLabel(day), groups[day]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    private static func dayLabel(_ day: Date) -> String {
        let datePart = day.formatted(.dateTime.month(.abbreviated).day()).uppercased()
        if Calendar.current.isDateInToday(day) { return "TODAY — \(datePart)" }
        if Calendar.current.isDateInYesterday(day) { return "YESTERDAY — \(datePart)" }
        return "\(day.formatted(.dateTime.weekday(.wide)).uppercased()) — \(datePart)"
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        let live = meeting.endedAt == nil
        let time = live ? "in progress"
                        : meeting.startedAt.formatted(date: .omitted, time: .shortened)
        let duration = live ? "\(max(1, Int(Date().timeIntervalSince(meeting.startedAt) / 60))) min"
                            : meeting.durationLabel
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if live { Circle().fill(.red).frame(width: 9, height: 9) }
                Text(meeting.title).font(.headline)
            }
            Text("\(meeting.appName) · \(time) · \(duration)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meeting.title)
        .accessibilityIdentifier("meeting.row.\(meeting.id.uuidString)")
    }

    private var meetingList: some View {
        List(selection: $app.selectedMeetingIDs) {
            ForEach(groupedMeetings, id: \.label) { group in
                Section {
                    ForEach(group.items) { meeting in
                        meetingRow(meeting).tag(meeting.id)
                    }
                } header: {
                    Text(group.label).font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("meeting.list")
        .overlay(alignment: .topTrailing) {
            if app.isRecording {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("recording…").font(.caption)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.background.opacity(0.9), in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .padding(10)
            }
        }
        .contextMenu(forSelectionType: Meeting.ID.self) { ids in
            Button("Delete \(ids.count > 1 ? "\(ids.count) meetings" : "meeting")…",
                   role: .destructive) {
                pendingDelete = ids
            }
        }
        .onDeleteCommand {
            if !app.selectedMeetingIDs.isEmpty { pendingDelete = app.selectedMeetingIDs }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .navigationTitle("Meetings")
    }
}

private struct SettingsAndPermissionsView: View {
    var body: some View {
        HSplitView {
            SettingsView()
                .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity)

            ScrollView {
                OnboardingView(mode: .permissions)
                    .padding(.vertical, 12)
            }
            .frame(minWidth: 360, idealWidth: 430, maxWidth: .infinity)
            .accessibilityIdentifier("settings.permissions")
        }
        .navigationTitle("Settings")
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject var app: AppState
    let meeting: Meeting

    private enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .summary
    @State private var summary: String?
    @State private var transcript: Transcript?
    @State private var isExportingAudio = false
    @State private var exportError: String?
    @StateObject private var player = MeetingPlayer()

    private var stage: ProcessingPipeline.Stage? { app.pipeline.stages[meeting.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(meeting.title).font(.title2.bold()).accessibilityIdentifier("detail.title")
            HStack(spacing: 6) {
                metaBadge("calendar", meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                metaBadge("clock", meeting.durationLabel)
                metaBadge("video", meeting.appName)
                metaBadge(meeting.hasSystemTrack ? "speaker.wave.2.fill" : "mic.fill",
                          meeting.hasSystemTrack ? "Mic + system" : "Mic only")
            }

            if player.isLoaded { playerBar }
            statusRow

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t).accessibilityIdentifier("detail.tab.\(t.rawValue.lowercased())")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .accessibilityIdentifier("detail.tabs")

            Group {
                switch tab {
                case .summary: summaryTab
                case .transcript: transcriptTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: reloadKey) { loadFiles() }
        .task {
            player.load(folder: folder, hasSystemTrack: meeting.hasSystemTrack)
            consumePendingSeek()
        }
        .onChange(of: app.pendingSeek) { consumePendingSeek() }
        .onDisappear { player.stop() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    exportAudioRecording()
                } label: {
                    Label(isExportingAudio ? "Exporting Audio" : "Export Audio",
                          systemImage: "square.and.arrow.up")
                }
                .disabled(isExportingAudio || !player.isLoaded)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Menu {
                    Button("Transcribe & Summarize") { app.reprocess(meeting, transcribe: true, summarize: true) }
                    Button("Transcribe Only") { app.reprocess(meeting, transcribe: true, summarize: false) }
                    Button("Re-summarize (Keep Transcript)") { app.reprocess(meeting, transcribe: false, summarize: true) }
                } label: {
                    Label("Process", systemImage: "wand.and.stars")
                }
            }
        }
    }

    /// Reload from disk when the meeting changes or the pipeline finishes a stage.
    private var reloadKey: String { "\(meeting.id)-\(String(describing: stage))" }

    /// Search → "jump to audio": switch to the transcript and play from there.
    private func consumePendingSeek() {
        guard let time = app.pendingSeek else { return }
        app.pendingSeek = nil
        tab = .transcript
        player.play(at: time)
    }

    // MARK: Player

    private var playerBar: some View {
        let progress = player.duration > 0 ? player.currentTime / player.duration : 0
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    player.playPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28)).foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (Space)")

                WaveformView(url: folder.appendingPathComponent("mic.m4a"),
                             progress: progress) { p in
                    player.seek(to: p * player.duration)
                }
                .help("Drag to scrub")

                speedMenu
            }
            HStack(spacing: 6) {
                Text(Transcript.stamp(player.currentTime))
                Spacer()
                Text(Transcript.stamp(player.duration))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Playback-speed cycler (1× → 1.25× → 1.5× → 2× → back to 1×). A compact
    /// Menu rather than a stepper so it reads as a label and fits the bar.
    private var speedMenu: some View {
        Menu {
            ForEach([1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                Button {
                    player.speed = Float(rate)
                } label: {
                    if abs(Double(player.speed) - rate) < 0.01 {
                        Label("\(formattedSpeed(rate))×", systemImage: "checkmark")
                    } else {
                        Text("\(formattedSpeed(rate))×")
                    }
                }
            }
            Divider()
            Button("Reset to 1×") { player.speed = 1.0 }
        } label: {
            Text(formattedSpeed(Double(player.speed)) + "×")
                .font(.callout.monospacedDigit())
                .foregroundStyle(player.speed == 1.0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(minWidth: 38)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("player.speed")
    }

    private func formattedSpeed(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(rate)) : String(rate)
    }

    @ViewBuilder private var statusRow: some View {
        if isExportingAudio {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Exporting audio…").font(.callout).foregroundStyle(.secondary)
            }
        }
        if let exportError {
            Label(exportError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        if let stage {
            switch stage {
            case .failed:
                Label(stage.label, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            default:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stage.label).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Tabs

    @ViewBuilder private var summaryTab: some View {
        if let summary {
            ScrollView {
                MarkdownText(summary)
                    .frame(maxWidth: 720, alignment: .leading)
                    .textSelection(.enabled)
            }
        } else {
            ContentUnavailableView(
                "No summary yet",
                systemImage: "text.badge.checkmark",
                description: Text(stage == nil
                    ? "Use Process → Transcribe & summarize. Summaries are written to summary.md."
                    : "Working on it…"))
        }
    }

    @ViewBuilder private var transcriptTab: some View {
        let visibleSegments = transcript?.segments.filter { !$0.displayText.isEmpty } ?? []
        if !visibleSegments.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(visibleSegments.enumerated()), id: \.offset) { _, segment in
                        segmentRow(segment)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "text.bubble",
                description: Text(stage == nil
                    ? "Use Process → Transcribe & summarize. The first run downloads the Parakeet model (~600 MB) from Hugging Face."
                    : "Working on it…"))
        }
    }

    private func segmentRow(_ segment: Transcript.Segment) -> some View {
        let isCurrent = player.isLoaded
            && player.currentTime >= segment.start
            && player.currentTime < max(segment.end, segment.start + 0.5)
        return HStack(alignment: .top, spacing: 10) {
            Text(Transcript.stamp(segment.start))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
            Text(segment.speaker.capitalized)
                .font(.caption.bold())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(segment.speaker == "me" ? Color.accentColor.opacity(0.18)
                                                    : Color.secondary.opacity(0.15),
                            in: Capsule())
            Text(segment.displayText).font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { player.play(at: segment.start) }   // click a sentence → jump audio
    }

    private var folder: URL { meeting.folderURL(in: app.storage) }

    private func loadFiles() {
        summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        transcript = try? app.pipeline.loadTranscript(from: folder)
    }

    private func exportAudioRecording() {
        exportError = nil

        let panel = NSSavePanel()
        panel.title = "Export Audio Recording"
        panel.nameFieldStringValue = "\(StorageManager.slugify(meeting.title))-audio.m4a"
        panel.canCreateDirectories = true
        if let m4a = UTType(filenameExtension: "m4a") {
            panel.allowedContentTypes = [m4a]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExportingAudio = true
        Task {
            defer { isExportingAudio = false }
            do {
                try await MeetingAudioAsset.exportMixedRecording(
                    folder: folder,
                    hasSystemTrack: meeting.hasSystemTrack,
                    to: url
                )
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func metaBadge(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}

/// Minimal line-based Markdown renderer — headings, bullets, checkboxes,
/// ordered lists, blockquotes, and horizontal rules, with inline
/// bold/italic/code via AttributedString. Enough for summary.md.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                render(line)
            }
        }
    }

    @ViewBuilder private func render(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            Divider().padding(.vertical, 4)
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4))).font(.headline).padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3))).font(.title3.bold()).padding(.top, 8)
        } else if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2))).font(.title2.bold())
        } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: trimmed.hasPrefix("- [x]") ? "checkmark.square" : "square")
                    .font(.system(size: 12)).padding(.top, 2)
                inline(String(trimmed.dropFirst(6)))
            }
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                inline(String(trimmed.dropFirst(2)))
            }
        } else if let ordered = Self.orderedListItem(trimmed) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(ordered.number).").font(.body.monospacedDigit())
                inline(ordered.rest)
            }
        } else if trimmed.hasPrefix("> ") {
            HStack(alignment: .top, spacing: 8) {
                // A thin accent rule reads as a quote bar without a custom shape.
                Rectangle().fill(.tint.opacity(0.6)).frame(width: 2)
                inline(String(trimmed.dropFirst(2)))
                    .italic().foregroundStyle(.secondary)
            }
        } else {
            inline(trimmed)
        }
    }

    /// Matches "1. text", "12. text" — returns the number and the remainder.
    private static func orderedListItem(_ trimmed: String) -> (number: Int, rest: String)? {
        guard let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber),
              let number = Int(trimmed[..<dot]),
              trimmed.index(after: dot) < trimmed.endIndex,
              trimmed[trimmed.index(after: dot)] == " " else { return nil }
        let rest = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
        return (number, rest)
    }

    private func inline(_ s: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(s)
        }
    }
}

/// The empty-state card shown when no meeting is selected. Orients across the
/// three pillars (record → recap → search/ask) and a couple of one-tap setup
/// steps, so a brand-new user lands somewhere useful instead of a blank pane.
/// Dismissed once and remembered via `@AppStorage`.
struct GettingStartedCard: View {
    @EnvironmentObject var app: AppState
    @AppStorage("lokalbotv3.gettingStartedDismissed") private var dismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Brand.gradient)
                            .frame(width: 48, height: 48)
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 22)).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome to LokalBot").font(.title2.bold())
                        Text("Record meetings, get the recap, and search everything — all on-device.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { dismissed = true } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityIdentifier("welcome.dismiss")
                }

                HStack(spacing: 12) {
                    pillar("waveform", "Record",
                           app.isRecording ? "Recording now…" : "LokalBot auto-detects meetings, or start one here.",
                           isRecording: app.isRecording)
                    pillar("doc.text.magnifyingglass", "Recap",
                           "A transcript and structured summary land the moment a call ends.", isRecording: nil)
                    pillar("magnifyingglass", "Search & ask",
                           "Full-text, meaning, and screen-text search — plus chat over your library.", isRecording: nil)
                }

                Text("Get started").font(.headline)
                VStack(alignment: .leading, spacing: 10) {
                    stepRow(done: app.isRecording || !app.meetings.isEmpty) {
                        Text("Record a meeting — it appears in the list automatically.")
                    }
                    stepRow(done: nil) {
                        HStack(spacing: 8) {
                            Button("Turn on day tracking") { app.navSection = .timeline }
                                .buttonStyle(.bordered).controlSize(.small)
                            Text("to see where your time goes.")
                        }
                    }
                    stepRow(done: app.settings.cotypingEnabled ? true : nil) {
                        HStack(spacing: 8) {
                            Button("Try cotyping") { app.navSection = .cotyping }
                                .buttonStyle(.bordered).controlSize(.small)
                            Text("— inline AI autocomplete that stays on your Mac.")
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))

                Text("Tip: press ⌘K anywhere to record, navigate, or jump to a meeting.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func pillar(_ icon: String, _ title: String, _ body: String,
                        isRecording: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(isRecording == true ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.tint))
            Text(title).font(.headline)
            Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    /// `done`: nil = actionable (hollow circle), true/false = checkmark/number.
    private func stepRow<S: View>(done: Bool?, @ViewBuilder _ content: () -> S) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done == true ? Color.green : Brand.teal)
                .padding(.top, 2)
            content().font(.callout)
        }
    }
}
