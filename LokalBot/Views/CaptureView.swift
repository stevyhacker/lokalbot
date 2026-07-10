import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Timeline section — the hour-indexed day track with meetings rendered
/// as first-class teal blocks beside app-colored activity blocks. Meetings
/// live in their own sidebar section (`MeetingListView`); both share
/// `CaptureModel`, and the detail pane (`CaptureDetailView`) is
/// selection-driven.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var day = Date()
    @Published var blocks: [ActivityBlock] = []
    @Published var shots: [ActivityStore.Screenshot] = []
    @Published var selection: ActivityBlock.ID?
    @Published var digest: String?
    @Published var generating = false
    @Published var digestError: String?

    var selectedBlock: ActivityBlock? {
        guard let selection else { return nil }
        return blocks.first { $0.id == selection }
    }

    func moveDay(by value: Int) {
        day = Calendar.current.date(byAdding: .day, value: value, to: day)
            ?? day.addingTimeInterval(TimeInterval(value) * 86_400)
    }

    func reload(app: AppState) {
        blocks = app.activityStore.blocks(on: day)
        shots = app.activityStore.screenshots(on: day)
        digest = try? String(contentsOf: journalURL(app: app), encoding: .utf8)
        digestError = nil
        selection = nil
    }

    /// The selected day's meetings, live recording included, for the track
    /// and the overview stats.
    func meetings(in app: AppState) -> [Meeting] {
        ((app.currentMeeting.map { [$0] } ?? []) + app.meetings)
            .filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
    }

    private func journalURL(app: AppState) -> URL {
        let name = day.formatted(.iso8601.year().month().day())
        return app.storage.rootURL.appendingPathComponent("journal/\(name).md")
    }

    func generateDigest(app: AppState) async {
        generating = true
        defer { generating = false }
        let todays = meetings(in: app).filter { $0.endedAt != nil }
        let ocr = app.activityStore.ocrText(on: day)
        do {
            let (text, _) = try await app.pipeline.generateDayDigest(
                for: day, blocks: blocks, meetings: todays, ocr: ocr, config: app.settings)
            digest = text
        } catch {
            digestError = error.localizedDescription
        }
    }

    /// Copy the raw digest Markdown to the clipboard. The rendered text is
    /// selectable too, but one click grabs the whole document without a
    /// fiddly multi-line drag across the per-line Markdown layout.
    func copyDigest(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Export the digest to a user-chosen `.md` file via the standard save
    /// panel. The digest is already auto-saved to `journal/<date>.md`; this
    /// drops a shareable copy wherever the user picks.
    func exportDigest(_ text: String) {
        let panel = NSSavePanel()
        panel.title = "Export Day Digest"
        panel.nameFieldStringValue = "\(day.formatted(.iso8601.year().month().day())).md"
        panel.canCreateDirectories = true
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            digestError = "Export failed — \(error.localizedDescription)"
        }
    }
}

