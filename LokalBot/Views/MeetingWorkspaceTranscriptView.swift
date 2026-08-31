import SwiftUI

struct TranscriptEvidenceList: View {
    let transcript: Transcript?
    @ObservedObject var player: MeetingPlayer
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let onRenameSpeaker: (String) -> Void

    var body: some View {
        if let transcript, !transcript.segments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                transcriptEngine(transcript.engine)
                transcriptSegments(transcript)
            }
        } else {
            EmptyWorkspaceRow(
                text: "No transcript yet.",
                searchQuery: searchQuery,
                activeMatchIndex: activeMatch.occurrenceIndex(at: .emptyState(.transcript)))
            .id(MeetingPageSearchMatch.Location.emptyState(.transcript))
        }
    }

    @ViewBuilder private func transcriptEngine(_ engine: String) -> some View {
        if !engine.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundStyle(.tint)
                SearchHighlightedText(
                    transcriptEngineDescription(engine),
                    query: searchQuery,
                    activeMatchIndex: activeMatch.occurrenceIndex(at: .transcriptEngine))
                    .id(MeetingPageSearchMatch.Location.transcriptEngine)
            }
            .font(WorkspaceTypography.metadata)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary.opacity(0.24),
                in: RoundedRectangle(cornerRadius: Brand.Radius.control))
            .accessibilityIdentifier("transcript.model")
        }
    }

    private func transcriptSegments(_ transcript: Transcript) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                transcriptRow(segment, index: index, transcript: transcript)
            }
        }
    }

    private func transcriptRow(
        _ segment: Transcript.Segment,
        index: Int,
        transcript: Transcript
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                player.play(at: segment.start)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                    SearchHighlightedText(
                        Transcript.stamp(segment.start),
                        query: searchQuery,
                        activeMatchIndex: activeMatch.occurrenceIndex(
                            at: .transcript(segmentIndex: index, field: .timestamp)))
                        .id(MeetingPageSearchMatch.Location.transcript(
                            segmentIndex: index,
                            field: .timestamp))
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Play from \(Transcript.stamp(segment.start))")
            .accessibilityIdentifier("transcript.segment.\(index).play")
            TranscriptSpeakerButton(
                title: transcript.displaySpeaker(for: segment.speaker),
                query: searchQuery,
                activeMatchIndex: activeMatch.occurrenceIndex(
                    at: .transcript(segmentIndex: index, field: .speaker)),
                identifier: "transcript.segment.\(index).speaker") {
                    onRenameSpeaker(segment.speaker)
                }
                .id(MeetingPageSearchMatch.Location.transcript(
                    segmentIndex: index,
                    field: .speaker))
                .frame(width: 72, height: 20, alignment: .leading)
            SearchHighlightedText(
                segment.displayText,
                query: searchQuery,
                activeMatchIndex: activeMatch.occurrenceIndex(
                    at: .transcript(segmentIndex: index, field: .text)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help("Select text and press Command-C to copy")
                .accessibilityIdentifier("transcript.segment.\(index).text")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            isActive(segment) ? Brand.teal.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        .id(MeetingPageSearchMatch.Location.transcript(
            segmentIndex: index,
            field: .text))
    }

    private func isActive(_ segment: Transcript.Segment) -> Bool {
        player.currentTime >= segment.start
            && player.currentTime < max(segment.end, segment.start + 0.5)
    }
}
