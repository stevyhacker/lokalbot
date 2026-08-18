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

    /// Nothing to act on means no card at all — an empty "Needs attention"
    /// section is dead weight on a glanceable page (the Timeline test pins the
    /// same rule for its day view).
    var body: some View {
        if !actions.isEmpty {
            WorkspaceSection(title: title, icon: "exclamationmark.circle") {
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
            .sheet(isPresented: $showingReview) {
                ActionReviewView(actions: actions)
                    .environmentObject(app)
            }
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
