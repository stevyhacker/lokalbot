import Foundation

/// Converts workspace content into independently addressable search sources.
/// Keeping this assembly out of the SwiftUI view makes the view declarative
/// and gives each outcome section one small, testable formatter.
struct MeetingWorkspaceSearchSourceBuilder {
    private let meeting: Meeting
    private let processingStatus: String?
    private let exportError: String?
    private let speechError: String?
    private let captureTranscriptOnly: Bool
    private let projection: MeetingOutcomeProjection?
    private let notes: String?
    private let summary: String?
    private let transcript: Transcript?
    private var sources: [MeetingPageSearchSource] = []

    static func build(
        meeting: Meeting,
        processingStatus: String?,
        exportError: String?,
        speechError: String?,
        captureTranscriptOnly: Bool,
        projection: MeetingOutcomeProjection?,
        notes: String?,
        summary: String?,
        transcript: Transcript?
    ) -> [MeetingPageSearchSource] {
        var builder = Self(
            meeting: meeting,
            processingStatus: processingStatus,
            exportError: exportError,
            speechError: speechError,
            captureTranscriptOnly: captureTranscriptOnly,
            projection: projection,
            notes: notes,
            summary: summary,
            transcript: transcript)
        return builder.build()
    }

    private mutating func build() -> [MeetingPageSearchSource] {
        appendOverview()
        if !captureTranscriptOnly {
            appendActions()
            appendDecisions()
            appendSummary()
        }
        appendTranscript()
        return sources
    }

    private mutating func appendOverview() {
        append(meeting.displayTitle, at: .title)
        for item in meetingWorkspaceMetadataItems(for: meeting) {
            append(item.text, at: .meetingMetadata(item.field))
        }
        append(processingStatus, at: .processingStatus)
        append(exportError, at: .exportError)
        append(speechError, at: .speechError)
    }

    private mutating func appendActions() {
        append("Action items", at: .sectionHeader(.actionItems))
        let actions = projection?.actionReferences ?? []
        guard !actions.isEmpty else {
            append(
                "No action items were extracted from this meeting.",
                at: .emptyState(.actionItems))
            return
        }
        for reference in actions {
            let id = reference.action.id
            append(reference.text, at: .action(id: id, field: .text))
            append(reference.owner ?? "Unassigned", at: .action(id: id, field: .owner))
            append(reference.due, at: .action(id: id, field: .due))
            append(
                reference.action.citations.first.map { Transcript.stamp($0.start) },
                at: .action(id: id, field: .evidence))
        }
    }

    private mutating func appendDecisions() {
        append("Decisions", at: .sectionHeader(.decisions))
        let decisions = projection?.outcomes.decisionRecords ?? []
        guard !decisions.isEmpty else {
            append("No cited decisions were extracted.", at: .emptyState(.decisions))
            return
        }
        for decision in decisions {
            append(decision.displayText, at: .decision(id: decision.id, field: .text))
            append(
                decision.citations.first.map { Transcript.stamp($0.start) },
                at: .decision(id: decision.id, field: .evidence))
        }
    }

    private mutating func appendSummary() {
        append("Summary", at: .sectionHeader(.summary))
        guard notes?.isEmpty == false || summary?.isEmpty == false else {
            append("No summary yet.", at: .emptyState(.summary))
            return
        }
        appendNotes()
        appendGeneratedSummary()
    }

    private mutating func appendNotes() {
        guard let notes, !notes.isEmpty else { return }
        append("Your notes", at: .notesLabel)
        append(SelectableDigestText.searchableText(from: notes), at: .notes)
    }

    private mutating func appendGeneratedSummary() {
        guard let summary, !summary.isEmpty else { return }
        let parts = SummaryPresentation.split(summary)
        if !parts.metadata.isEmpty {
            append(
                SummaryMetadataRow.displayText(for: parts.metadata),
                at: .summaryMetadata)
        }
        append(SelectableDigestText.searchableText(from: parts.body), at: .summary)
    }

    private mutating func appendTranscript() {
        append("Transcript", at: .sectionHeader(.transcript))
        guard let transcript, !transcript.segments.isEmpty else {
            append("No transcript yet.", at: .emptyState(.transcript))
            return
        }
        if !transcript.engine.isEmpty {
            append(transcriptEngineDescription(transcript.engine), at: .transcriptEngine)
        }
        for (index, segment) in transcript.segments.enumerated() {
            append(
                Transcript.stamp(segment.start),
                at: .transcript(segmentIndex: index, field: .timestamp))
            append(
                transcript.displaySpeaker(for: segment.speaker),
                at: .transcript(segmentIndex: index, field: .speaker))
            append(
                segment.displayText,
                at: .transcript(segmentIndex: index, field: .text))
        }
    }

    private mutating func append(
        _ text: String?,
        at location: MeetingPageSearchMatch.Location
    ) {
        guard let text, !text.isEmpty else { return }
        sources.append(.init(location: location, text: text))
    }
}
