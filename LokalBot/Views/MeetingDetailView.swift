import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

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

    private var dateChip: some View {
        BrandChip(icon: "calendar",
                  text: meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
            .fixedSize()
    }
    private var durationChip: some View { BrandChip(icon: "clock", text: meeting.durationLabel).fixedSize() }
    private var appChip: some View { BrandChip(icon: "video", text: meeting.appName).fixedSize() }
    private var trackChip: some View {
        BrandChip(icon: meeting.hasSystemTrack ? "speaker.wave.2.fill" : "mic.fill",
                  text: meeting.hasSystemTrack ? "Mic + system" : "Mic only")
            .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(meeting.title).font(.title2.bold()).accessibilityIdentifier("detail.title")
            // One row when the detail column has room, two rows when it
            // doesn't — never let chip text wrap inside a chip.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    dateChip; durationChip; appChip; trackChip
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { dateChip; durationChip }
                    HStack(spacing: 6) { appChip; trackChip }
                }
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
                    app.reprocess(meeting, transcribe: true, summarize: true)
                } label: {
                    Label("Transcribe & Summarize", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }
                .help("Transcribe & summarize")
                .accessibilityIdentifier("toolbar.transcribeAndSummarize")

                Button {
                    app.reprocess(meeting, transcribe: true, summarize: false)
                } label: {
                    Label("Transcribe", systemImage: "waveform")
                        .labelStyle(.titleAndIcon)
                }
                .help("Transcribe only")
                .accessibilityIdentifier("toolbar.transcribeOnly")

                Button {
                    app.reprocess(meeting, transcribe: false, summarize: true)
                } label: {
                    Label("Re-summarize", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .help("Re-summarize and keep the current transcript")
                .accessibilityIdentifier("toolbar.resummarize")

                Menu {
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
                    Divider()
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
                } label: {
                    Label("More Meeting Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("toolbar.meetingActions")
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

                WaveformView(url: MeetingAudioFiles.readableURL(for: .mic, in: folder)
                                 ?? MeetingAudioFiles.readableURL(for: .system, in: folder)
                                 ?? MeetingAudioFiles.primaryURL(for: .mic, in: folder),
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
                .foregroundStyle(Brand.error)
                .textSelection(.enabled)
        }
        if let speechError {
            Label(speechError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Brand.error)
                .textSelection(.enabled)
        }
        if let transcriptError {
            Label(transcriptError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Brand.error)
                .textSelection(.enabled)
        }
        if let stage {
            switch stage {
            case .failed:
                HStack(spacing: 10) {
                    Label(stage.label, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Brand.error)
                        .textSelection(.enabled)
                    Button("Retry") { app.retryProcessing(meeting) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("meeting.detail.retry")
                }
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
                    ? "Use Transcribe & Summarize in the toolbar. Summaries are written to summary.md."
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
                    ? "Use Transcribe & Summarize in the toolbar. The first run downloads the Parakeet model (~600 MB) from Hugging Face."
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
        .background(isCurrent ? Brand.teal.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { player.play(at: display.segment.start) }   // click a sentence → jump audio
    }

    private func speakerChip(for display: Transcript.DisplaySegment) -> some View {
        Text(display.speakerLabel)
            .font(.caption.bold())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(display.speakerKey == "me"
                        ? Brand.teal.opacity(0.18)
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
            if !outcomes.userActionItems.isEmpty {
                group("My action items", icon: "person.crop.circle.badge.checkmark") {
                    ForEach(Array(outcomes.userActionItems.enumerated()), id: \.offset) { _, item in
                        row(text: item.text, detail: detail(for: item, includeOwner: false))
                    }
                }
            }
            if !outcomes.otherActionItems.isEmpty {
                group("Other action items", icon: "checklist") {
                    ForEach(Array(outcomes.otherActionItems.enumerated()), id: \.offset) { _, item in
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

    private func detail(for item: MeetingOutcomes.ActionItem,
                        includeOwner: Bool = true) -> String? {
        let owner = includeOwner ? item.owner : nil
        let notes = [owner, item.due.map { "due \($0)" }].compactMap { $0 }
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
