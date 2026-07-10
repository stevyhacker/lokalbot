import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var pendingDelete: Set<Meeting.ID>?
    /// Shared by the Capture section's two columns (content ↔ detail).
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
        .toolbar {
            ToolbarItem {
                Button {
                    openWindow(id: "palette")
                } label: {
                    Label("Commands", systemImage: "command")
                }
                .help("Command palette (⌘K)")
                .accessibilityIdentifier("toolbar.palette")
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
        .background(WindowToolbarStyle())
        .overlay(alignment: .bottom) {
            if let error = app.lastError {
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

    /// Master/detail sections (Timeline, Meetings, Ask) use the native
    /// three-column split; single-surface sections (forms) use two.
    @ViewBuilder private var navigation: some View {
        if app.navSection == .timeline {
            NavigationSplitView {
                sidebar
            } content: {
                TimelineContentView(model: capture)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            } detail: {
                CaptureDetailView(model: capture, pendingDelete: $pendingDelete)
            }
        } else if app.navSection == .meetings {
            NavigationSplitView {
                sidebar
            } content: {
                MeetingListView(pendingDelete: $pendingDelete)
                    .navigationTitle("Meetings")
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            } detail: {
                CaptureDetailView(model: capture, pendingDelete: $pendingDelete)
            }
        } else if app.navSection == .type {
            NavigationSplitView {
                sidebar
            } detail: {
                TypeView()
            }
        } else if app.navSection == .ask {
            NavigationSplitView {
                sidebar
            } content: {
                ChatConversationList()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                AskView()
            }
        } else if app.navSection == .agent {
            NavigationSplitView {
                sidebar
            } detail: {
                AgentView(sessions: app.agentSessions, installer: app.agentInstaller)
            }
        } else {
            NavigationSplitView {
                sidebar
            } detail: {
                SettingsView()
            }
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Library") {
                Label("Timeline", systemImage: "calendar.day.timeline.left")
                    .tag(AppState.NavSection.timeline)
                    .accessibilityIdentifier("sidebar.timeline")
                Label("Meetings", systemImage: "waveform.circle")
                    .tag(AppState.NavSection.meetings)
                    .accessibilityIdentifier("sidebar.meetings")
                Label("Ask", systemImage: "sparkle.magnifyingglass")
                    .tag(AppState.NavSection.ask)
                    .accessibilityIdentifier("sidebar.ask")
            }
            Section("Automation") {
                Label("Type", systemImage: "keyboard")
                    .tag(AppState.NavSection.type)
                    .accessibilityIdentifier("sidebar.type")
                Label("Agent", systemImage: "wand.and.sparkles")
                    .tag(AppState.NavSection.agent)
                    .accessibilityIdentifier("sidebar.agent")
            }
            Section("Configure") {
                Label("Settings", systemImage: "gearshape")
                    .tag(AppState.NavSection.settings)
                    .accessibilityIdentifier("sidebar.settings")
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }

    private var sidebarSelection: Binding<AppState.NavSection?> {
        Binding(get: { app.navSection }, set: { app.navSection = $0 ?? .timeline })
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
    @State private var notes: String?
    @State private var outcomes: MeetingOutcomes?
    @State private var transcript: Transcript?
    @State private var transcriptDisplay = Transcript.DisplayIndex()
    @State private var speakerNameHints: [String] = []
    @State private var speakerRenameDraft: SpeakerRenameDraft?
    @State private var isExportingAudio = false
    @State private var isPreparingSpeech = false
    @State private var isReadingSummarySpeech = false
    @State private var isExportingSpeech = false
    @State private var exportError: String?
    @State private var speechError: String?
    @State private var transcriptError: String?
    @State private var speechPlayer: AVAudioPlayer?
    @State private var speechTask: Task<Void, Never>?
    @State private var speechSessionID: UUID?
    @StateObject private var player = MeetingPlayer()

    private var stage: ProcessingPipeline.Stage? { app.pipeline.stages[meeting.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(meeting.title).font(.title2.bold()).accessibilityIdentifier("detail.title")
            HStack(spacing: 6) {
                BrandChip(icon: "calendar", text: meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                BrandChip(icon: "clock", text: meeting.durationLabel)
                BrandChip(icon: "video", text: meeting.appName)
                BrandChip(icon: meeting.hasSystemTrack ? "speaker.wave.2.fill" : "mic.fill",
                          text: meeting.hasSystemTrack ? "Mic + system" : "Mic only")
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
        .sheet(item: $speakerRenameDraft) { draft in
            SpeakerRenameSheet(
                draft: draft,
                hints: speakerNameHints,
                onSave: { saveSpeakerAlias($0, for: draft.speaker) },
                onReset: { saveSpeakerAlias(nil, for: draft.speaker) },
                onCancel: { speakerRenameDraft = nil })
        }
#if LOKALBOT_UI_TEST_HOST
        .onAppear {
            if let raw = ProcessInfo.processInfo.environment["LOKALBOT_DETAIL_TAB"],
               let t = Tab(rawValue: raw.capitalized) {
                tab = t
            }
        }
#endif
        .onDisappear {
            player.stop()
            stopSpokenSummary(clearError: false)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    toggleSummarySpeech()
                } label: {
                    Label(summarySpeechButtonTitle,
                          systemImage: isReadingSummarySpeech ? "stop.fill" : "speaker.wave.2")
                }
                .disabled(!isReadingSummarySpeech && spokenSummaryText == nil)
                Button {
                    exportSpokenSummary()
                } label: {
                    Label(isExportingSpeech ? "Exporting Speech" : "Export Spoken Summary",
                          systemImage: "waveform")
                }
                .disabled(isExportingSpeech || spokenSummaryText == nil)
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
        if isPreparingSpeech || isExportingSpeech {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(isExportingSpeech ? "Exporting spoken summary…" : "Preparing speech…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        if let exportError {
            Label(exportError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        if let speechError {
            Label(speechError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        if let transcriptError {
            Label(transcriptError, systemImage: "exclamationmark.triangle")
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
        // Notes render even before the summary exists — the user typed them,
        // they shouldn't be hostage to the pipeline.
        if summary != nil || notes != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let notes {
                        notesSection(notes)
                    }
                    if let outcomes {
                        MeetingOutcomesSection(outcomes: outcomes)
                    }
                    if let summary {
                        MarkdownText(summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "No summary yet",
                systemImage: "text.badge.checkmark",
                description: Text(stage == nil
                    ? "Use Process → Transcribe & summarize. Summaries are written to summary.md."
                    : "Working on it…"))
        }
    }

    /// The user's own quick notes from the live panel (notes.md).
    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Your notes", systemImage: "square.and.pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            MarkdownText(notes)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("detail.notes")
    }

    @ViewBuilder private var transcriptTab: some View {
        let visibleSegments = transcriptDisplay.segments
        let activeSegmentIDs = player.isLoaded
            ? transcriptDisplay.activeSegmentIDs(at: player.currentTime)
            : Set<Int>()
        if !visibleSegments.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let engine = transcript?.engine, !engine.isEmpty {
                    transcriptModelBadge(engine)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleSegments) { segment in
                            segmentRow(segment, isCurrent: activeSegmentIDs.contains(segment.id))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "text.bubble",
                description: Text(stage == nil
                    ? "Use Process → Transcribe & summarize. The first run downloads the Parakeet model (~600 MB) from Hugging Face."
                    : "Working on it…"))
        }
    }

    /// Provenance line atop the transcript: the exact model (and backend) that
    /// produced it, read from `transcript.json` — so it reflects the model used
    /// for *this* transcript, not whatever is currently selected in Settings.
    private func transcriptModelBadge(_ engine: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .foregroundStyle(.tint)
            Text("Transcribed with ") + Text(engine).fontWeight(.medium)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 8)
        .accessibilityIdentifier("transcript.model")
    }

    private func segmentRow(_ display: Transcript.DisplaySegment, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Transcript.stamp(display.segment.start))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
            speakerChip(for: display)
            Text(display.text).font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { player.play(at: display.segment.start) }   // click a sentence → jump audio
    }

    private func speakerChip(for display: Transcript.DisplaySegment) -> some View {
        Text(display.speakerLabel)
            .font(.caption.bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(display.speakerKey == "me"
                        ? Color.accentColor.opacity(0.18)
                        : Color.secondary.opacity(0.15),
                        in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { beginRenameSpeaker(display.segment.speaker) }
            .contextMenu {
                Button("Rename Speaker...") { beginRenameSpeaker(display.segment.speaker) }
                if display.hasSpeakerAlias {
                    Button("Reset Speaker Name") {
                        saveSpeakerAlias(nil, for: display.segment.speaker)
                    }
                }
                if !speakerNameHints.isEmpty {
                    Divider()
                    ForEach(speakerNameHints.prefix(8), id: \.self) { hint in
                        Button(hint) { saveSpeakerAlias(hint, for: display.segment.speaker) }
                    }
                }
            }
            .help("Rename speaker")
            .accessibilityIdentifier("speaker.chip.\(display.speakerKey)")
    }

    private var folder: URL { meeting.folderURL(in: app.storage) }

    private var spokenSummaryText: String? {
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        return summary
    }

    private var summarySpeechButtonTitle: String {
        if isPreparingSpeech { return "Stop Preparing Speech" }
        if isReadingSummarySpeech { return "Stop Summary" }
        return "Read Summary"
    }

    private func loadFiles() {
        summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        notes = MeetingNotes.load(from: folder)
        outcomes = MeetingOutcomes.load(from: folder).flatMap { $0.isEmpty ? nil : $0 }
        setTranscript(try? app.pipeline.loadTranscript(from: folder))
        speakerNameHints = app.speakerNameHints(for: meeting)
    }

    private func setTranscript(_ updated: Transcript?) {
        transcript = updated
        transcriptDisplay = Transcript.DisplayIndex(transcript: updated)
    }

    private func beginRenameSpeaker(_ speaker: String) {
        guard let transcript else { return }
        speakerRenameDraft = SpeakerRenameDraft(
            speaker: speaker,
            defaultName: Transcript.defaultSpeakerName(for: speaker),
            currentName: transcript.displaySpeaker(for: speaker))
    }

    private func saveSpeakerAlias(_ alias: String?, for speaker: String) {
        guard var updated = transcript else { return }
        updated.setSpeakerAlias(alias, for: speaker)
        do {
            try app.saveTranscript(updated, for: meeting)
            setTranscript(updated)
            transcriptError = nil
            speakerRenameDraft = nil
        } catch {
            transcriptError = "Could not save speaker name: \(error.localizedDescription)"
        }
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

    private func toggleSummarySpeech() {
        if isReadingSummarySpeech {
            stopSpokenSummary()
        } else {
            readSummaryAloud()
        }
    }

    private func readSummaryAloud() {
        guard let text = spokenSummaryText else { return }
        stopSpokenSummary(clearError: false)
        speechError = nil
        let sessionID = UUID()
        speechSessionID = sessionID
        isPreparingSpeech = true
        isReadingSummarySpeech = true
        speechTask = Task {
            defer { finishSpeechSession(sessionID) }
            do {
                let url = try await synthesizeSpeech(text: text, outputURL: nil)
                try Task.checkCancellation()
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                guard speechSessionID == sessionID else { return }
                speechPlayer = player
                isPreparingSpeech = false
                guard player.play() else {
                    throw NSError(
                        domain: "LokalBot.SpeechPlayback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not start speech playback."])
                }
                try await Task.sleep(
                    nanoseconds: UInt64(max(player.duration, 0.1) * 1_000_000_000))
            } catch is CancellationError {
            } catch {
                if speechSessionID == sessionID {
                    speechError = error.localizedDescription
                }
            }
        }
    }

    private func stopSpokenSummary(clearError: Bool = true) {
        speechSessionID = nil
        speechTask?.cancel()
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        isPreparingSpeech = false
        isReadingSummarySpeech = false
        if clearError {
            speechError = nil
        }
    }

    private func finishSpeechSession(_ sessionID: UUID) {
        guard speechSessionID == sessionID else { return }
        speechSessionID = nil
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        isPreparingSpeech = false
        isReadingSummarySpeech = false
    }

    private func exportSpokenSummary() {
        guard let text = spokenSummaryText else { return }
        speechError = nil

        let panel = NSSavePanel()
        panel.title = "Export Spoken Summary"
        panel.nameFieldStringValue = "\(StorageManager.slugify(meeting.title))-spoken-summary.wav"
        panel.canCreateDirectories = true
        if let wav = UTType(filenameExtension: "wav") {
            panel.allowedContentTypes = [wav]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExportingSpeech = true
        Task {
            defer { isExportingSpeech = false }
            do {
                _ = try await synthesizeSpeech(text: text, outputURL: url)
            } catch {
                speechError = error.localizedDescription
            }
        }
    }

    private func synthesizeSpeech(text: String, outputURL: URL?) async throws -> URL {
        try await KokoroSpeechEngine.shared.synthesize(.init(
            text: text,
            voice: app.settings.speechVoice,
            speed: app.settings.speechSpeed,
            outputURL: outputURL))
    }

    struct SpeakerRenameDraft: Identifiable {
        let speaker: String
        let defaultName: String
        let currentName: String

        var id: String { speaker }
    }
}

/// Structured outcomes card atop the summary tab, read from `outcomes.json`
/// (written by the pipeline's extraction pass). Only shown when non-empty.
private struct MeetingOutcomesSection: View {
    let outcomes: MeetingOutcomes

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !outcomes.actionItems.isEmpty {
                group("Action items", icon: "checklist") {
                    ForEach(Array(outcomes.actionItems.enumerated()), id: \.offset) { _, item in
                        row(text: item.text, detail: detail(for: item))
                    }
                }
            }
            if !outcomes.decisions.isEmpty {
                group("Decisions", icon: "checkmark.seal") {
                    ForEach(outcomes.decisions, id: \.self) { row(text: $0, detail: nil) }
                }
            }
            if !outcomes.openQuestions.isEmpty {
                group("Open questions", icon: "questionmark.circle") {
                    ForEach(outcomes.openQuestions, id: \.self) { row(text: $0, detail: nil) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityIdentifier("detail.outcomes")
    }

    private func detail(for item: MeetingOutcomes.ActionItem) -> String? {
        let notes = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    private func group(_ title: String, icon: String,
                       @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            rows()
        }
    }

    private func row(text: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.tertiary)
            Text(text).textSelection(.enabled)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SpeakerRenameSheet: View {
    let draft: MeetingDetailView.SpeakerRenameDraft
    let hints: [String]
    let onSave: (String) -> Void
    let onReset: () -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(draft: MeetingDetailView.SpeakerRenameDraft,
         hints: [String],
         onSave: @escaping (String) -> Void,
         onReset: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.draft = draft
        self.hints = hints
        self.onSave = onSave
        self.onReset = onReset
        self.onCancel = onCancel
        _name = State(initialValue: draft.currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Speaker").font(.headline)
            TextField("Speaker name", text: $name)
                .textFieldStyle(.roundedBorder)

            if !hints.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(hints, id: \.self) { hint in
                            Button(hint) { name = hint }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Button("Reset") { onReset() }
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { onSave(name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // First-checklist-item state: front-load the transcription model download
    // so it doesn't ambush the user's first recap.
    @State private var modelDownloaded = false
    @State private var preparingModel = false
    @State private var modelProgress: Double?
    @State private var modelStatus: String?
    @State private var modelError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroPanel(radius: Brand.Radius.card) {
                    HStack(spacing: 14) {
                        IconTile(systemImage: "waveform.badge.magnifyingglass",
                                 tint: Brand.teal, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Welcome to LokalBot").font(.title2.bold())
                                .foregroundStyle(.white)
                            Text("Record meetings, get the recap, and search everything — all on-device.")
                                .font(.callout).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Button { dismissed = true } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3).foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                        .accessibilityIdentifier("welcome.dismiss")
                    }
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
                    stepRow(done: modelDownloaded ? true : nil) {
                        modelStep
                    }
                    stepRow(done: app.isRecording || !app.meetings.isEmpty) {
                        Text("Record a meeting — it appears in the list automatically.")
                    }
                    stepRow(done: nil) {
                        HStack(spacing: 8) {
                            Button("Turn on day tracking") {
                                app.navSection = .timeline
                            }
                                .buttonStyle(.bordered).controlSize(.small)
                            Text("to see where your time goes.")
                        }
                    }
                    stepRow(done: app.settings.cotypingEnabled ? true : nil) {
                        HStack(spacing: 8) {
                            Button("Try cotyping") { app.openType(.cotyping) }
                                .buttonStyle(.bordered).controlSize(.small)
                            Text("— inline AI autocomplete that stays on your Mac.")
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.panel))

                Text("Tip: press ⌘K anywhere to record, navigate, or jump to a meeting.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            modelDownloaded = TranscriptionModelStore.downloadedChoices()
                .contains(app.settings.transcriptionModel.id)
        }
    }

    /// Checklist item 1: get the transcription model onto disk before the
    /// first recap needs it. `prepare` is idempotent, so racing a first
    /// transcription is harmless.
    @ViewBuilder private var modelStep: some View {
        if modelDownloaded {
            Text("Transcription model ready — recaps run entirely on-device.")
        } else if preparingModel {
            HStack(spacing: 8) {
                ProgressView(value: modelProgress).frame(width: 160)
                Text(modelStatus ?? "Downloading…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button("Download the transcription model") { downloadModel() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Text("one-time — or it downloads with your first recap.")
                }
                if let modelError {
                    Text(modelError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func downloadModel() {
        guard !preparingModel else { return }
        preparingModel = true
        modelError = nil
        let choice = app.settings.transcriptionModel
        Task { @MainActor in
            defer { preparingModel = false }
            do {
                try await choice.engine.prepare { update in
                    modelProgress = update.fractionCompleted
                    modelStatus = update.status
                }
                modelDownloaded = true
            } catch {
                modelError = error.localizedDescription
            }
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
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
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

/// Forces the host window's toolbar to show icons *and* their labels — macOS
/// otherwise renders SwiftUI toolbar items icon-only. Attached as a hidden
/// background view so it configures whichever `NSWindow` ends up hosting the UI
/// (the production scene or the UI-test host) once its toolbar exists, then
/// stays out of the way so a user's later "Icon Only" choice sticks.
private struct WindowToolbarStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var applied = false

        func apply(to view: NSView, attemptsLeft: Int = 12) {
            guard !applied else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                if let toolbar = view.window?.toolbar {
                    toolbar.displayMode = .iconAndLabel
                    self.applied = true
                } else if attemptsLeft > 0 {
                    self.apply(to: view, attemptsLeft: attemptsLeft - 1)
                }
            }
        }
    }
}
