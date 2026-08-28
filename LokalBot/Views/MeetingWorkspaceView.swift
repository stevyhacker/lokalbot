import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Meetings inspector router. A completed selection opens the full workspace;
/// an active recording keeps its dedicated live surface.
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
            } else {
                MeetingWorkspaceDetail(meeting: meeting).id(meeting.id)
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

private struct MeetingWorkspaceDetail: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let meeting: Meeting

    @StateObject private var player = MeetingPlayer()
    @State private var summary: String?
    @State private var notes: String?
    @State private var transcript: Transcript?
    @State private var transcriptExpanded = false
    @State private var correction: ActionCorrectionDraft?
    @State private var speakerRenameDraft: WorkspaceSpeakerRenameDraft?
    @State private var speakerNameHints: [String] = []
    @State private var calendarSpeakerCandidates: [CalendarParticipantIdentity] = []
    @State private var exportError: String?
    @State private var speechError: String?
    @State private var isExportingAudio = false
    @State private var isExportingSpeech = false
    @State private var isReadingSummary = false
    @State private var speechPlayer: AVAudioPlayer?
    @State private var speechTask: Task<Void, Never>?
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @State private var searchMatches: [MeetingPageSearchMatch] = []
    @State private var selectedSearchMatchIndex = 0
    @State private var searchContentRevision = 0
    @FocusState private var searchFieldFocused: Bool

    private var folder: URL { meeting.folderURL(in: app.storage) }
    private var projection: MeetingOutcomeProjection? { app.outcomeIndex.projection(for: meeting.id) }
    private var captureTranscriptOnly: Bool {
#if LOKALBOT_UI_TEST_HOST
        ProcessInfo.processInfo.environment["LOKALBOT_DETAIL_TAB"] == "transcript"
#else
        false
#endif
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                if isSearchPresented {
                    MeetingPageSearchBar(
                        query: $searchQuery,
                        fieldFocused: $searchFieldFocused,
                        statusText: searchStatusText,
                        hasMatches: !searchMatches.isEmpty,
                        onPrevious: { moveSearch(by: -1, using: scrollProxy) },
                        onNext: { moveSearch(by: 1, using: scrollProxy) },
                        onClose: dismissSearch)
                    .padding(.horizontal, WorkspaceMetric.pagePadding)
                    .padding(.vertical, 10)
                    Divider()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                        MeetingWorkspaceHeader(meeting: meeting)

                        if player.isLoaded { MeetingAudioBar(player: player, folder: folder) }
                        if let stage = app.pipeline.stages[meeting.id] {
                            HStack(spacing: 10) {
                                Label(stage.label, systemImage: stageIcon(stage))
                                    .font(.callout)
                                    .foregroundStyle(stage.isFailure ? Brand.error : .secondary)
                                if stage.isFailure {
                                    Button("Retry") { app.retryProcessing(meeting) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityIdentifier("meeting.workspace.retry")
                                } else if stage.isWaitingForModels {
                                    Button("Download & process") { app.retryProcessing(meeting) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityIdentifier("meeting.workspace.downloadProcess")
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

                        if !captureTranscriptOnly {
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
                                                    correction = ActionCorrectionDraft(
                                                        reference: reference)
                                                },
                                                onEvidence: { citation in
                                                    transcriptExpanded = true
                                                    player.play(at: citation.start)
                                                })
                                            if reference.id != actions.last?.id { Divider() }
                                        }
                                    }
                                } else {
                                    EmptyWorkspaceRow(
                                        text: "No action items were extracted from this meeting.")
                                }
                            }

                            WorkspaceSection(title: "Decisions", icon: "checkmark.seal") {
                                if let decisions = projection?.outcomes.decisionRecords,
                                   !decisions.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(decisions) { decision in
                                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(Brand.teal)
                                                Text(decision.displayText)
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

                            WorkspaceSection(title: "Summary", icon: "text.alignleft") {
                                if notes?.isEmpty == false || summary?.isEmpty == false {
                                    VStack(alignment: .leading, spacing: 14) {
                                        if let notes, !notes.isEmpty {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Label(
                                                    "Your notes",
                                                    systemImage: "square.and.pencil")
                                                .font(WorkspaceTypography.metadataEmphasis)
                                                .foregroundStyle(.secondary)
                                                SelectableDigestText(
                                                    notes,
                                                    searchQuery: visibleSearchQuery,
                                                    activeMatchIndex: activeOccurrence(at: .notes))
                                                .id(MeetingPageSearchMatch.Location.notes)
                                            }
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                .quaternary.opacity(0.24),
                                                in: RoundedRectangle(
                                                    cornerRadius: Brand.Radius.control))
                                            .accessibilityIdentifier("detail.notes")
                                        }
                                        if let summary, !summary.isEmpty {
                                            let parts = SummaryPresentation.split(summary)
                                            if !parts.metadata.isEmpty {
                                                SummaryMetadataRow(items: parts.metadata)
                                            }
                                            SelectableDigestText(
                                                parts.body,
                                                searchQuery: visibleSearchQuery,
                                                activeMatchIndex: activeOccurrence(at: .summary))
                                            .id(MeetingPageSearchMatch.Location.summary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .workspaceReadingWidth()
                                } else {
                                    EmptyWorkspaceRow(text: "No summary yet.")
                                }
                            }
                            .accessibilityIdentifier("meeting.summary")
                        }

                        WorkspaceDisclosure(
                            isExpanded: $transcriptExpanded,
                            identifier: "meeting.transcriptDisclosure") {
                            TranscriptEvidenceList(
                                transcript: transcript,
                                player: player,
                                searchQuery: visibleSearchQuery,
                                activeMatch: activeSearchMatch,
                                onRenameSpeaker: { beginRenameSpeaker($0) })
                        } label: {
                            Label("Transcript", systemImage: "text.bubble")
                                .font(WorkspaceTypography.sectionTitle)
                        }
                    }
                    .padding(WorkspaceMetric.pagePadding)
                    .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .onChange(of: searchQuery) {
                updateSearch(using: scrollProxy)
            }
            .onChange(of: searchContentRevision) {
                if isSearchPresented {
                    updateSearch(using: scrollProxy)
                }
            }
        }
        .navigationTitle(meeting.displayTitle)
        .task(id: meeting.id) {
            load()
#if LOKALBOT_UI_TEST_HOST
            if ProcessInfo.processInfo.environment["LOKALBOT_DETAIL_TAB"] == "transcript" {
                transcriptExpanded = true
            }
#endif
        }
        .onChange(of: app.navigationHandoff.revision) { consumeMeetingSeek() }
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
        .sheet(item: $speakerRenameDraft) { draft in
            WorkspaceSpeakerRenameSheet(
                draft: draft,
                hints: speakerNameHints,
                calendarCandidates: calendarCandidates(for: draft.speaker),
                assignedCalendarIdentityIDs: assignedCalendarIdentityIDs,
                onSave: { name, identityID in
                    saveSpeakerAlias(
                        name,
                        calendarIdentityID: identityID,
                        for: draft.speaker)
                },
                onReset: {
                    saveSpeakerAlias(
                        nil,
                        calendarIdentityID: nil,
                        for: draft.speaker)
                },
                onCancel: { speakerRenameDraft = nil })
        }
        .onDisappear {
            player.stop()
            stopSpeech(clearError: false)
        }
        .focusedSceneValue(
            \.meetingPageSearchAction,
            MeetingPageSearchAction(perform: presentSearch))
        .meetingProcessingToolbar(app: app, meeting: meeting)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: presentSearch) {
                    Label("Find in Meeting", systemImage: "magnifyingglass")
                }
                .help("Find in summary and transcript (⌘F)")
                .accessibilityIdentifier("toolbar.meetingSearch")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(isReadingSummary ? "Stop spoken summary" : "Read summary aloud") {
                        isReadingSummary ? stopSpeech() : readSummary()
                    }
                    .disabled(summary?.isEmpty != false)
                    Button(isExportingSpeech ? "Exporting spoken summary..." : "Export spoken summary") {
                        exportSpokenSummary()
                    }
                    .disabled(isExportingSpeech || summary?.isEmpty != false)
                    Divider()
                    Button {
                        copySummary()
                    } label: {
                        Label("Copy Summary", systemImage: "doc.on.doc")
                    }
                    .disabled(summary?.isEmpty != false)
                    Button {
                        copyTranscript()
                    } label: {
                        Label("Copy Transcript", systemImage: "text.bubble")
                    }
                    .disabled(transcript?.segments.isEmpty != false)
                    Button {
                        MeetingMarkdownActions.copy(meeting)
                    } label: {
                        Label("Copy Meeting as Markdown", systemImage: "doc.on.doc")
                    }
                    Button {
                        exportError = MeetingMarkdownActions.export(meeting)
                    } label: {
                        Label("Export Meeting as Markdown...", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(isExportingAudio ? "Exporting audio..." : "Export audio") {
                        exportAudio()
                    }
                    .disabled(isExportingAudio || !player.isLoaded)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                } label: {
                    Label("More Meeting Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("toolbar.meetingActions")
            }
        }
        .accessibilityIdentifier("meeting.detail.workspace")
    }

    private func stageIcon(_ stage: ProcessingPipeline.Stage) -> String {
        if stage.isFailure { return "exclamationmark.triangle" }
        if stage.isWaitingForModels { return "arrow.down.circle" }
        return "sparkles"
    }

    private var visibleSearchQuery: String {
        isSearchPresented ? searchQuery : ""
    }

    private var activeSearchMatch: MeetingPageSearchMatch? {
        guard isSearchPresented,
              searchMatches.indices.contains(selectedSearchMatchIndex) else { return nil }
        return searchMatches[selectedSearchMatchIndex]
    }

    private var searchStatusText: String {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Summary + transcript" }
        guard let match = activeSearchMatch else { return "No matches" }
        return "\(selectedSearchMatchIndex + 1) of \(searchMatches.count) · "
            + match.location.sectionLabel
    }

    private func activeOccurrence(
        at location: MeetingPageSearchMatch.Location
    ) -> Int? {
        guard let match = activeSearchMatch, match.location == location else { return nil }
        return match.occurrenceIndex
    }

    private func presentSearch() {
        isSearchPresented = true
        DispatchQueue.main.async {
            searchFieldFocused = true
        }
    }

    private func dismissSearch() {
        isSearchPresented = false
        searchFieldFocused = false
        searchQuery = ""
        searchMatches = []
        selectedSearchMatchIndex = 0
    }

    private func updateSearch(using scrollProxy: ScrollViewProxy) {
        let notesText = captureTranscriptOnly ? nil : notes.map {
            SelectableDigestText.searchableText(from: $0)
        }
        let summaryText = captureTranscriptOnly ? nil : summary.map {
            SelectableDigestText.searchableText(
                from: SummaryPresentation.split($0).body)
        }
        let matches = MeetingPageSearch.matches(
            query: searchQuery,
            notesText: notesText,
            summaryText: summaryText,
            transcript: transcript)
        searchMatches = matches
        selectedSearchMatchIndex = 0
        if let first = matches.first {
            reveal(first, using: scrollProxy)
        }
    }

    private func moveSearch(by offset: Int, using scrollProxy: ScrollViewProxy) {
        guard !searchMatches.isEmpty else { return }
        selectedSearchMatchIndex = (
            selectedSearchMatchIndex + offset + searchMatches.count
        ) % searchMatches.count
        reveal(searchMatches[selectedSearchMatchIndex], using: scrollProxy)
    }

    private func reveal(
        _ match: MeetingPageSearchMatch,
        using scrollProxy: ScrollViewProxy
    ) {
        let needsTranscriptLayout: Bool
        if case .transcript = match.location {
            needsTranscriptLayout = !transcriptExpanded
            transcriptExpanded = true
        } else {
            needsTranscriptLayout = false
        }

        let scroll = {
            withAnimation(WorkspaceMotion.animation(
                .autoScroll,
                reduceMotion: reduceMotion)) {
                scrollProxy.scrollTo(match.location, anchor: .center)
            }
        }
        if needsTranscriptLayout {
            DispatchQueue.main.async(execute: scroll)
        } else {
            scroll()
        }
    }

    private func load() {
        summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        notes = MeetingNotes.load(from: folder)
        transcript = try? app.pipeline.loadTranscript(from: folder)
        speakerNameHints = app.speakerNameHints(for: meeting)
        calendarSpeakerCandidates = meeting.resolvedCalendarParticipantIdentities
        player.load(folder: folder, hasSystemTrack: meeting.hasSystemTrack)
        app.outcomeIndex.refresh(meeting: meeting)
        consumeMeetingSeek()
        searchContentRevision += 1
    }

    private func consumeMeetingSeek() {
        if let seek = app.navigationHandoff.consumeMeetingSeek(for: meeting.id) {
            transcriptExpanded = true
            player.play(at: seek)
        }
    }

    private func copySummary() {
        guard let summary, !summary.isEmpty else { return }
        MeetingMarkdownActions.copyText(summary)
    }

    private func copyTranscript() {
        guard let transcript, !transcript.segments.isEmpty else { return }
        MeetingMarkdownActions.copyText(transcript.markdown)
    }

    private func beginRenameSpeaker(_ speaker: String) {
        guard let transcript else { return }
        speakerRenameDraft = WorkspaceSpeakerRenameDraft(
            speaker: speaker,
            defaultName: Transcript.defaultSpeakerName(for: speaker),
            currentName: transcript.displaySpeaker(for: speaker),
            currentCalendarIdentityID: transcript.calendarIdentityID(for: speaker))
    }

    private var assignedCalendarIdentityIDs: Set<String> {
        Set(transcript?.speakerCalendarIdentityIDs.values.map { $0 } ?? [])
    }

    private func calendarCandidates(
        for speaker: String
    ) -> [CalendarParticipantIdentity] {
        Transcript.canonicalSpeakerKey(speaker) == "me"
            ? []
            : calendarSpeakerCandidates
    }

    private func saveSpeakerAlias(
        _ alias: String?,
        calendarIdentityID: String?,
        for speaker: String
    ) {
        guard var updated = transcript else { return }
        updated.setSpeakerAlias(
            alias,
            for: speaker,
            calendarIdentityID: calendarIdentityID)
        do {
            try app.saveTranscript(updated, for: meeting)
            transcript = updated
            speakerRenameDraft = nil
            exportError = nil
        } catch {
            exportError = "Could not save speaker name: \(error.localizedDescription)"
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

private struct MeetingPageSearchBar: View {
    @Binding var query: String
    @FocusState.Binding var fieldFocused: Bool
    let statusText: String
    let hasMatches: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search summary and transcript", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(onNext)
                .accessibilityIdentifier("meeting.search.field")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityIdentifier("meeting.search.clear")
            }

            Text(statusText)
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("meeting.search.status")

            Divider().frame(height: 18)

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(!hasMatches)
            .help("Previous match")
            .accessibilityIdentifier("meeting.search.previous")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(!hasMatches)
            .help("Next match")
            .accessibilityIdentifier("meeting.search.next")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close search")
            .accessibilityIdentifier("meeting.search.close")
        }
        .font(WorkspaceTypography.control)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .workspaceControl()
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("meeting.search.bar")
    }
}

private struct MeetingWorkspaceHeader: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.displayTitle)
                .font(WorkspaceTypography.display)
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
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (Space)")
                WaveformView(
                    url: MeetingAudioFiles.readableURL(for: .mic, in: folder)
                        ?? MeetingAudioFiles.readableURL(for: .system, in: folder)
                        ?? MeetingAudioFiles.primaryURL(for: .mic, in: folder),
                    progress: progress,
                    onSeek: { player.seek(to: $0 * player.duration) })
                Menu("\(player.speed.formatted())x") {
                    ForEach([1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { speed in
                        Button("\(speed.formatted())x") { player.speed = Float(speed) }
                    }
                    Divider()
                    Button("Reset to 1x") { player.speed = 1.0 }
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
        .accessibilityIdentifier("meeting.audioPlayer")
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
        .padding(WorkspaceMetric.sectionGap)
        .frame(width: 460)
    }
}

private struct TranscriptEvidenceList: View {
    let transcript: Transcript?
    @ObservedObject var player: MeetingPlayer
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let onRenameSpeaker: (String) -> Void

    var body: some View {
        if let transcript, !transcript.segments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !transcript.engine.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .foregroundStyle(.tint)
                        Text("Transcribed with ")
                            + Text(transcript.engine).fontWeight(.medium)
                    }
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.24),
                                in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                    .accessibilityIdentifier("transcript.model")
                }

                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                player.play(at: segment.start)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 8))
                                    Text(Transcript.stamp(segment.start))
                                        .font(.caption.monospacedDigit())
                                }
                                .foregroundStyle(.tertiary)
                                .frame(width: 64, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            .help("Play from \(Transcript.stamp(segment.start))")
                            .accessibilityIdentifier("transcript.segment.\(index).play")
                            Button {
                                onRenameSpeaker(segment.speaker)
                            } label: {
                                Text(transcript.displaySpeaker(for: segment.speaker))
                                    .font(.caption.bold())
                                    .frame(width: 72, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Rename speaker")
                            .accessibilityIdentifier("transcript.segment.\(index).speaker")
                            SearchHighlightedText(
                                segment.displayText,
                                query: searchQuery,
                                activeMatchIndex: activeOccurrence(for: index))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .help("Select text and press Command-C to copy")
                                .accessibilityIdentifier("transcript.segment.\(index).text")
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                        .background(
                            isActive(segment)
                                ? Brand.teal.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                        .id(MeetingPageSearchMatch.Location.transcript(segmentIndex: index))
                    }
                }
            }
        } else {
            EmptyWorkspaceRow(text: "No transcript yet.")
        }
    }

    private func isActive(_ segment: Transcript.Segment) -> Bool {
        player.currentTime >= segment.start
            && player.currentTime < max(segment.end, segment.start + 0.5)
    }

    private func activeOccurrence(for segmentIndex: Int) -> Int? {
        guard activeMatch?.location == .transcript(segmentIndex: segmentIndex) else {
            return nil
        }
        return activeMatch?.occurrenceIndex
    }
}

