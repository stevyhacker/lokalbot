import Foundation

struct RetentionReview: Identifiable {
    struct Candidate: Equatable, Hashable, Identifiable {
        let id: Int64
        let timestamp: Date
        let path: String
        let removeText: Bool
        let removeVector: Bool
    }
    let id = UUID()
    let days: Int
    let keepTextForever: Bool
    let reviewedAt: Date
    let candidates: [Candidate]
    let savedCount: Int
    let bytes: Int64

    var pixelCount: Int { candidates.filter { !$0.path.isEmpty }.count }
    var textCount: Int { candidates.filter(\.removeText).count }
    var vectorCount: Int { candidates.filter(\.removeVector).count }
    var oldest: Date? { candidates.map(\.timestamp).min() }
    var newest: Date? { candidates.map(\.timestamp).max() }

    /// A disappearing file or newly saved moment may shrink a review safely.
    /// Additional data, changed paths or new text require a fresh review.
    func covers(_ current: RetentionReview) -> Bool {
        let approved = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return days == current.days && keepTextForever == current.keepTextForever
            && current.candidates.allSatisfy { candidate in
                guard let old = approved[candidate.id] else { return false }
                return (candidate.path.isEmpty || candidate.path == old.path)
                    && (!candidate.removeText || old.removeText)
                    && (!candidate.removeVector || old.removeVector)
            }
    }
}

enum RetentionReviewError: LocalizedError {
    case scopeChanged
    var errorDescription: String? {
        "The cleanup scope changed. Review the updated counts before applying it."
    }
}
