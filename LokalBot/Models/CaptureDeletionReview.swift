import Foundation

struct CaptureDeletionReview: Identifiable {
    let id = UUID()
    let interval: DateInterval
    let includesSaved: Bool
    let captures: [ActivityStore.Screenshot]
    let savedExcluded: Int

    var pixelCount: Int { captures.filter(\.hasPixels).count }
    var savedIncluded: Int { captures.filter(\.isBookmarked).count }

    func covers(_ current: Self) -> Bool {
        guard interval == current.interval, includesSaved == current.includesSaved else { return false }
        let approved = Dictionary(uniqueKeysWithValues: captures.map { ($0.id, $0) })
        return current.captures.allSatisfy { item in
            guard let original = approved[item.id] else { return false }
            return item.ts == original.ts && (item.path.isEmpty || item.path == original.path)
        }
    }
}

extension ActivityStore {
    func captureDeletionReview(in interval: DateInterval, includesSaved: Bool) -> CaptureDeletionReview {
        let all = screenshots(in: interval, app: nil, bookmarkedOnly: false, includingMissingFiles: true)
        return CaptureDeletionReview(
            interval: interval, includesSaved: includesSaved,
            captures: all.filter { includesSaved || !$0.isBookmarked },
            savedExcluded: includesSaved ? 0 : all.filter(\.isBookmarked).count)
    }
}
