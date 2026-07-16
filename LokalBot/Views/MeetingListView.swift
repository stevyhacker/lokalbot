import SwiftUI

/// The meeting library list — live recording first, then finished meetings
/// grouped by day. Capture's Library scope (spec §2.2: unchanged behavior —
/// multi-select, delete). The live row routes to `LiveMeetingDetailView`
/// via the shared selection. Deletion is confirmed by the host window's
/// dialog via `pendingDelete`.
struct MeetingListView: View {
    @EnvironmentObject var app: AppState
    @Binding var pendingDelete: Set<Meeting.ID>?

    var body: some View {
        List(selection: $app.selectedMeetingIDs) {
            ForEach(groupedMeetings, id: \.label) { group in
                Section {
                    ForEach(group.items) { meeting in
                        meetingRow(meeting).tag(meeting.id)
                    }
                } header: {
                    SectionHeader(text: group.label)
                }
            }
        }
        .accessibilityIdentifier("meeting.list")
        .overlay {
            if !app.libraryReady {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading your meeting library…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("meeting.libraryLoading")
            } else if groupedMeetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "waveform.circle",
                    description: Text("LokalBot detects meeting apps automatically — or choose Record now in the menu bar.")
                )
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

    @ViewBuilder
    private func meetingRow(_ meeting: Meeting) -> some View {
        if meeting.endedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                meetingRowContent(meeting, now: context.date)
            }
        } else {
            meetingRowContent(meeting, now: Date())
        }
    }

    private func meetingRowContent(_ meeting: Meeting, now: Date) -> some View {
        let live = meeting.endedAt == nil
        let time = live ? "in progress"
                        : meeting.startedAt.formatted(date: .omitted, time: .shortened)
        let duration = live ? "\(max(1, Int(now.timeIntervalSince(meeting.startedAt) / 60))) min"
                            : meeting.durationLabel
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if live { StatusDot(color: Brand.recording, size: 9) }
                    Text(meeting.title).font(.headline)
                    if live {
                        Spacer(minLength: 6)
                        LiveWaveform(barCount: 5, barWidth: 2.5, maxHeight: 10)
                    }
                }
                Text("\(meeting.appName) · \(time) · \(duration)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(meeting.title)
            .accessibilityIdentifier("meeting.row.\(meeting.id.uuidString)")

            if !live, let stage = app.pipeline.stages[meeting.id] {
                pipelineStatus(stage, meeting: meeting)
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func pipelineStatus(_ stage: ProcessingPipeline.Stage, meeting: Meeting) -> some View {
        if stage.isFailure {
            VStack(alignment: .trailing, spacing: 2) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Retry") {
                    app.retryProcessing(meeting)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .help(stage.label)
            .accessibilityIdentifier("meeting.retry.\(meeting.id.uuidString)")
        } else {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.75)
                Text(stage.rowLabel)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(stage.label)
            .accessibilityIdentifier("meeting.status.\(meeting.id.uuidString)")
        }
    }
}
