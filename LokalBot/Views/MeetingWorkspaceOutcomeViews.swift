import SwiftUI

struct OutcomeActionRow: View {
    @EnvironmentObject var app: AppState
    let reference: OutcomeActionReference
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let onStatus: (OutcomeStatus) -> Void
    let onCorrect: () -> Void
    let onEvidence: (OutcomeSourceCitation) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { onStatus(reference.status == .done ? .open : .done) } label: {
                Image(systemName: reference.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(reference.status == .done ? Brand.teal : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meeting.action.toggle.\(reference.action.id)")
            VStack(alignment: .leading, spacing: 5) {
                SearchHighlightedText(
                    reference.text,
                    query: searchQuery,
                    activeMatchIndex: activeOccurrence(for: .text))
                    .id(MeetingPageSearchMatch.Location.action(
                        id: reference.action.id,
                        field: .text))
                    .font(WorkspaceTypography.body)
                    .strikethrough(reference.status == .done)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("meeting.action.text.\(reference.action.id)")
                HStack(spacing: 7) {
                    Button(action: onCorrect) {
                        SearchHighlightedText(
                            reference.owner ?? "Unassigned",
                            query: searchQuery,
                            activeMatchIndex: activeOccurrence(for: .owner))
                            .id(MeetingPageSearchMatch.Location.action(
                                id: reference.action.id,
                                field: .owner))
                    }
                        .buttonStyle(.plain)
                        .font(WorkspaceTypography.metadataEmphasis)
                        .foregroundStyle(.secondary)
                    if let due = reference.due {
                        MeetingSearchChip(
                            icon: "calendar",
                            text: due,
                            size: .compact,
                            searchQuery: searchQuery,
                            activeMatchIndex: activeOccurrence(for: .due),
                            location: .action(
                                id: reference.action.id,
                                field: .due))
                    }
                    if let citation = reference.action.citations.first {
                        EvidencePill(
                            citation: citation,
                            searchQuery: searchQuery,
                            activeMatchIndex: activeOccurrence(for: .evidence),
                            searchLocation: .action(
                                id: reference.action.id,
                                field: .evidence)) {
                            onEvidence(citation)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(OutcomeStatus.allCases, id: \.rawValue) { status in
                    Button(status.label) { onStatus(status) }
                }
                Divider()
                Button("Correct owner or due date", action: onCorrect)
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
            .accessibilityIdentifier("meeting.action.status.\(reference.action.id)")
        }
        .padding(.vertical, WorkspaceMetric.rowVerticalPadding)
    }

    private func activeOccurrence(
        for field: MeetingPageSearchMatch.ActionField
    ) -> Int? {
        activeMatch.occurrenceIndex(at: .action(
            id: reference.action.id,
            field: field))
    }
}

struct OutcomeDecisionRow: View {
    let decision: MeetingOutcomes.Decision
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let onEvidence: (OutcomeSourceCitation) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark")
                .foregroundStyle(Brand.teal)
            SearchHighlightedText(
                decision.displayText,
                query: searchQuery,
                activeMatchIndex: activeOccurrence(for: .text))
                .id(MeetingPageSearchMatch.Location.decision(
                    id: decision.id,
                    field: .text))
                .font(WorkspaceTypography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let citation = decision.citations.first {
                EvidencePill(
                    citation: citation,
                    searchQuery: searchQuery,
                    activeMatchIndex: activeOccurrence(for: .evidence),
                    searchLocation: .decision(
                        id: decision.id,
                        field: .evidence)) {
                    onEvidence(citation)
                }
            }
        }
    }

    private func activeOccurrence(
        for field: MeetingPageSearchMatch.DecisionField
    ) -> Int? {
        activeMatch.occurrenceIndex(at: .decision(
            id: decision.id,
            field: field))
    }
}

struct ActionCorrectionDraft: Identifiable {
    let id = UUID()
    let actionID: String
    let originalText: String
    var text: String
    var owner: String
    var due: String

    init(reference: OutcomeActionReference) {
        actionID = reference.action.id
        originalText = reference.action.text
        text = reference.text
        owner = reference.owner ?? ""
        due = reference.due ?? ""
    }
}

struct ActionCorrectionSheet: View {
    @State var draft: ActionCorrectionDraft
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct action details").font(WorkspaceTypography.pageTitle)
            TextField("Corrected wording", text: $draft.text)
            HStack {
                Text("Owner")
                Spacer()
                Menu(draft.owner.isEmpty ? "Unassigned" : draft.owner) {
                    Button("Me") { draft.owner = "Me" }
                    Button("Unresolved speaker") { draft.owner = "Unresolved speaker" }
                    Button("Unassigned") { draft.owner = "" }
                }
            }
            TextField("Owner", text: $draft.owner)
            TextField("Due date as agreed", text: $draft.due)
            Text("This correction is stored separately from the extracted source.")
                .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save correction") { onSave(draft.text, draft.owner, draft.due) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(WorkspaceMetric.sectionGap)
        .frame(width: 460)
    }
}
