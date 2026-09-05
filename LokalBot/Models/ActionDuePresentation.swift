import Foundation

enum ActionDuePresentation {
    /// Only an explicit ISO calendar date can drive overdue sorting. Relative
    /// language retains the original meeting date instead of guessing intent.
    static func date(_ phrase: String?) -> Date? {
        guard let phrase, AskDayScope.isCanonicalKey(phrase) else { return nil }
        return AskDayScope.date(for: phrase)
    }

    static func label(_ phrase: String, spokenAt: Date) -> String {
        if let date = date(phrase) { return "Due \(date.formatted(date: .abbreviated, time: .omitted))" }
        return "\(phrase) — said on \(spokenAt.formatted(date: .abbreviated, time: .omitted))"
    }
}