private struct MeetingProcessingToolbarModifier: ViewModifier {
    @ObservedObject var app: AppState
    let meeting: Meeting

    func body(content: Content) -> some View {
        content.toolbar {
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
            }
        }
    }
}

private extension View {
    func meetingProcessingToolbar(app: AppState, meeting: Meeting) -> some View {
        modifier(MeetingProcessingToolbarModifier(app: app, meeting: meeting))
    }
}

private struct WorkspaceSpeakerRenameDraft: Identifiable {
    let id = UUID()
    let speaker: String
    let defaultName: String
    let currentName: String
    let currentCalendarIdentityID: String?
}

private struct WorkspaceSpeakerRenameSheet: View {
    let draft: WorkspaceSpeakerRenameDraft
    let hints: [String]
    let calendarCandidates: [CalendarParticipantIdentity]
    let assignedCalendarIdentityIDs: Set<String>
    let onSave: (String, String?) -> Void
    let onReset: () -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var selectedCalendarIdentityID: String?

    init(
        draft: WorkspaceSpeakerRenameDraft,
        hints: [String],
        calendarCandidates: [CalendarParticipantIdentity],
        assignedCalendarIdentityIDs: Set<String>,
        onSave: @escaping (String, String?) -> Void,
        onReset: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.hints = hints
        self.calendarCandidates = calendarCandidates
        self.assignedCalendarIdentityIDs = assignedCalendarIdentityIDs
        self.onSave = onSave
        self.onReset = onReset
        self.onCancel = onCancel
        _name = State(initialValue: draft.currentName)
        _selectedCalendarIdentityID = State(
            initialValue: draft.currentCalendarIdentityID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Speaker").font(.headline)
            TextField("Speaker name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("speaker.rename.name")

            if !calendarCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Calendar attendees")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(calendarCandidates.enumerated()), id: \.element.id) { index, candidate in
                        calendarCandidateRow(candidate, index: index)
                    }

                    Text("Email addresses stay in this meeting's local metadata and are shown only to distinguish attendees.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(
                    .quaternary.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 8))
            }

