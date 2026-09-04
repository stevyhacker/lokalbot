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
                Button("Review all \(actions.count) actions") {
                    app.openActions()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("outcomes.review")
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
            .accessibilityLabel(reference.status == .done ? "Reopen action" : "Complete action")
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
                        Text(ActionDuePresentation.label(due, spokenAt: reference.meetingStartedAt))
                            .font(WorkspaceTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    if let citation = reference.action.citations.first {
                        EvidencePill(citation: citation) {
                            app.openMeeting(reference.meetingID, seek: citation.start)
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
