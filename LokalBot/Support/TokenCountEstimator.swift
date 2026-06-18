import Foundation

/// Cheap, allocation-light estimate of how many model tokens a string occupies.
///
/// `ProcessingPipeline` budgets transcript chunks against a model's context
/// window, and paying for a real tokenizer on that path is wasteful. A
/// word-aware heuristic — roughly four characters per token within a word, every
/// word at least one token — tracks real subword tokenization more closely than
/// a single global chars-per-token ratio, especially for code or short function
/// words. It is deliberately an *estimate*: use it for relative budgeting, never
/// to assert a hard token limit.
enum TokenCountEstimator {
    /// Estimated token count for `text`; `0` for empty or whitespace-only input.
    ///
    /// Splits on punctuation as well as whitespace because real tokenizers break
    /// "can't", "end.", and "func()" into several tokens — gluing punctuation to
    /// a word would systematically undercount code and punctuation-heavy prose.
    static func estimate(_ text: String) -> Int {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        guard !words.isEmpty else { return 0 }
        return words.reduce(0) { running, word in
            running + max(1, Int((Double(word.count) / 4.0).rounded()))
        }
    }
}
