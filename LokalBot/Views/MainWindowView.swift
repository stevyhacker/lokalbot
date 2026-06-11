import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Label("Meetings", systemImage: "waveform.circle").tag(AppState.NavSection.meetings)
                Label("Timeline", systemImage: "calendar.day.timeline.left").tag(AppState.NavSection.timeline)
                Label("Search", systemImage: "magnifyingglass").tag(AppState.NavSection.search)
                Label("Settings", systemImage: "gearshape").tag(AppState.NavSection.settings)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } content: {
            switch app.navSection {
            case .meetings: meetingList
            case .timeline: TimelineView()
            case .search: SearchView().navigationTitle("Search")
            case .settings:
                SettingsView()
                    .navigationSplitViewColumnWidth(min: 470, ideal: 560)
            }
        } detail: {
            if app.navSection == .settings {
                // Settings selected → the detail pane shows live permission
                // status (same panel as onboarding).
                ScrollView { OnboardingView() }
            } else if let meeting = app.meetings.first(where: { $0.id == app.selectedMeetingID }) {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
            } else {
                ContentUnavailableView(
                    "No meeting selected",
                    systemImage: "waveform.circle",
                    description: Text("Recordings appear here automatically and are transcribed & summarized after the meeting ends."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.isRecording
                        ? app.stopRecording()
                        : app.startRecording(detectedApp: app.detector.activeApp)
                } label: {
                    Label(app.isRecording ? "Stop recording" : "Record now",
                          systemImage: app.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(app.isRecording ? .red : nil)
            }
        }
        .task {
            // Auto-open once, ever. After that it lives behind
            // menu bar → "Permissions…" and never nags.
            let key = "lokalbot.onboarding.shown"
            if !OnboardingView.allGranted && !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                openWindow(id: "onboarding")
            }
        }
    }

    private var sidebarSelection: Binding<AppState.NavSection?> {
        Binding(get: { app.navSection }, set: { app.navSection = $0 ?? .meetings })
    }

    private var meetingList: some View {
        List(selection: $app.selectedMeetingID) {
            Section("Library") {
                ForEach(app.meetings) { meeting in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title).font(.system(size: 13.5, weight: .semibold))
                        Text("\(meeting.appName) · \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(meeting.durationLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(meeting.id)
                }
            }
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
            Text(meeting.title).font(.title2.bold())
            HStack(spacing: 8) {
                badge("📅 \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))")
                badge("⏱ \(meeting.durationLabel)")
                badge("🎥 \(meeting.appName)")
                badge(meeting.hasSystemTrack ? "🎚 mic + system" : "🎙 mic only")
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                Menu("Process") {
                    Button("Transcribe & summarize") { app.reprocess(meeting, transcribe: true, summarize: true) }
                    Button("Transcribe only") { app.reprocess(meeting, transcribe: true, summarize: false) }
                    Button("Re-summarize (keep transcript)") { app.reprocess(meeting, transcribe: false, summarize: true) }
                }
                .fixedSize()
            }

            if player.isLoaded { playerBar }
            statusRow

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

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
        if let transcript, !transcript.segments.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
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
            Text(segment.text).font(.system(size: 13))
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

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption)
            .padding(.horizontal, 9).padding(.vertical, 3)
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
