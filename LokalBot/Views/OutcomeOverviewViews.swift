import SwiftUI

/// Shared outcome-first building blocks used by Today and Timeline. They read
/// the same `OutcomeIndex` as Meetings, so status changes are immediately
/// reflected everywhere without modifying extracted source files.
struct NeedsAttentionSection: View {
    @EnvironmentObject var app: AppState
    let actions: [OutcomeActionReference]
    var title = "Needs attention"
    var limit = 4
    @Binding var showingReview: Bool

    var body: some View {
        WorkspaceSection(title: title, icon: "exclamationmark.circle") {
            if actions.isEmpty {
                EmptyWorkspaceRow(text: "No open items assigned to you.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(actions.prefix(limit))) { reference in
                        OutcomeOverviewActionRow(reference: reference)
                        if reference.id != actions.prefix(limit).last?.id { Divider() }
                    }
                }
                Button("Review \(actions.count) open item\(actions.count == 1 ? "" : "s")") {
                    showingReview = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("outcomes.review")
            }
        }
        .sheet(isPresented: $showingReview) {
            ActionReviewView(actions: actions)
                .environmentObject(app)
        }
    }
}

struct OutcomeOverviewActionRow: View {
    @EnvironmentObject var app: AppState
    let reference: OutcomeActionReference

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                set(reference.status == .done ? .open : .done)
            } label: {
                Image(systemName: reference.status == .done
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reference.status == .done ? Brand.teal : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("outcome.action.toggle.\(reference.id)")
            VStack(alignment: .leading, spacing: 4) {
                Text(reference.text)
                    .font(WorkspaceTypography.bodyEmphasis)
                    .strikethrough(reference.status == .done)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Button(reference.meetingTitle) { app.openMeeting(reference.meetingID) }
                        .buttonStyle(.plain)
                        .font(WorkspaceTypography.metadata)
                        .foregroundStyle(Brand.teal)
                    if let due = reference.due {
                        Text("Due \(due)")
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    if let citation = reference.action.citations.first {
                        EvidencePill(citation: citation) {
                            app.pendingSeek = citation.start
                            app.openMeeting(reference.meetingID)
                        }
                    }
                }
            }
            Menu {
                ForEach(OutcomeStatus.allCases, id: \.rawValue) { status in
                    Button(status.label) { set(status) }
                }
                Divider()
                Button("Open meeting") { app.openMeeting(reference.meetingID) }
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
            .accessibilityIdentifier("outcome.action.status.\(reference.id)")
        }
        .padding(.vertical, WorkspaceMetric.rowVerticalPadding)
        .accessibilityIdentifier("outcome.action.\(reference.id)")
    }

    private func set(_ status: OutcomeStatus) {
        _ = app.outcomeIndex.setStatus(
            status,
            actionID: reference.action.id,
            meetingID: reference.meetingID)
    }
}

struct ActionReviewView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let actions: [OutcomeActionReference]
    @State private var status: OutcomeStatus = .open

    private var visible: [OutcomeActionReference] {
        let all = app.outcomeIndex.all.flatMap(\.actionReferences).filter(\.isForUser)
        return all.filter { $0.status == status }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Review action items").font(WorkspaceTypography.pageTitle)
                    Text("Status is stored locally and never changes the extracted source.")
                        .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            Picker("Status", selection: $status) {
                ForEach(OutcomeStatus.allCases, id: \.rawValue) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            List(visible) { reference in
                OutcomeOverviewActionRow(reference: reference)
            }
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView("No \(status.label.lowercased()) items",
                                           systemImage: "checklist")
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

struct TimelineOutcomeView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: CaptureModel
    @Binding var pendingDelete: Set<Meeting.ID>?
    @State private var showingReview = false
    @State private var activityExpanded = false

    private var dayActions: [OutcomeActionReference] {
        app.outcomeIndex.openUserActions.filter {
            Calendar.current.isDate($0.meetingStartedAt, inSameDayAs: model.day)
        }
    }

    private var dayDecisions: [(meeting: Meeting, decision: MeetingOutcomes.Decision)] {
        app.outcomeIndex.recentDecisions.filter {
            Calendar.current.isDate($0.meeting.startedAt, inSameDayAs: model.day)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceMetric.sectionGap) {
                header
                NeedsAttentionSection(
                    actions: dayActions,
                    title: "Needs attention",
                    showingReview: $showingReview)

                WorkspaceSection(title: "Decisions", icon: "checkmark.seal") {
                    if dayDecisions.isEmpty {
                        EmptyWorkspaceRow(text: "No cited decisions for this day.")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(dayDecisions.prefix(6), id: \.decision.id) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Image(systemName: "checkmark").foregroundStyle(Brand.teal)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.decision.text)
                                        Button(item.meeting.displayTitle) {
                                            app.openMeeting(item.meeting.id)
                                        }
                                        .buttonStyle(.plain)
                                        .font(WorkspaceTypography.metadata)
                                        .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if let citation = item.decision.citations.first {
                                        EvidencePill(citation: citation) {
                                            app.pendingSeek = citation.start
                                            app.openMeeting(item.meeting.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                WorkspaceDisclosure(
                    isExpanded: $activityExpanded,
                    identifier: "timeline.activityEvidence") {
                    VStack(spacing: 12) {
                        TimelineContentView(model: model)
                            .frame(minHeight: 460)
                        CaptureDetailView(model: model, pendingDelete: $pendingDelete)
                            .frame(minHeight: 360)
                    }
                } label: {
                    HStack {
                        Label("Activity evidence", systemImage: "calendar.day.timeline.left")
                            .font(WorkspaceTypography.sectionTitle)
                        Spacer()
                        Text("\(model.blocks.count) blocks · \(model.shots.count) moments")
                            .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: WorkspaceMetric.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Timeline")
        .task(id: app.navSection) {
            if app.navSection == .timeline { model.selectDay(model.day, app: app) }
        }
        .onChange(of: app.pendingScreenSnapshotID) { _, id in
            if id != nil { activityExpanded = true }
        }
        .accessibilityIdentifier("timeline.outcomes")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.day.formatted(date: .complete, time: .omitted))
                    .font(WorkspaceTypography.display)
                HStack(spacing: 7) {
                    StatTile(icon: "clock", value: CaptureStyle.hm(
                        model.blocks.reduce(0) { $0 + $1.duration }), label: "tracked")
                    StatTile(icon: "waveform", value: "\(model.meetings(in: app).count)",
                             label: "meetings")
                    StatTile(icon: "camera", value: "\(model.shots.count)", label: "moments")
                }
            }
            Spacer()
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous day")
                .accessibilityIdentifier("timeline.previousDay")
            Button("Today") { selectDay(Date()) }
                .accessibilityIdentifier("timeline.today")
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDateInToday(model.day))
                .accessibilityLabel("Next day")
                .accessibilityIdentifier("timeline.nextDay")
            Button {
                app.openAsk(dayScope: model.day)
            } label: {
                Label("Ask", systemImage: "sparkle.magnifyingglass")
            }
        }
    }

    private func shiftDay(_ value: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: value, to: model.day) else {
            return
        }
        selectDay(date)
    }

    private func selectDay(_ date: Date) {
        app.selectedMeetingIDs = []
        model.selectDay(date, app: app)
    }
}
