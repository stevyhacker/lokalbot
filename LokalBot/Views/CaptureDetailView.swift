import SwiftUI
import AppKit

/// The Timeline/Meetings detail pane — a selection-driven inspector (spec
/// §2.2): a selected meeting opens the unchanged `MeetingDetailView`, a
/// selected activity block gets its card + per-app context + block-scoped
/// screenshots, and no selection shows the day overview (stat tiles,
/// per-app proportion bar + totals, digest) in Timeline or an empty
/// state in Meetings.
struct CaptureDetailView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel
    @Binding var pendingDelete: Set<Meeting.ID>?

    @ViewBuilder
    var body: some View {
        if app.navSection == .timeline,
           let snapshotID = model.selectedSnapshotID,
           let screenshot = model.shots.first(where: { $0.id == snapshotID }) {
            ScreenMomentDetailView(
                screenshot: screenshot,
                onReload: { model.reload(app: app) },
                onClear: { model.selectedSnapshotID = nil })
                .id(snapshotID)
        } else {
            switch CaptureInspectorState.resolve(meetingIDs: app.selectedMeetingIDs,
                                                 blockSelection: model.selection,
                                                 allowsBlockSelection: app.navSection == .timeline) {
            case .meeting:
                if let meeting = app.selectedMeeting {
                    if meeting.endedAt == nil {
                        LiveMeetingDetailView(meeting: meeting)
                            .id(meeting.id)
                    } else {
                        MeetingDetailView(meeting: meeting)
                            .id(meeting.id)
                    }
                } else {
                    noSelection
                }
            case .multiSelection(let count):
                ContentUnavailableView {
                    Label("\(count) meetings selected", systemImage: "checklist")
                } description: {
                    Text("Press ⌫ or right-click to delete them.")
                } actions: {
                    Button("Delete \(count) meetings", role: .destructive) {
                        pendingDelete = app.selectedMeetingIDs
                    }
                }
            case .block:
                if let block = model.selectedBlock {
                    blockDetail(block)
                } else {
                    noSelection
                }
            case .overview:
                noSelection
            }
        }
    }

    /// Meetings shows the in-progress recording by default while one is
    /// running (the live view is the whole point of opening the app
    /// mid-meeting), an empty state otherwise (the getting-started card now
    /// lives on the Today home); Timeline shows the day overview.
    @ViewBuilder private var noSelection: some View {
        if app.navSection == .timeline {
            dayOverview
        } else if !app.libraryReady {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading your meeting library…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let live = app.currentMeeting {
            LiveMeetingDetailView(meeting: live)
                .id(live.id)
        } else {
            ContentUnavailableView {
                Label(app.meetings.isEmpty ? "No meetings yet" : "No meeting selected",
                      systemImage: "waveform.circle")
            } description: {
                Text(app.meetings.isEmpty
                     ? "Choose Record now to capture a meeting."
                     : "Select a meeting to open its summary and transcript.")
            } actions: {
                if app.meetings.isEmpty {
                    Button("Record now") {
                        app.startRecording(
                            context: app.recordingContext(for: app.detector.activeApp))
                    }
                }
            }
        }
    }

    // MARK: - Day overview (absorbs the old Totals + Digest tabs)

    private var dayOverview: some View {
        let meetings = model.meetings(in: app)
        let perApp = Dictionary(grouping: model.blocks, by: \.app)
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
            .sorted { $0.value > $1.value }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Day overview")
                    .font(.title3.bold())
                    .accessibilityIdentifier("capture.dayOverview")
                DayStatRow(
                    trackedSeconds: perApp.reduce(0) { $0 + $1.value },
                    appCount: perApp.count,
                    momentCount: model.shots.count,
                    meetingCount: meetings.count)
                if !perApp.isEmpty {
                    totalsSection(perApp)
                }
                Button {
                    app.openAsk(dayScope: model.day)
                } label: {
                    Label("Ask about this day", systemImage: "sparkle.magnifyingglass")
                }
                .accessibilityIdentifier("capture.askDay")
                Divider()
                digestSection
                    .frame(maxWidth: 860, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func totalsSection(_ perApp: [(key: String, value: TimeInterval)]) -> some View {
        let total = perApp.reduce(0) { $0 + $1.value }
        let segments = ProportionBarMath.segments(
            perApp: perApp.map { (label: $0.key, seconds: $0.value) })
        let rows = AppTimePresentation.rows(
            perApp: perApp.map { (label: $0.key, seconds: $0.value) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Where time went").font(.headline)
                Spacer()
                Text("\(CaptureStyle.hm(total)) tracked")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProportionBar(segments: segments.map {
                ($0, $0.label == "Other" ? Color(nsColor: .tertiaryLabelColor)
                                         : CaptureStyle.color(for: $0.label))
            })
            .padding(.vertical, 2)
            ForEach(rows, id: \.label) { row in
                let label = row.isOther
                    ? "Other (\(row.appCount) app\(row.appCount == 1 ? "" : "s"))"
                    : row.label
                totalsRow(
                    row.isOther ? Color(nsColor: .tertiaryLabelColor)
                                : CaptureStyle.color(for: row.label),
                    label,
                    row.seconds,
                    of: total)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private func totalsRow(_ swatch: Color, _ label: String, _ seconds: TimeInterval,
                           of total: TimeInterval) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: swatch, size: 9)
            Text(label).font(.body).lineLimit(1)
            Spacer()
            Text(CaptureStyle.hm(seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(String(format: "%2.0f%%", seconds / max(total, 1) * 100))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Day digest").font(.title3.bold())
                if model.generating { ProgressView().controlSize(.small) }
                Spacer()
                if let digest = model.digest {
                    Menu {
                        Button {
                            Task { await model.generateDigest(app: app) }
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.generating)
                        Divider()
                        Button { model.copyDigest(digest) } label: {
                            Label("Copy digest", systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("capture.dayDigest.copyAll")
                        Button { model.exportDigest(digest) } label: {
                            Label("Export Markdown", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(digestUpdatedHelp)
                    .accessibilityLabel("Day digest actions")
                } else {
                    Button("Generate digest") {
                        Task { await model.generateDigest(app: app) }
                    }
                    .disabled(model.generating)
                }
            }
            if model.digestIsStale {
                Label("Newer activity is available — regenerate to include it.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("capture.dayDigest.stale")
            }
            if let digestError = model.digestError {
                Label(digestError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let digest = model.digest {
                DayDigestView(digest, mode: .timeline)
                    .accessibilityIdentifier("capture.dayDigest.text")
            }
        }
    }

    private var digestUpdatedHelp: String {
        guard let updatedAt = model.digestUpdatedAt else { return "Day digest actions" }
        return "Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Activity block detail (card + per-app context + captured moments)

    private func blockDetail(_ block: ActivityBlock) -> some View {
        let scoped = model.shots.filter { $0.ts >= block.start && $0.ts <= block.end }
        let sameApp = model.blocks.filter { $0.app == block.app }
        let appTotal = sameApp.reduce(0) { $0 + $1.duration }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                blockCard(block)
                HStack(spacing: 8) {
                    StatTile(icon: "clock", value: CaptureStyle.hm(appTotal),
                             label: "in \(block.app) today")
                    StatTile(icon: "rectangle.stack", value: "\(sameApp.count)",
                             label: sameApp.count == 1 ? "block" : "blocks")
                }
                Text("Context moments (\(scoped.count))").font(.headline)
                if scoped.isEmpty {
                    Text("None during this block.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                        ForEach(scoped) { shot in
                            ScreenThumbnailView(screenshot: shot)
                                .help("\(shot.app) — \(shot.ts.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func blockCard(_ block: ActivityBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: CaptureStyle.color(for: block.app), size: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.app).font(.subheadline.weight(.semibold))
                if !block.title.isEmpty {
                    Text(block.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(CaptureStyle.hm(block.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { model.selection = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Clear selection")
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }
}