            if !otherHints.isEmpty {
                Text("Other suggestions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(otherHints, id: \.self) { hint in
                            Button(hint) {
                                name = hint
                                selectedCalendarIdentityID = nil
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Button("Reset to \(draft.defaultName)", action: onReset)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(name, selectedCalendarIdentityID) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("speaker.rename.save")
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private var otherHints: [String] {
        let calendarNames = Set(calendarCandidates.compactMap(\.name).map(normalizedName))
        return hints.filter { !calendarNames.contains(normalizedName($0)) }
    }

    private func calendarCandidateRow(
        _ candidate: CalendarParticipantIdentity,
        index: Int
    ) -> some View {
        let assignedElsewhere = assignedCalendarIdentityIDs.contains(candidate.id)
            && candidate.id != draft.currentCalendarIdentityID
        return Button {
            selectedCalendarIdentityID = candidate.id
            name = candidate.name ?? ""
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedCalendarIdentityID == candidate.id
                      ? "checkmark.circle.fill"
                      : "person.crop.circle")
                    .foregroundStyle(selectedCalendarIdentityID == candidate.id
                                     ? Color.accentColor
                                     : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name ?? "Name unavailable")
                        .foregroundStyle(.primary)
                    if let email = candidate.emailAddress {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if assignedElsewhere {
                    Text("Assigned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(assignedElsewhere)
        .accessibilityIdentifier("speaker.rename.calendarCandidate.\(index)")
    }

    private func normalizedName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current)
    }
}

@MainActor
private enum MeetingMarkdownActions {
    static func copy(_ meeting: Meeting) {
        copyText(SessionFormatter.getMarkdown(meeting, options: .all))
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Returns an error message for inline presentation, or nil after either
    /// a successful export or a user-cancelled save panel.
    static func export(_ meeting: Meeting) -> String? {
        let panel = NSSavePanel()
        panel.title = "Export Meeting as Markdown"
        panel.nameFieldStringValue = "\(StorageManager.slugify(meeting.displayTitle)).md"
        panel.canCreateDirectories = true
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        do {
            try SessionFormatter.getMarkdown(meeting, options: .all)
                .write(to: destination, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Meeting export failed: \(error.localizedDescription)"
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
