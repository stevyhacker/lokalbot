import Foundation

/// Shape of the notes the LLM should produce. Adapted from Seminarly's
/// `NoteTemplate` — LokalBot keeps summarisation output as Markdown rather
/// than structured JSON, so the JSON section schema isn't ported, just the
/// enum that drives prompt selection.
enum NoteTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case meeting
    case lecture
    case studyGuide
    case podcast
    case freeform

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meeting: return "Meeting"
        case .lecture: return "Lecture"
        case .studyGuide: return "Study guide"
        case .podcast: return "Podcast / interview"
        case .freeform: return "Free-form"
        }
    }

    var icon: String {
        switch self {
        case .meeting: return "person.2.fill"
        case .lecture: return "graduationcap.fill"
        case .studyGuide: return "book.fill"
        case .podcast: return "mic.fill"
        case .freeform: return "doc.text.fill"
        }
    }

    /// One-line summary used in the Settings picker.
    var description: String {
        switch self {
        case .meeting:
            return "TL;DR · Key points · Decisions · Action items · Open questions"
        case .lecture:
            return "TL;DR · Concepts · Definitions · Examples · Questions to review"
        case .studyGuide:
            return "TL;DR · Key concepts · Flashcards · Practice questions"
        case .podcast:
            return "TL;DR · Topics · Quotes · Insights"
        case .freeform:
            return "Topical bullets — the model decides the section headings"
        }
    }
}
