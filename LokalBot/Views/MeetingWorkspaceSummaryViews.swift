import SwiftUI

struct MeetingSummaryWorkspaceContent: View {
    let notes: String?
    let summary: String?
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?

    var body: some View {
        if notes?.isEmpty == false || summary?.isEmpty == false {
            VStack(alignment: .leading, spacing: 14) {
                if let notes, !notes.isEmpty {
                    notesContent(notes)
                }
                if let summary, !summary.isEmpty {
                    summaryContent(summary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .workspaceReadingWidth()
        } else {
            EmptyWorkspaceRow(
                text: "No summary yet.",
                searchQuery: searchQuery,
                activeMatchIndex: activeMatch.occurrenceIndex(at: .emptyState(.summary)))
            .id(MeetingPageSearchMatch.Location.emptyState(.summary))
        }
    }

    private func notesContent(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                SearchHighlightedText(
                    "Your notes",
                    query: searchQuery,
                    activeMatchIndex: activeMatch.occurrenceIndex(at: .notesLabel))
                .id(MeetingPageSearchMatch.Location.notesLabel)
            } icon: {
                Image(systemName: "square.and.pencil")
            }
            .font(WorkspaceTypography.metadataEmphasis)
            .foregroundStyle(.secondary)
            SelectableDigestText(
                notes,
                searchQuery: searchQuery,
                activeMatchIndex: activeMatch.occurrenceIndex(at: .notes))
            .id(MeetingPageSearchMatch.Location.notes)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.24),
            in: RoundedRectangle(cornerRadius: Brand.Radius.control))
        .accessibilityIdentifier("detail.notes")
    }

    @ViewBuilder private func summaryContent(_ summary: String) -> some View {
        let parts = SummaryPresentation.split(summary)
        if !parts.metadata.isEmpty {
            SummaryMetadataRow(
                items: parts.metadata,
                searchQuery: searchQuery,
                activeMatchIndex: activeMatch.occurrenceIndex(at: .summaryMetadata))
            .id(MeetingPageSearchMatch.Location.summaryMetadata)
        }
        SelectableDigestText(
            parts.body,
            searchQuery: searchQuery,
            activeMatchIndex: activeMatch.occurrenceIndex(at: .summary))
        .id(MeetingPageSearchMatch.Location.summary)
    }
}

struct MeetingPageSearchBar: View {
    @Binding var query: String
    let focusRequest: Int
    let statusText: String?
    let hasMatches: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            MeetingSearchTextField(
                text: $query,
                focusRequest: focusRequest,
                onSubmit: onNext,
                onCancel: onClose)
                .frame(maxWidth: .infinity)
                .frame(height: 20)

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

            if let statusText {
                Text(statusText)
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("meeting.search.status")
            }

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
        .onAppear {
            uiTestDiagnosticLog("meeting.search bar appear")
        }
        .font(WorkspaceTypography.control)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .workspaceControl()
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.search.bar")
    }
}

struct MeetingWorkspaceMetadataItem {
    let field: MeetingPageSearchMatch.MeetingMetadataField
    let icon: String
    let text: String
}

func meetingWorkspaceMetadataItems(
    for meeting: Meeting
) -> [MeetingWorkspaceMetadataItem] {
    [
        .init(
            field: .date,
            icon: "calendar",
            text: meeting.startedAt.formatted(date: .abbreviated, time: .shortened)),
        .init(field: .duration, icon: "clock", text: meeting.durationLabel),
        .init(field: .app, icon: "video", text: meeting.appName),
        .init(
            field: .audioSource,
            icon: meeting.hasSystemTrack ? "speaker.wave.2.fill" : "mic.fill",
            text: meeting.hasSystemTrack ? "Mic + system" : "Mic only"),
    ]
}

func transcriptEngineDescription(_ engine: String) -> String {
    "Transcribed with \(engine)"
}

struct MeetingWorkspaceHeader: View {
    let meeting: Meeting
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchHighlightedText(
                meeting.displayTitle,
                query: searchQuery,
                activeMatchIndex: activeMatch.occurrenceIndex(at: .title))
                .id(MeetingPageSearchMatch.Location.title)
                .font(WorkspaceTypography.display)
                .accessibilityIdentifier("detail.title")
            HStack(spacing: 7) {
                ForEach(meetingWorkspaceMetadataItems(for: meeting), id: \.field) { item in
                    MeetingSearchChip(
                        icon: item.icon,
                        text: item.text,
                        searchQuery: searchQuery,
                        activeMatchIndex: activeMatch.occurrenceIndex(
                            at: .meetingMetadata(item.field)),
                        location: .meetingMetadata(item.field))
                }
            }
        }
    }
}

struct MeetingSearchChip: View {
    var icon: String?
    let text: String
    var size: ChipSize = .regular
    let searchQuery: String
    let activeMatchIndex: Int?
    let location: MeetingPageSearchMatch.Location

    var body: some View {
        Group {
            if let icon {
                Label {
                    highlightedText
                } icon: {
                    Image(systemName: icon)
                }
                .labelStyle(.titleAndIcon)
            } else {
                highlightedText
            }
        }
        .font(size.font.monospacedDigit())
        .foregroundStyle(.secondary)
        .chipChrome(size)
    }

    private var highlightedText: some View {
        SearchHighlightedText(
            text,
            query: searchQuery,
            activeMatchIndex: activeMatchIndex)
            .id(location)
    }
}

struct MeetingAudioBar: View {
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
