import Foundation

/// Bounded memory of recently shown continuation suggestions. It lets common
/// editing paths re-show the still-valid tail instantly, without debounce or a
/// model call: focus bounce, backspace rollback, and typing through a suggestion
/// after the active session was cleared.
nonisolated struct CotypingSuggestionAnchorCache {
    static let prefixTailLength = 256
    static let capacity = 16
    static let maxEntryAge: TimeInterval = 180

    private struct Anchor: Equatable {
        let identityKey: String
        let prefixTail: String
        let fullText: String
    }

    private struct Entry {
        let anchor: Anchor
        let recordedAt: Date
    }

    private struct Match {
        let remainder: String
        let consumed: Int
        let recordedAt: Date

        func beats(_ other: Match?) -> Bool {
            guard let other else { return true }
            if consumed != other.consumed { return consumed > other.consumed }
            return recordedAt > other.recordedAt
        }
    }

    private var entries: [Entry] = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    mutating func record(identityKey: String, precedingText: String, fullText: String) {
        guard !identityKey.isEmpty, !fullText.isEmpty else { return }
        let anchor = Anchor(
            identityKey: identityKey,
            prefixTail: Self.tail(of: precedingText),
            fullText: fullText)
        entries.removeAll { $0.anchor == anchor }
        entries.append(Entry(anchor: anchor, recordedAt: now()))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    mutating func remainder(identityKey: String, precedingText: String) -> String? {
        pruneExpired()
        let liveTail = Self.tail(of: precedingText)
        var best: Match?
        for entry in entries.reversed() where entry.anchor.identityKey == identityKey {
            guard let consumed = Self.consumedPrefixLength(
                liveTail: liveTail,
                anchorTail: entry.anchor.prefixTail,
                fullText: entry.anchor.fullText)
            else { continue }
            let match = Match(
                remainder: String(entry.anchor.fullText.dropFirst(consumed)),
                consumed: consumed,
                recordedAt: entry.recordedAt)
            if match.beats(best) {
                best = match
            }
        }
        return best?.remainder
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    private mutating func pruneExpired() {
        let cutoff = now().addingTimeInterval(-Self.maxEntryAge)
        entries.removeAll { $0.recordedAt < cutoff }
    }

    private static func consumedPrefixLength(
        liveTail: String,
        anchorTail: String,
        fullText: String
    ) -> Int? {
        let live = Array(liveTail)
        let composed = Array(anchorTail) + Array(fullText)
        let anchorCount = anchorTail.count

        for consumed in 0..<max(0, composed.count - anchorCount) {
            let end = anchorCount + consumed
            let start = max(0, end - prefixTailLength)
            guard end - start == live.count else { continue }
            if composed[start..<end].elementsEqual(live) {
                return consumed
            }
        }
        return nil
    }

    private static func tail(of text: String) -> String {
        String(text.suffix(prefixTailLength))
    }
}
