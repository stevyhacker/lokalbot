import Foundation

enum MeetingWorkspaceTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case actions = "Actions"
    case transcript = "Transcript"
    case notes = "Notes"
    var id: String { rawValue }

    static func containing(_ location: MeetingPageSearchMatch.Location) -> Self {
        switch location {
        case .action, .sectionHeader(.actionItems), .emptyState(.actionItems): .actions
        case .notes, .notesLabel, .sectionHeader(.notes), .emptyState(.notes): .notes
        case .transcript, .transcriptEngine, .sectionHeader(.transcript), .emptyState(.transcript): .transcript
        default: .overview
        }
    }
}
