import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var pendingDelete: Set<Meeting.ID>?

    private enum ThreeColumnSection {
        case meetings, search, settings

        init?(_ section: AppState.NavSection) {
            switch section {
            case .meetings: self = .meetings
            case .search: self = .search
            case .settings: self = .settings
            case .timeline: return nil
            case .cotyping: return nil
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
            Label("Meetings", systemImage: "waveform.circle")
                .tag(AppState.NavSection.meetings)
                .accessibilityIdentifier("sidebar.meetings")
            Label("Timeline", systemImage: "calendar.day.timeline.left")
                .tag(AppState.NavSection.timeline)
                .accessibilityIdentifier("sidebar.timeline")
            Label("Cotyping", systemImage: "text.cursor")
                .tag(AppState.NavSection.cotyping)
                .accessibilityIdentifier("sidebar.cotyping")
            Label("Search", systemImage: "magnifyingglass")
                .tag(AppState.NavSection.search)
                .accessibilityIdentifier("sidebar.search")
            Label("Settings", systemImage: "gearshape")
                .tag(AppState.NavSection.settings)
                .accessibilityIdentifier("sidebar.settings")
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }

    @ViewBuilder private func contentPane(for section: ThreeColumnSection) -> some View {
        switch section {
        case .meetings: meetingList
        case .search: SearchView().navigationTitle("Search")
        case .settings:
            SettingsView()
                .navigationSplitViewColumnWidth(min: 470, ideal: 560)
        }
    }

    @ViewBuilder private var detailPane: some View {
        if app.navSection == .settings {
            // Settings selected → the detail pane shows live permission
            // status (same panel as onboarding).
            ScrollView { OnboardingView() }
        } else if let meeting = app.selectedMeeting {
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
            ContentUnavailableView(
                "No meeting selected",
                systemImage: "waveform.circle",
                description: Text("Recordings appear here automatically and are transcribed & summarized after the meeting ends."))
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
        HStack(spacing: 12) {
            Button {
                player.playPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)

            Text(Transcript.stamp(player.currentTime))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.currentTime },
                                  set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 1))
            Text(Transcript.stamp(player.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var statusRow: some View {
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
/// and inline bold/italic/code via AttributedString. Enough for summary.md.
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
        } else {
            inline(trimmed)
        }
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
