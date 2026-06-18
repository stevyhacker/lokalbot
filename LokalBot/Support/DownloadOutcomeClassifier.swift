import Foundation

/// The terminal state of a model download, reduced to the few cases the UI
/// needs to react to. Crucially this separates "the user pressed Cancel" from
/// a genuine failure so the app can restore prior state silently instead of
/// surfacing an alarming error for a deliberate action.
///
/// Kept free of any `URLSession`/`Task` machinery so the decision is a pure
/// function of plain values and is unit-testable without the network.
enum DownloadOutcome: Equatable, Sendable {
    /// HTTP 2xx (or no response error) and the staged bytes begin with the
    /// GGUF magic — the file is a usable model.
    case success
    /// The server answered with a non-2xx status; the payload is not a model.
    case httpError(Int)
    /// The transfer finished but the bytes are not a GGUF file — typically an
    /// HTML error/landing page served with a 200.
    case notGGUF
    /// The user cancelled. Callers should quietly roll back, not alert.
    case cancelled
    /// A transport-level failure (DNS, TLS, connection reset, timeout),
    /// carrying the underlying description for display.
    case transport(String)
}

extension DownloadOutcome {
    /// The single source of truth for user-facing copy. Every download surface
    /// binds to this so error wording stays consistent.
    var userMessage: String {
        switch self {
        case .success:
            return "Download complete."
        case .httpError(let status):
            return "Download failed (HTTP \(status))."
        case .notGGUF:
            return "Download failed (response was not a GGUF model)."
        case .cancelled:
            return "Download cancelled."
        case .transport(let detail):
            return "Download failed: \(detail)"
        }
    }
}

enum DownloadOutcomeClassifier {
    /// Folds the three independent signals a finished download produces — the
    /// HTTP status (if any response arrived), a terminal error (if the transfer
    /// aborted), and whether the staged bytes start with the GGUF magic — into
    /// one outcome.
    ///
    /// Priority order is deliberate:
    ///   1. User cancellation wins over everything. `Task` cancellation and an
    ///      in-flight `URLSessionDownloadTask.cancel()` surface as two distinct
    ///      error shapes (`CancellationError` vs the bridged `URLError.cancelled`);
    ///      both must read as `.cancelled`, never as a transport failure, or the
    ///      user gets a scary message for an action they took on purpose.
    ///   2. A non-2xx status is the authoritative failure when a response came
    ///      back at all — a concrete code is a clearer message than a generic
    ///      transport string, and clearer than "not a GGUF".
    ///   3. Any remaining error is a transport-level failure.
    ///   4. Only once the transfer is known-clean do we judge the payload.
    static func classify(httpStatus: Int?, error: Error?, looksLikeGGUF: Bool) -> DownloadOutcome {
        if let error, isUserCancellation(error) {
            return .cancelled
        }
        if let httpStatus, !(200..<300).contains(httpStatus) {
            return .httpError(httpStatus)
        }
        if let error {
            return .transport(error.localizedDescription)
        }
        guard looksLikeGGUF else {
            return .notGGUF
        }
        return .success
    }

    /// `true` when the error represents a deliberate cancellation rather than a
    /// fault. Covers both the pre-flight `CancellationError` and the
    /// `NSURLErrorCancelled` an aborted in-flight transfer reports (which is the
    /// bridged form of `URLError(.cancelled)`).
    static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
