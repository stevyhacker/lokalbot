import SwiftUI

struct WorkspaceSpeakerRenameDraft: Identifiable {
    let id = UUID()
    let speaker: String
    let defaultName: String
    let currentName: String
    let currentCalendarIdentityID: String?
}

/// Focused editor for a speaker alias and its optional local calendar
/// identity. Keeping this flow separate leaves the meeting workspace focused
/// on orchestration instead of sheet-specific presentation state.
struct WorkspaceSpeakerRenameSheet: View {
    let draft: WorkspaceSpeakerRenameDraft
    let hints: [String]
    let calendarCandidates: [CalendarParticipantIdentity]
    let assignedCalendarIdentityIDs: Set<String>
    let onSave: (String, String?) -> Void
    let onReset: () -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var selectedCalendarIdentityID: String?

    init(
        draft: WorkspaceSpeakerRenameDraft,
        hints: [String],
        calendarCandidates: [CalendarParticipantIdentity],
        assignedCalendarIdentityIDs: Set<String>,
        onSave: @escaping (String, String?) -> Void,
        onReset: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.hints = hints
        self.calendarCandidates = calendarCandidates
        self.assignedCalendarIdentityIDs = assignedCalendarIdentityIDs
        self.onSave = onSave
        self.onReset = onReset
        self.onCancel = onCancel
        _name = State(initialValue: draft.currentName)
        _selectedCalendarIdentityID = State(initialValue: draft.currentCalendarIdentityID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Speaker").font(.headline)
            TextField("Speaker name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("speaker.rename.name")

            if !calendarCandidates.isEmpty {
                calendarCandidateSection
            }
            if !otherHints.isEmpty {
                suggestionSection
            }

            HStack {
                Button("Reset to \(draft.defaultName)", action: onReset)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(name, selectedCalendarIdentityID) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("speaker.rename.save")
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            uiTestDiagnosticLog(
                "speaker.rename sheet appear candidates=\(calendarCandidates.count)"
            )
        }
    }

    private var calendarCandidateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendar attendees")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(calendarCandidates.enumerated()), id: \.element.id) { index, candidate in
                calendarCandidateRow(candidate, index: index)
            }

            Text("Email addresses stay in this meeting's local metadata and are shown only to distinguish attendees.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            .quaternary.opacity(0.22),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    @ViewBuilder
    private var suggestionSection: some View {
        Text("Other suggestions")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(otherHints, id: \.self) { hint in
                    Button(hint) {
                        name = hint
                        selectedCalendarIdentityID = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var otherHints: [String] {
        let calendarNames = Set(calendarCandidates.compactMap(\.name).map(normalizedName))
        return hints.filter { !calendarNames.contains(normalizedName($0)) }
    }

    private func calendarCandidateRow(
        _ candidate: CalendarParticipantIdentity,
        index: Int
    ) -> some View {
        let assignedElsewhere = assignedCalendarIdentityIDs.contains(candidate.id)
            && candidate.id != draft.currentCalendarIdentityID
        let label = calendarCandidateAccessibilityLabel(
            candidate,
            assignedElsewhere: assignedElsewhere
        )
        return Button {
            selectCalendarCandidate(candidate)
        } label: {
            Label(
                label,
                systemImage: selectedCalendarIdentityID == candidate.id
                    ? "checkmark.circle.fill"
                    : "person.crop.circle"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A standard bordered button supplies the native AXButton role.
        .buttonStyle(.bordered)
        .tint(selectedCalendarIdentityID == candidate.id ? .accentColor : nil)
        .disabled(assignedElsewhere)
        .accessibilityIdentifier("speaker.rename.calendarCandidate.\(index)")
    }

    private func selectCalendarCandidate(_ candidate: CalendarParticipantIdentity) {
        selectedCalendarIdentityID = candidate.id
        name = candidate.name ?? ""
    }

    private func calendarCandidateAccessibilityLabel(
        _ candidate: CalendarParticipantIdentity,
        assignedElsewhere: Bool
    ) -> String {
        [
            candidate.name ?? "Name unavailable",
            candidate.emailAddress,
            assignedElsewhere ? "Assigned" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func normalizedName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}
