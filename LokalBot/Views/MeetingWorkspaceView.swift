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
        } else if !app.libraryReady, let error = app.libraryLoadError {
            ContentUnavailableView {
                Label("Meeting library unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { app.retryLibraryLoad() }
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
    @State private var artifactLoadError: String?
    @State private var isLoadingArtifacts = false
    @State private var isExportingAudio = false
    @State private var isExportingSpeech = false
    @State private var isReadingSummary = false
    @State private var speechPlayer: AVAudioPlayer?
    @State private var speechTask: Task<Void, Never>?
    @State private var searchQuery = ""
    @State private var searchMatches: [MeetingPageSearchMatch] = []
    @State private var selectedSearchMatchIndex = 0
    @State private var searchContentRevision = 0

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
                        focusRequest: app.meetingPageSearchRequestRevision,
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
                        meetingOverviewContent

                        if !captureTranscriptOnly {
                            outcomeSections
                        }

                        transcriptSection
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
            .onChange(of: projection) {
                if isSearchPresented {
                    updateSearch(using: scrollProxy)
                }
            }
        }
        .navigationTitle(meeting.displayTitle)
        .task(id: meeting.id) {
            await load()
#if LOKALBOT_UI_TEST_HOST
            if ProcessInfo.processInfo.environment["LOKALBOT_DETAIL_TAB"] == "transcript" {
                transcriptExpanded = true
            }
#endif
        }
        .onChange(of: app.navigationHandoff.revision) { consumeMeetingSeek() }
        .onChange(of: app.meetingPageSearchRequestRevision) {
            guard app.presentedMeetingSearchID == meeting.id else { return }
            uiTestDiagnosticLog(
                "meeting.search receive revision="
                    + "\(app.meetingPageSearchRequestRevision) id=\(meeting.id)")
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
        .meetingProcessingToolbar(app: app, meeting: meeting)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: presentSearch) {
                    Label("Find in Meeting", systemImage: "magnifyingglass")
                }
                .help("Find on this meeting page (⌘F)")
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

    @ViewBuilder private var meetingOverviewContent: some View {
        MeetingWorkspaceHeader(
            meeting: meeting,
            searchQuery: visibleSearchQuery,
            activeMatch: activeSearchMatch)

        if player.isLoaded {
            MeetingAudioBar(player: player, folder: folder)
        }
        if let stage = app.pipeline.stages[meeting.id] {
            processingStageContent(stage)
        }
        if let exportError {
            workspaceErrorLabel(
                exportError,
                icon: "exclamationmark.triangle",
                location: .exportError)
        }
        if let speechError {
            workspaceErrorLabel(
                speechError,
                icon: "speaker.slash",
                location: .speechError)
        }
        if let artifactLoadError {
            InlineIssueView(
                artifactLoadError,
                systemImage: "doc.badge.ellipsis",
                actionTitle: "Retry",
                font: .callout
            ) {
                Task { await load() }
            }
        } else if isLoadingArtifacts {
            LoadingStateLabel("Loading meeting artifacts…", font: .callout)
        }
    }

    private func processingStageContent(
        _ stage: ProcessingPipeline.Stage
    ) -> some View {
        HStack(spacing: 10) {
            Label {
                SearchHighlightedText(
                    stage.label,
                    query: visibleSearchQuery,
                    activeMatchIndex: activeOccurrence(at: .processingStatus))
                .id(MeetingPageSearchMatch.Location.processingStatus)
            } icon: {
                Image(systemName: stageIcon(stage))
            }
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

    private func workspaceErrorLabel(
        _ text: String,
        icon: String,
        location: MeetingPageSearchMatch.Location
    ) -> some View {
        Label {
            SearchHighlightedText(
                text,
                query: visibleSearchQuery,
                activeMatchIndex: activeOccurrence(at: location))
            .id(location)
        } icon: {
            Image(systemName: icon)
        }
        .font(.callout)
        .foregroundStyle(Brand.error)
    }

    @ViewBuilder private var outcomeSections: some View {
        actionItemsSection
        decisionsSection
        summarySection
    }

    private var actionItemsSection: some View {
        let actions = projection?.actionReferences ?? []
        return WorkspaceSection(
            title: "Action items",
            icon: "checklist",
            searchQuery: visibleSearchQuery,
            activeMatchIndex: activeOccurrence(at: .sectionHeader(.actionItems)),
            searchLocation: .sectionHeader(.actionItems)) {
            if actions.isEmpty {
                EmptyWorkspaceRow(
                    text: "No action items were extracted from this meeting.",
                    searchQuery: visibleSearchQuery,
                    activeMatchIndex: activeOccurrence(at: .emptyState(.actionItems)))
                .id(MeetingPageSearchMatch.Location.emptyState(.actionItems))
            } else {
                VStack(spacing: 0) {
                    ForEach(actions) { reference in
                        OutcomeActionRow(
                            reference: reference,
                            searchQuery: visibleSearchQuery,
                            activeMatch: activeSearchMatch,
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
            }
        }
    }

    private var decisionsSection: some View {
        let decisions = projection?.outcomes.decisionRecords ?? []
        return WorkspaceSection(
            title: "Decisions",
            icon: "checkmark.seal",
            searchQuery: visibleSearchQuery,
            activeMatchIndex: activeOccurrence(at: .sectionHeader(.decisions)),
            searchLocation: .sectionHeader(.decisions)) {
            if decisions.isEmpty {
                EmptyWorkspaceRow(
                    text: "No cited decisions were extracted.",
                    searchQuery: visibleSearchQuery,
                    activeMatchIndex: activeOccurrence(at: .emptyState(.decisions)))
                .id(MeetingPageSearchMatch.Location.emptyState(.decisions))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(decisions) { decision in
                        OutcomeDecisionRow(
                            decision: decision,
                            searchQuery: visibleSearchQuery,
                            activeMatch: activeSearchMatch) { citation in
                            transcriptExpanded = true
                            player.play(at: citation.start)
                        }
                    }
                }
            }
        }
    }

    private var summarySection: some View {
        WorkspaceSection(
            title: "Summary",
            icon: "text.alignleft",
            searchQuery: visibleSearchQuery,
            activeMatchIndex: activeOccurrence(at: .sectionHeader(.summary)),
            searchLocation: .sectionHeader(.summary)) {
            MeetingSummaryWorkspaceContent(
                notes: notes,
                summary: summary,
                searchQuery: visibleSearchQuery,
                activeMatch: activeSearchMatch)
        }
        .accessibilityIdentifier("meeting.summary")
    }

    private var transcriptSection: some View {
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
            Label {
                SearchHighlightedText(
                    "Transcript",
                    query: visibleSearchQuery,
                    activeMatchIndex: activeOccurrence(
                        at: .sectionHeader(.transcript)))
                .id(MeetingPageSearchMatch.Location.sectionHeader(.transcript))
            } icon: {
                Image(systemName: "text.bubble")
            }
            .font(WorkspaceTypography.sectionTitle)
        }
    }

    private func stageIcon(_ stage: ProcessingPipeline.Stage) -> String {
        if stage.isFailure { return "exclamationmark.triangle" }
        if stage.isWaitingForModels { return "arrow.down.circle" }
        return "sparkles"
    }

    private var visibleSearchQuery: String {
        isSearchPresented ? searchQuery : ""
    }

    private var isSearchPresented: Bool {
        app.presentedMeetingSearchID == meeting.id
    }

    private var activeSearchMatch: MeetingPageSearchMatch? {
        guard isSearchPresented,
              searchMatches.indices.contains(selectedSearchMatchIndex) else { return nil }
        return searchMatches[selectedSearchMatchIndex]
    }

    private var searchStatusText: String? {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
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
        app.requestSelectedMeetingSearch()
    }

    private func dismissSearch() {
        app.dismissMeetingSearch(for: meeting.id)
        searchQuery = ""
        searchMatches = []
        selectedSearchMatchIndex = 0
    }

    private func updateSearch(using scrollProxy: ScrollViewProxy) {
        let matches = MeetingPageSearch.matches(
            query: searchQuery,
            sources: searchSources)
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
        if match.location.requiresTranscriptExpansion {
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

    private var searchSources: [MeetingPageSearchSource] {
        MeetingWorkspaceSearchSourceBuilder.build(
            meeting: meeting,
            processingStatus: app.pipeline.stages[meeting.id]?.label,
            exportError: exportError,
            speechError: speechError,
            captureTranscriptOnly: captureTranscriptOnly,
            projection: projection,
            notes: notes,
            summary: summary,
            transcript: transcript)
    }

    private func load() async {
        isLoadingArtifacts = true
        let meetingFolder = folder
        let artifacts = await Task.detached(priority: .utility) {
            MeetingArtifactLoader.loadWorkspace(from: meetingFolder)
        }.value
        guard !Task.isCancelled else { return }
        summary = artifacts.summary
        notes = artifacts.notes
        transcript = artifacts.transcript
        artifactLoadError = artifacts.issues.isEmpty
            ? nil
            : artifacts.issues.map(\.message).joined(separator: " ")
        isLoadingArtifacts = false
        speakerNameHints = app.speakerNameHints(for: meeting)
        calendarSpeakerCandidates = meeting.resolvedCalendarParticipantIdentities
        uiTestDiagnosticLog(
            "meeting.load id=\(meeting.id) "
                + "calendarCandidates=\(calendarSpeakerCandidates.count)")
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
        uiTestDiagnosticLog(
            "beginRenameSpeaker speaker=\(speaker) "
                + "calendarCandidates=\(calendarSpeakerCandidates.count) "
                + "meetingCandidates=\(meeting.resolvedCalendarParticipantIdentities.count)")
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
            searchContentRevision += 1
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
