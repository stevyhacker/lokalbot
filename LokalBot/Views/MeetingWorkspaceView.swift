import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Meetings inspector router: list rows open the outcome preview, while deep
/// links and the explicit Open meeting action enter the complete workspace.
struct MeetingLibraryDetailView: View {
    @EnvironmentObject var app: AppState
    @Binding var pendingDelete: Set<Meeting.ID>?

    @ViewBuilder var body: some View {
        if app.selectedMeetingIDs.count > 1 {
            ContentUnavailableView {
                Label("\(app.selectedMeetingIDs.count) meetings selected", systemImage: "checklist")
            } description: {
                Text("Press Delete or use the list menu to remove them.")
            } actions: {
                Button("Delete \(app.selectedMeetingIDs.count) meetings", role: .destructive) {
                    pendingDelete = app.selectedMeetingIDs
                }
                .accessibilityIdentifier("meeting.multiSelect.delete")
            }
        } else if let meeting = app.selectedMeeting {
            if meeting.endedAt == nil {
                LiveMeetingDetailView(meeting: meeting).id(meeting.id)
            } else if app.meetingPresentation == .detail {
                MeetingWorkspaceDetail(meeting: meeting).id(meeting.id)
            } else {
                MeetingOutcomePreview(meeting: meeting).id(meeting.id)
            }
        } else if !app.libraryReady {
            ProgressView("Loading your meeting library...")
        } else {
            ContentUnavailableView(
                "No meeting selected",
                systemImage: "waveform.circle",
                description: Text("Select a meeting to review its outcomes and evidence."))
        }
    }
}

private struct MeetingOutcomePreview: View {
    @EnvironmentObject var app: AppState
    let meeting: Meeting

