import SwiftUI

/// The meeting library list — live recording first, then finished meetings
/// grouped by day. Capture's Library scope (spec §2.2: unchanged behavior —
/// multi-select, delete, the live-recording overlay). Deletion is confirmed
/// by the host window's dialog via `pendingDelete`.
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
        .overlay(alignment: .topTrailing) {
            if app.isRecording {
                HStack(spacing: 6) {
                    StatusDot(color: Brand.recording, size: 7)
                    Text("recording…").font(.caption)
                    LiveWaveform(barCount: 5, barWidth: 2.5, maxHeight: 10)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .hudCapsule()
                .padding(10)
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

    private func meetingRow(_ meeting: Meeting) -> some View {
        let live = meeting.endedAt == nil
        let time = live ? "in progress"
                        : meeting.startedAt.formatted(date: .omitted, time: .shortened)
        let duration = live ? "\(max(1, Int(Date().timeIntervalSince(meeting.startedAt) / 60))) min"
                            : meeting.durationLabel
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if live { StatusDot(color: Brand.recording, size: 9) }
                Text(meeting.title).font(.headline)
            }
            Text("\(meeting.appName) · \(time) · \(duration)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meeting.title)
        .accessibilityIdentifier("meeting.row.\(meeting.id.uuidString)")
    }
}