/// Shared Capture styling helpers (block colors, duration labels).
enum CaptureStyle {
    /// Stable per-app color from the name hash.
    static func color(for app: String) -> Color {
        var hash: UInt64 = 5381
        for byte in app.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.78)
    }

    static func hm(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

// MARK: - Content column — the day track

struct TimelineContentView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel

    var body: some View {
        CaptureDayView(model: model)
            .navigationTitle("Timeline")
            .task(id: model.day.formatted(date: .numeric, time: .omitted)) {
                model.reload(app: app)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        app.sampler.isPaused.toggle()
                    } label: {
                        Label(app.sampler.isPaused ? "Resume Tracking" : "Pause Tracking",
                              systemImage: app.sampler.isPaused ? "play.fill" : "pause.fill")
                    }
                    Button {
                        model.reload(app: app)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
    }
}

// MARK: - Day view — header, summary rail, hour track

struct CaptureDayView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel

    var body: some View {
        let meetings = model.meetings(in: app)
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.blocks.isEmpty && meetings.isEmpty {
                ContentUnavailableView(
                    "No activity recorded",
                    systemImage: "clock",
                    description: Text(app.settings.trackingEnabled
                        ? "Blocks appear as you use your Mac (sampled every 5 s, idle-aware)."
                        : "Day tracking is off — enable it in Settings."))
                    .frame(maxHeight: .infinity)
            } else {
                summaryRail(meetings: meetings)
                Divider()
                if meetings.contains(where: { $0.endedAt == nil }) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        captureTrack(meetings: meetings, now: context.date)
                    }
                } else {
                    captureTrack(meetings: meetings, now: Date())
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func captureTrack(meetings: [Meeting], now: Date) -> some View {
        CaptureTrackView(
            items: CaptureTrackItem.items(blocks: model.blocks,
                                          meetings: meetings,
                                          now: now),
            blockSelection: model.selection,
            selectedMeetingIDs: app.selectedMeetingIDs,
            onSelectBlock: { id in
                model.selection = id
                if id != nil { app.selectedMeetingIDs = [] }
            },
            onSelectMeeting: { id in
                model.selection = nil
                app.selectedMeetingIDs = app.selectedMeetingIDs == [id] ? [] : [id]
            })
            .accessibilityIdentifier("timeline.track")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.moveDay(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous day")
            DatePicker("", selection: $model.day, displayedComponents: .date)
                .labelsHidden().fixedSize()
            Button { model.moveDay(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next day")
            .disabled(Calendar.current.isDateInToday(model.day))
            Spacer()
        }
    }

    private func summaryRail(meetings: [Meeting]) -> some View {
        let total = model.blocks.reduce(0) { $0 + $1.duration }
        let apps = Set(model.blocks.map(\.app)).count
        return HStack(spacing: 8) {
            StatTile(icon: "clock", value: CaptureStyle.hm(total), label: "tracked")
            StatTile(icon: "square.grid.2x2", value: "\(apps)", label: apps == 1 ? "app" : "apps")
            StatTile(icon: "camera.viewfinder", value: "\(model.shots.count)", label: "screens")
            if !meetings.isEmpty {
                StatTile(icon: "waveform", value: "\(meetings.count)",
                         label: meetings.count == 1 ? "meeting" : "meetings")
            }
            Spacer()
        }
    }
}

/// Vertical, hour-indexed track (calendar day-view metaphor). Meetings get a
/// dedicated teal lane on the left edge of the block area so they never
/// occlude the activity blocks they overlap (a meeting and its app's
/// activity cover the same minutes); activity blocks keep the remaining lane
/// width. With no meetings, activity blocks span the full lane as before.
private struct CaptureTrackView: View {
    let items: [CaptureTrackItem]
    let blockSelection: ActivityBlock.ID?
    let selectedMeetingIDs: Set<Meeting.ID>
    let onSelectBlock: (ActivityBlock.ID?) -> Void
    let onSelectMeeting: (Meeting.ID) -> Void

    private let pointsPerHour: CGFloat = 100
    private let gutter: CGFloat = 56

    private var hasMeetings: Bool {
        items.contains { if case .meeting = $0 { return true }; return false }
    }

    var body: some View {
        let start = trackStart
        let hours = hourCount(from: start)
        let height = CGFloat(hours) * pointsPerHour
        ScrollView {
            GeometryReader { geo in
                let laneWidth = max(40, geo.size.width - gutter)
                let meetingLane = hasMeetings ? max(96, laneWidth * 0.28) : 0
                let activityX = gutter + (meetingLane > 0 ? meetingLane + 6 : 0)
                let activityWidth = max(40, laneWidth - (meetingLane > 0 ? meetingLane + 6 : 0))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(0..<hours), id: \.self) { i in
                        let y = CGFloat(i) * pointsPerHour
                        Rectangle().fill(.quaternary.opacity(0.4))
                            .frame(width: laneWidth, height: 1)
                            .offset(x: gutter, y: y)
                        Text(hourLabel(start, i))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: gutter - 8, alignment: .trailing)
                            .offset(y: y - 6)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .activity(let block):
                            activityView(block, start: start, x: activityX, width: activityWidth)
                        case .meeting(let meeting, let end):
                            meetingView(meeting, end: end, start: start,
                                        x: gutter, width: max(96, meetingLane))
                        }
                    }
                }
                .frame(width: geo.size.width, height: height, alignment: .topLeading)
            }
            .frame(height: height)
        }
    }

    @ViewBuilder
    private func activityView(_ block: ActivityBlock, start: Date,
                              x: CGFloat, width: CGFloat) -> some View {
        let y = CGFloat(block.start.timeIntervalSince(start) / 3600) * pointsPerHour
        let h = max(5, CGFloat(block.duration / 3600) * pointsPerHour)
        let isSelected = blockSelection == block.id
        RoundedRectangle(cornerRadius: 4)
            .fill(CaptureStyle.color(for: block.app).opacity(isSelected ? 1 : 0.85))
            .overlay(alignment: .topLeading) {
                if h >= 20 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(block.app).font(.caption.weight(.medium)).lineLimit(1)
                        if !block.title.isEmpty && h >= 38 {
                            Text(block.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6).padding(.top, 3)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: width, height: h, alignment: .topLeading)
            .offset(x: x, y: y)
            .help("\(block.app)\(block.title.isEmpty ? "" : " — \(block.title)")\n\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(CaptureStyle.hm(block.duration))")
            .onTapGesture { onSelectBlock(isSelected ? nil : block.id) }
    }

    @ViewBuilder
    private func meetingView(_ meeting: Meeting, end: Date, start: Date,
                             x: CGFloat, width: CGFloat) -> some View {
        let y = CGFloat(meeting.startedAt.timeIntervalSince(start) / 3600) * pointsPerHour
        let duration = end.timeIntervalSince(meeting.startedAt)
        let h = max(24, CGFloat(duration / 3600) * pointsPerHour)
        let isSelected = selectedMeetingIDs == [meeting.id]
        RoundedRectangle(cornerRadius: 4)
            .fill(Brand.teal.opacity(isSelected ? 1 : 0.85))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform").font(.caption2)
                        Text(meeting.title).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    if h >= 38 {
                        Text(meeting.durationLabel).font(.caption2).opacity(0.8)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.top, 4)
            }
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: width, height: h, alignment: .topLeading)
            .offset(x: x, y: y)
            .help("\(meeting.title)\n\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) · \(meeting.durationLabel)")
            .onTapGesture { onSelectMeeting(meeting.id) }
            .accessibilityIdentifier("capture.meeting.\(meeting.id.uuidString)")
    }

    private var trackStart: Date {
        let first = items.first?.start ?? Calendar.current.startOfDay(for: Date())
        return Calendar.current.dateInterval(of: .hour, for: first)?.start ?? first
    }

    private func hourCount(from start: Date) -> Int {
        let last = items.map(\.end).max() ?? start.addingTimeInterval(3600)
        return max(1, Int(ceil(last.timeIntervalSince(start) / 3600)))
    }

    private func hourLabel(_ start: Date, _ i: Int) -> String {
        start.addingTimeInterval(Double(i) * 3600).formatted(date: .omitted, time: .shortened)
    }
}
