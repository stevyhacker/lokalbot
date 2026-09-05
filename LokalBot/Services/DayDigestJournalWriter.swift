import Foundation

/// Capture the journal revision before awaiting a model, then verify it again
/// immediately before committing. A user edit or a newer generation wins.
enum DayDigestJournalWriter {
    struct Revision: Equatable, Sendable {
        var digest: String?
    }

    enum WriteError: LocalizedError {
        case changedDuringGeneration

        var errorDescription: String? {
            "The journal changed while its digest was being generated. Your changes were preserved."
        }
    }

    static func revision(at url: URL) throws -> Revision {
        do {
            return Revision(digest: ContentFingerprint.digest(try Data(contentsOf: url)))
        } catch {
            let error = error as NSError
            guard error.domain == NSCocoaErrorDomain,
                  error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError else {
                throw error
            }
            return Revision(digest: nil)
        }
    }

    static func write(
        _ text: String, to url: URL, replacing expected: Revision,
        evidence: DayDigestEvidence, quality: DayDigestGenerationQuality
    ) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try revision(at: url) == expected else { throw WriteError.changedDuringGeneration }
        try text.write(to: url, atomically: true, encoding: .utf8)
        try DayDigestGenerationMetadataStore.record(
            quality: quality, evidenceLatestAt: evidence.latestEvidenceAt,
            evidenceSignature: evidence.contentSignature,
            meetingEvidenceSignature: evidence.meetingSignature, for: url)
    }
}