    private var folder: URL { meeting.folderURL(in: app.storage) }
    private var projection: MeetingOutcomeProjection? { app.outcomeIndex.projection(for: meeting.id) }
    private var summary: String? {
        try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                MeetingWorkspaceHeader(meeting: meeting, compact: true)

                if let summary, !summary.isEmpty {
                    WorkspaceSection(title: "Summary", icon: "text.alignleft") {
                        MarkdownText(summary)
                            .lineLimit(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                WorkspaceSection(title: "My actions", icon: "checklist") {
                    if let actions = projection?.actionReferences.filter(\.isForUser), !actions.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(actions.prefix(4)) { reference in
                                PreviewActionRow(reference: reference)
                                if reference.id != actions.prefix(4).last?.id { Divider() }
                            }
                        }
                    } else {
                        EmptyWorkspaceRow(text: "No action assigned to you was extracted.")
                    }
                }

                WorkspaceSection(title: "Decisions", icon: "checkmark.seal") {
                    if let decisions = projection?.outcomes.decisionRecords, !decisions.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(decisions.prefix(4)) { decision in
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Brand.teal)
                                    Text(decision.text)
                                        .font(WorkspaceTypography.body)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let source = decision.citations.first {
                                        EvidencePill(citation: source) {
                                            app.pendingSeek = source.start
                                            app.meetingPresentation = .detail
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        EmptyWorkspaceRow(text: "No cited decisions were extracted.")
                    }
                }

                HStack {
                    Button("Open meeting") { app.meetingPresentation = .detail }
                        .buttonStyle(.borderedProminent)
                    Button("Draft follow-up") { app.meetingPresentation = .detail }
                    Spacer()
                    Button("Ask about this meeting") {
                        app.openAsk(query: "What matters from \(meeting.displayTitle)?")
                    }
                }
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("meeting.preview.scroll")
        .navigationTitle(meeting.displayTitle)
        .accessibilityIdentifier("meeting.preview")
    }
}

private struct MeetingWorkspaceDetail: View {
    @EnvironmentObject var app: AppState
    let meeting: Meeting

    @StateObject private var player = MeetingPlayer()
    @State private var summary: String?
    @State private var transcript: Transcript?
    @State private var summaryExpanded = false
    @State private var transcriptExpanded = false
    @State private var correction: ActionCorrectionDraft?
    @State private var followUp = FollowUpDraft()
    @State private var savedFollowUpNotice = false
    @State private var exportError: String?
    @State private var speechError: String?
    @State private var isExportingAudio = false
    @State private var isExportingSpeech = false
    @State private var isReadingSummary = false
    @State private var speechPlayer: AVAudioPlayer?
    @State private var speechTask: Task<Void, Never>?

    private var folder: URL { meeting.folderURL(in: app.storage) }
    private var projection: MeetingOutcomeProjection? { app.outcomeIndex.projection(for: meeting.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                HStack(alignment: .top) {
                    MeetingWorkspaceHeader(meeting: meeting, compact: false)
                    Spacer()
                    Menu {
                        Button("Transcribe and summarize") {
                            app.reprocess(meeting, transcribe: true, summarize: true)
                        }
                        Button("Transcribe only") {
                            app.reprocess(meeting, transcribe: true, summarize: false)
                        }
                        Button("Re-summarize") {
                            app.reprocess(meeting, transcribe: false, summarize: true)
                        }
                        Divider()
                        Button(isReadingSummary ? "Stop spoken summary" : "Read summary aloud") {
                            isReadingSummary ? stopSpeech() : readSummary()
                        }
                        .disabled(summary?.isEmpty != false)
                        Button(isExportingSpeech ? "Exporting spoken summary..." : "Export spoken summary") {
                            exportSpokenSummary()
                        }
                        .disabled(isExportingSpeech || summary?.isEmpty != false)
                        Button(isExportingAudio ? "Exporting audio..." : "Export audio") {
                            exportAudio()
                        }
                        .disabled(isExportingAudio || !player.isLoaded)
                        Divider()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("meeting.more")
                }

                if player.isLoaded { MeetingAudioBar(player: player, folder: folder) }
                if let stage = app.pipeline.stages[meeting.id] {
                    HStack(spacing: 10) {
                        Label(stage.label, systemImage: stage.isFailure
                              ? "exclamationmark.triangle" : "sparkles")
                            .font(.callout)
                            .foregroundStyle(stage.isFailure ? .orange : .secondary)
                        if stage.isFailure {
                            Button("Retry") { app.retryProcessing(meeting) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("meeting.workspace.retry")
                        }
                    }
                }
                if let exportError {
                    Label(exportError, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Brand.error)
                }
                if let speechError {
                    Label(speechError, systemImage: "speaker.slash")
                        .font(.callout).foregroundStyle(Brand.error)
                }

                WorkspaceSection(title: "Action items", icon: "checklist") {
                    if let actions = projection?.actionReferences, !actions.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(actions) { reference in
                                OutcomeActionRow(
                                    reference: reference,
                                    onStatus: { status in
                                        _ = app.outcomeIndex.setStatus(
                                            status,
                                            actionID: reference.action.id,
                                            meetingID: meeting.id)
                                    },
                                    onCorrect: {
                                        correction = ActionCorrectionDraft(reference: reference)
                                    },
                                    onEvidence: { citation in
                                        transcriptExpanded = true
                                        player.play(at: citation.start)
                                    })
                                if reference.id != actions.last?.id { Divider() }
                            }
                        }
                    } else {
                        EmptyWorkspaceRow(text: "No action items were extracted from this meeting.")
                    }
                }

                WorkspaceSection(title: "Decisions", icon: "checkmark.seal") {
                    if let decisions = projection?.outcomes.decisionRecords, !decisions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(decisions) { decision in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Brand.teal)
                                    Text(decision.text)
                                        .font(WorkspaceTypography.body)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                    if let citation = decision.citations.first {
                                        EvidencePill(citation: citation) {
                                            transcriptExpanded = true
                                            player.play(at: citation.start)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        EmptyWorkspaceRow(text: "No cited decisions were extracted.")
                    }
                }

                FollowUpDraftEditor(
                    meeting: meeting,
                    draft: $followUp,
                    savedNotice: $savedFollowUpNotice,
                    onSave: {
                        savedFollowUpNotice = app.outcomeIndex.saveFollowUp(
                            followUp, meetingID: meeting.id)
                    })

                WorkspaceDisclosure(
                    isExpanded: $summaryExpanded,
                    identifier: "meeting.summaryDisclosure") {
                    if let summary, !summary.isEmpty {
                        MarkdownText(summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else {
                        EmptyWorkspaceRow(text: "No summary yet.")
                    }
                } label: {
                    Label("Summary", systemImage: "text.alignleft")
                        .font(WorkspaceTypography.sectionTitle)
                }

                WorkspaceDisclosure(
                    isExpanded: $transcriptExpanded,
                    identifier: "meeting.transcriptDisclosure") {
                    TranscriptEvidenceList(transcript: transcript, player: player)
                } label: {
                    Label("Transcript", systemImage: "text.bubble")
                        .font(WorkspaceTypography.sectionTitle)
                }
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(meeting.displayTitle)
        .task(id: meeting.id) { load() }
        .onChange(of: app.pendingSeek) { _, value in
            guard let value else { return }
            app.pendingSeek = nil
            transcriptExpanded = true
            player.play(at: value)
        }
        .sheet(item: $correction) { draft in
            ActionCorrectionSheet(draft: draft) { text, owner, due in
                _ = app.outcomeIndex.correctAction(
                    actionID: draft.actionID,
                    meetingID: meeting.id,
                    text: text == draft.originalText ? nil : text,
                    owner: owner,
                    due: due)
                correction = nil
            } onCancel: { correction = nil }
        }
        .onDisappear {
            player.stop()
            stopSpeech(clearError: false)
        }
        .accessibilityIdentifier("meeting.detail.workspace")
    }

    private func load() {
        summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        transcript = try? app.pipeline.loadTranscript(from: folder)
        player.load(folder: folder, hasSystemTrack: meeting.hasSystemTrack)
        app.outcomeIndex.refresh(meeting: meeting)
        followUp = app.outcomeIndex.projection(for: meeting.id)?.followUp
            ?? FollowUpDraft.seeded(for: meeting, outcomes: MeetingOutcomes())
        if let seek = app.pendingSeek {
            app.pendingSeek = nil
            transcriptExpanded = true
            player.play(at: seek)
        }
    }

    private func exportAudio() {
        exportError = nil
        let panel = NSSavePanel()
        panel.title = "Export Audio Recording"
        panel.nameFieldStringValue = "\(StorageManager.slugify(meeting.displayTitle))-audio.m4a"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: "m4a") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingAudio = true
        Task {
            defer { isExportingAudio = false }
            do {
                try await MeetingAudioAsset.exportMixedRecording(
                    folder: folder,
                    hasSystemTrack: meeting.hasSystemTrack,
                    to: destination)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func readSummary() {
        guard let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        stopSpeech(clearError: false)
        speechError = nil
        isReadingSummary = true
        speechTask = Task {
            defer { stopSpeech(clearError: false) }
            do {
                let url = try await synthesize(text, outputURL: nil)
                try Task.checkCancellation()
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                speechPlayer = player
                guard player.play() else {
                    throw NSError(
                        domain: "LokalBot.SpeechPlayback", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not start speech playback."])
                }
                try await Task.sleep(
                    nanoseconds: UInt64(max(player.duration, 0.1) * 1_000_000_000))
            } catch is CancellationError {
            } catch {
                speechError = error.localizedDescription
            }
        }
    }

    private func exportSpokenSummary() {
        guard let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        speechError = nil
        let panel = NSSavePanel()
        panel.title = "Export Spoken Summary"
        panel.nameFieldStringValue = "\(StorageManager.slugify(meeting.displayTitle))-spoken-summary.wav"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: "wav") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingSpeech = true
        Task {
            defer { isExportingSpeech = false }
            do {
                _ = try await synthesize(text, outputURL: destination)
            } catch {
                speechError = error.localizedDescription
            }
        }
    }

    private func synthesize(_ text: String, outputURL: URL?) async throws -> URL {
        try await KokoroSpeechEngine.shared.synthesize(.init(
            text: text,
            voice: app.settings.speechVoice,
            speed: app.settings.speechSpeed,
            outputURL: outputURL))
    }

    private func stopSpeech(clearError: Bool = true) {
        speechTask?.cancel()
        speechTask = nil
        speechPlayer?.stop()
        speechPlayer = nil
        isReadingSummary = false
        if clearError { speechError = nil }
    }
}

private struct MeetingWorkspaceHeader: View {
    let meeting: Meeting
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.displayTitle)
                .font(compact ? WorkspaceTypography.pageTitle : WorkspaceTypography.display)
                .accessibilityIdentifier("detail.title")
            HStack(spacing: 7) {
                BrandChip(icon: "calendar", text: meeting.startedAt.formatted(
                    date: .abbreviated, time: .shortened))
                BrandChip(icon: "clock", text: meeting.durationLabel)
                BrandChip(icon: "video", text: meeting.appName)
                BrandChip(
                    icon: meeting.hasSystemTrack ? "speaker.wave.2.fill" : "mic.fill",
                    text: meeting.hasSystemTrack ? "Mic + system" : "Mic only")
            }
        }
    }
}

private struct MeetingAudioBar: View {
    @ObservedObject var player: MeetingPlayer
    let folder: URL

    var body: some View {
        let progress = player.duration > 0 ? player.currentTime / player.duration : 0
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                Button { player.playPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                WaveformView(
                    url: MeetingAudioFiles.readableURL(for: .mic, in: folder)
                        ?? MeetingAudioFiles.readableURL(for: .system, in: folder)
                        ?? MeetingAudioFiles.primaryURL(for: .mic, in: folder),
                    progress: progress,
                    onSeek: { player.seek(to: $0 * player.duration) })
                Menu("\(player.speed.formatted())x") {
                    ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(speed.formatted())x") { player.speed = Float(speed) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack {
                Text(Transcript.stamp(player.currentTime))
                Spacer()
                Text(Transcript.stamp(player.duration))
            }
            .font(WorkspaceTypography.metadata.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .workspacePanel()
    }
}

private struct PreviewActionRow: View {
    @EnvironmentObject var app: AppState
    let reference: OutcomeActionReference

    var body: some View {
        HStack(spacing: 10) {
            Button {
                _ = app.outcomeIndex.setStatus(
                    reference.status == .done ? .open : .done,
                    actionID: reference.action.id,
                    meetingID: reference.meetingID)
            } label: {
                Image(systemName: reference.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reference.status == .done ? Brand.teal : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meeting.preview.action.toggle.\(reference.action.id)")
            Text(reference.text)
                .font(WorkspaceTypography.body)
                .strikethrough(reference.status == .done)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("meeting.preview.action.text.\(reference.action.id)")
            if let due = reference.due { BrandChip(icon: "calendar", text: due, size: .compact) }
        }
        .padding(.vertical, WorkspaceMetric.rowVerticalPadding)
    }
}

private struct OutcomeActionRow: View {
    @EnvironmentObject var app: AppState
    let reference: OutcomeActionReference
    let onStatus: (OutcomeStatus) -> Void
    let onCorrect: () -> Void
    let onEvidence: (OutcomeSourceCitation) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { onStatus(reference.status == .done ? .open : .done) } label: {
                Image(systemName: reference.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reference.status == .done ? Brand.teal : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meeting.action.toggle.\(reference.action.id)")
            VStack(alignment: .leading, spacing: 5) {
                Text(reference.text)
                    .font(WorkspaceTypography.body)
                    .strikethrough(reference.status == .done)
                    .textSelection(.enabled)
                HStack(spacing: 7) {
                    Button(reference.owner ?? "Unassigned", action: onCorrect)
                        .buttonStyle(.plain)
                        .font(WorkspaceTypography.metadataEmphasis)
                        .foregroundStyle(.secondary)
                    if let due = reference.due {
                        BrandChip(icon: "calendar", text: due, size: .compact)
                    }
                    if let citation = reference.action.citations.first {
                        EvidencePill(citation: citation) { onEvidence(citation) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(OutcomeStatus.allCases, id: \.rawValue) { status in
                    Button(status.label) { onStatus(status) }
                }
                Divider()
                Button("Correct owner or due date", action: onCorrect)
                Button("Open in Agent") {
                    app.openAgent(.init(
                        title: reference.text,
                        prompt: "Help me complete this action from \(reference.meetingTitle): \(reference.text)",
                        meetingID: reference.meetingID,
                        actionID: reference.action.id))
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("meeting.action.status.\(reference.action.id)")
        }
        .padding(.vertical, WorkspaceMetric.rowVerticalPadding)
        .accessibilityIdentifier("meeting.action.\(reference.action.id)")
    }
}

private struct ActionCorrectionDraft: Identifiable {
    let id = UUID()
    let actionID: String
    let originalText: String
    var text: String
    var owner: String
    var due: String

    init(reference: OutcomeActionReference) {
        actionID = reference.action.id
        originalText = reference.action.text
        text = reference.text
        owner = reference.owner ?? ""
        due = reference.due ?? ""
    }
}

private struct ActionCorrectionSheet: View {
    @State var draft: ActionCorrectionDraft
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct action details").font(WorkspaceTypography.pageTitle)
            TextField("Corrected wording", text: $draft.text)
            HStack {
                Text("Owner")
                Spacer()
                Menu(draft.owner.isEmpty ? "Unassigned" : draft.owner) {
                    Button("Me") { draft.owner = "Me" }
                    Button("Unresolved speaker") { draft.owner = "Unresolved speaker" }
                    Button("Unassigned") { draft.owner = "" }
                }
            }
            TextField("Owner", text: $draft.owner)
            TextField("Due date as agreed", text: $draft.due)
            Text("This correction is stored separately from the extracted source.")
                .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save correction") { onSave(draft.text, draft.owner, draft.due) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private struct FollowUpDraftEditor: View {
    let meeting: Meeting
    @Binding var draft: FollowUpDraft
    @Binding var savedNotice: Bool
    let onSave: () -> Void

    var body: some View {
        WorkspaceSection(title: "Follow-up", icon: "arrowshape.turn.up.right") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Recipient (optional)", text: $draft.recipient)
                    TextField("Cc (optional)", text: $draft.cc)
                }
                HStack {
                    TextField("Subject", text: $draft.subject)
                }
                TextEditor(text: $draft.body)
                    .font(WorkspaceTypography.body)
                    .frame(minHeight: 150)
                    .padding(7)
                    .workspaceControl()
                HStack {
                    if savedNotice {
                        Label("Saved locally", systemImage: "checkmark.circle")
                            .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save draft", action: onSave)
                    Button(draft.reviewed ? "Reviewed" : "Mark reviewed") {
                        draft.reviewed = true
                        onSave()
                    }
                    .disabled(draft.reviewed)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exportText, forType: .string)
                    }
                    Button("Export...") { export() }
                }
                Text("LokalBot does not send this. Review it, then copy or export it.")
                    .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            }
        }
    }

    private var exportText: String {
        ([draft.recipient.isEmpty ? nil : "To: \(draft.recipient)",
          draft.cc.isEmpty ? nil : "Cc: \(draft.cc)",
          draft.subject.isEmpty ? nil : "Subject: \(draft.subject)", "", draft.body]
            .compactMap { $0 }).joined(separator: "\n")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(StorageManager.slugify(meeting.displayTitle))-follow-up.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exportText.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct TranscriptEvidenceList: View {
    let transcript: Transcript?
    @ObservedObject var player: MeetingPlayer

    var body: some View {
        if let transcript, !transcript.segments.isEmpty {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                    Button {
                        player.play(at: segment.start)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(Transcript.stamp(segment.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 64, alignment: .trailing)
                            Text(transcript.displaySpeaker(for: segment.speaker))
                                .font(.caption.bold())
                                .frame(width: 72, alignment: .leading)
                                .accessibilityIdentifier("transcript.segment.\(index).speaker")
                            Text(segment.displayText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("transcript.segment.\(index)")
                    .accessibilityLabel(
                        "\(transcript.displaySpeaker(for: segment.speaker)), "
                            + "\(Transcript.stamp(segment.start)). \(segment.displayText)")
                }
            }
        } else {
            EmptyWorkspaceRow(text: "No transcript yet.")
        }
    }
}

struct EvidencePill: View {
    let citation: OutcomeSourceCitation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(Transcript.stamp(citation.start), systemImage: "quote.bubble")
                .font(WorkspaceTypography.metadata.monospacedDigit())
        }
        .buttonStyle(.borderless)
        .help(citation.excerpt)
        .accessibilityLabel("Jump to evidence at \(Transcript.stamp(citation.start))")
    }
}

struct WorkspaceSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(WorkspaceTypography.sectionTitle)
            content
        }
        .workspacePanel()
    }
}

struct EmptyWorkspaceRow: View {
    let text: String
    var body: some View {
        Text(text).font(WorkspaceTypography.body).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}
