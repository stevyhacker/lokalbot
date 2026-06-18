import Foundation

/// Pure character-budget allocator for multi-section prompts.
///
/// `ProcessingPipeline` assembles a summariser prompt from several labelled
/// pieces — system rules, the transcript chunk, optional glossary/context. When
/// their combined size exceeds the model's context window something has to give,
/// and it must be the least important piece, not the transcript the model is
/// asked to summarise. `fit` trims sections to a single character budget: each
/// declares a `priority` (higher is kept) and a `minCharacters` floor, the
/// lowest-priority sections are shortened first, and within one priority tier the
/// cut is shared proportionally to size.
///
/// Character-based on purpose, so the layer stays pure and deterministic; pair it
/// with `TokenCountEstimator` (≈4 chars/token) to convert a token budget first.
struct PromptSectionBudget: Sendable {
    /// One labelled piece of the prompt competing for the shared budget.
    struct Section: Sendable {
        let label: String
        let text: String
        /// Higher priority survives budget pressure; the lowest-priority
        /// sections are shortened first.
        let priority: Int
        /// Characters this section keeps before any higher-priority section is
        /// touched. Clamped to the section's own length, and only breached in the
        /// degenerate case where the floors alone overflow the budget.
        let minCharacters: Int
    }

    /// Trims `sections` to fit `totalBudget` characters, returning every section
    /// in its ORIGINAL order (render order stays the caller's concern) with
    /// possibly-shortened text. Deterministic for identical input.
    ///
    /// Allocation, applied in order:
    ///  1. If everything already fits, nothing is trimmed.
    ///  2. The overflow is removed from discretionary content (above each
    ///     section's clamped floor), lowest priority first; ties at the same
    ///     priority share the cut proportionally to their size.
    ///  3. If the floors themselves overflow the budget, sections are trimmed
    ///     below their floors — still lowest priority first — down to empty.
    /// Shortening keeps each section's leading characters.
    func fit(sections: [Section], totalBudget: Int) -> [(label: String, text: String)] {
        guard !sections.isEmpty else { return [] }
        let budget = max(0, totalBudget)

        let lengths = sections.map { $0.text.count }
        let totalNatural = lengths.reduce(0, +)

        // Everything fits — hand the sections back untouched.
        if totalNatural <= budget {
            return sections.map { (label: $0.label, text: $0.text) }
        }

        // Per-section floor, never larger than what the section actually holds.
        let floors = sections.indices.map { min(max(0, sections[$0].minCharacters), lengths[$0]) }

        var allocation = lengths
        var deficit = totalNatural - budget

        // Pass 1: absorb the overflow from content above the floors.
        Self.trim(&allocation, deficit: &deficit, lowerBound: floors, sections: sections)
        // Pass 2: the floors alone exceed the budget — keep trimming below them.
        if deficit > 0 {
            let zeros = [Int](repeating: 0, count: sections.count)
            Self.trim(&allocation, deficit: &deficit, lowerBound: zeros, sections: sections)
        }

        return sections.indices.map { index in
            (label: sections[index].label,
             text: String(sections[index].text.prefix(allocation[index])))
        }
    }

    /// Removes `deficit` characters from `allocation`, walking priority tiers from
    /// lowest to highest and never dropping a section below `lowerBound[i]`.
    private static func trim(
        _ allocation: inout [Int],
        deficit: inout Int,
        lowerBound: [Int],
        sections: [Section]
    ) {
        guard deficit > 0 else { return }

        // Indices lowest-priority-first; equal priorities keep input order so the
        // proportional split is deterministic.
        let order = sections.indices.sorted { lhs, rhs in
            sections[lhs].priority == sections[rhs].priority
                ? lhs < rhs
                : sections[lhs].priority < sections[rhs].priority
        }

        var cursor = 0
        while cursor < order.count, deficit > 0 {
            let tierPriority = sections[order[cursor]].priority
            var tier: [Int] = []
            while cursor < order.count, sections[order[cursor]].priority == tierPriority {
                tier.append(order[cursor])
                cursor += 1
            }
            absorb(&allocation, deficit: &deficit, tier: tier, lowerBound: lowerBound)
        }
    }

    /// Distributes `min(deficit, tier headroom)` across one priority tier in
    /// proportion to each section's headroom (`allocation - lowerBound`), using
    /// the largest-remainder method so the total removed is exact and the split
    /// is deterministic. Updates `allocation` and `deficit` in place.
    private static func absorb(
        _ allocation: inout [Int],
        deficit: inout Int,
        tier: [Int],
        lowerBound: [Int]
    ) {
        let headroom = tier.map { allocation[$0] - lowerBound[$0] }
        let tierHeadroom = headroom.reduce(0, +)
        guard tierHeadroom > 0 else { return }

        let toRemove = min(deficit, tierHeadroom)

        // Floor each proportional share, then hand the leftover units to the
        // largest fractional parts (ties broken by tier order). `toRemove <=
        // tierHeadroom` guarantees every floored share stays within its headroom.
        var removal = [Int](repeating: 0, count: tier.count)
        var fractions: [(slot: Int, fraction: Double)] = []
        for slot in tier.indices where headroom[slot] > 0 {
            let exact = Double(toRemove) * Double(headroom[slot]) / Double(tierHeadroom)
            let base = Int(exact.rounded(.down))
            removal[slot] = base
            if base < headroom[slot] { fractions.append((slot: slot, fraction: exact - Double(base))) }
        }

        var leftover = toRemove - removal.reduce(0, +)
        let ranked = fractions.sorted { lhs, rhs in
            lhs.fraction == rhs.fraction ? lhs.slot < rhs.slot : lhs.fraction > rhs.fraction
        }
        var rank = 0
        while leftover > 0, rank < ranked.count {
            removal[ranked[rank].slot] += 1
            leftover -= 1
            rank += 1
        }

        for slot in tier.indices { allocation[tier[slot]] -= removal[slot] }
        deficit -= removal.reduce(0, +)
    }
}
