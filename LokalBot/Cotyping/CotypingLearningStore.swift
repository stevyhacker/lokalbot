import Combine
import CryptoKit
import Foundation

struct CotypingLearningExample: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var appName: String
    var bundleID: String?
    var surfaceClass: String
    var contextHint: String?
    var prefixTail: String
    var acceptedText: String
}

struct CotypingLearningSnapshot: Codable, Equatable, Sendable {
    var examples: [CotypingLearningExample] = []
}

/// Accumulates one visible suggestion's accepted chunks until the coordinator
/// closes that suggestion. Stats can still count each accept gesture, while
/// encrypted learning stores one coherent example and performs one write.
struct CotypingAcceptedSuggestionBatch: Equatable, Sendable {
    struct LearningRecord: Equatable, Sendable {
        var field: CotypingField
        var acceptedText: String
    }

    struct Completion: Equatable, Sendable {
        var acceptedChunkCount: Int
        var learningRecord: LearningRecord?
    }

    private(set) var acceptedChunkCount = 0
    private var learningField: CotypingField?
    private var learningText = ""

    var isEmpty: Bool { acceptedChunkCount == 0 }

    mutating func append(
        field: CotypingField,
        acceptedText: String,
        learningEnabled: Bool
    ) {
        guard !acceptedText.isEmpty else { return }
        acceptedChunkCount += 1
        guard learningEnabled else { return }
        if learningField == nil { learningField = field }
        learningText += acceptedText
    }

    /// Forgets the private text accumulated for the current suggestion while
    /// preserving its accept count so stats can still close on the normal
    /// suggestion boundary.
    mutating func discardLearningRecord() {
        learningField = nil
        learningText = ""
    }

    /// Returns one completed persistence unit and resets the accumulator.
    /// Calling it repeatedly without another accepted chunk is a no-op.
    mutating func complete() -> Completion? {
        guard acceptedChunkCount > 0 else { return nil }
        let learningRecord = learningField.map {
            LearningRecord(field: $0, acceptedText: learningText)
        }
        let completion = Completion(
            acceptedChunkCount: acceptedChunkCount,
            learningRecord: learningRecord)
        self = .init()
        return completion
    }
}

enum CotypingLearningRanker {
    static let maxAcceptedCharacters = 240
    static let maxPrefixCharacters = 180
    static let maxContextCharacters = 180
    static let minimumRankScore = 5

    static func acceptedText(_ text: String) -> String? {
        guard let cleaned = clean(text, maxCharacters: maxAcceptedCharacters),
              cleaned.count >= 3,
              !CotypingPromptLeakGuard.looksLikePromptScaffolding(cleaned) else { return nil }
        return cleaned
    }

    static func prefixTail(_ text: String) -> String? {
        clean(String(text.suffix(maxPrefixCharacters)), maxCharacters: maxPrefixCharacters)
    }

    static func contextHint(for field: CotypingField) -> String? {
        guard let surface = CotypingSurfaceComposer.compose(
            appName: field.appName,
            bundleID: field.bundleID,
            windowTitle: field.windowTitle,
            fieldPlaceholder: field.fieldPlaceholder)
        else { return nil }
        return clean(
            CotypingSurfaceComposer.prefaceLines(for: surface).joined(separator: " "),
            maxCharacters: maxContextCharacters)
    }

    static func canLearn(from field: CotypingField) -> Bool {
        guard !field.isSecure else { return false }
        switch CotypingSurfaceClassifier.classify(bundleID: field.bundleID) {
        case .codeEditor, .terminal:
            return false
        case .email, .chat, .browser, .other:
            return true
        }
    }

    static func surfaceKey(for bundleID: String?) -> String {
        CotypingSurfaceClassifier.classify(bundleID: bundleID).learningKey
    }

    static func rankedExamples(
        _ examples: [CotypingLearningExample],
        for field: CotypingField,
        limit: Int
    ) -> [String] {
        guard canLearn(from: field), limit > 0 else { return [] }
        let surfaceKey = surfaceKey(for: field.bundleID)
        let prefixTerms = terms(in: field.precedingText)
        let contextTerms = contextHint(for: field).map { terms(in: $0) } ?? []

        let ranked = examples.compactMap { example -> (score: Int, date: Date, text: String)? in
            guard let text = acceptedText(example.acceptedText) else { return nil }
            var score = 0
            if sameBundle(example.bundleID, field.bundleID) { score += 8 }
            if example.surfaceClass == surfaceKey { score += 3 }
            let overlap = prefixTerms.intersection(terms(in: example.prefixTail)).count
            score += min(overlap, 5)
            if let hint = example.contextHint {
                let contextOverlap = contextTerms.intersection(terms(in: hint)).count
                score += min(contextOverlap, 4)
            }
            if sameAppName(example.appName, field.appName) { score += 2 }
            guard score >= minimumRankScore else { return nil }
            return (score, example.createdAt, text)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.date > $1.date
        }

        var seen = Set<String>()
        var selected: [String] = []
        for item in ranked {
            let key = item.text.lowercased()
            guard seen.insert(key).inserted else { continue }
            selected.append(item.text)
            if selected.count == limit { break }
        }
        return selected
    }

    private static func clean(_ text: String, maxCharacters: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxCharacters))
    }

    private static func sameBundle(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.lowercased(), let rhs = rhs?.lowercased(),
              !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs
    }

    private static func sameAppName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func terms(in text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 })
    }
}

/// Async persistence seam. The production actor keeps JSON encoding,
/// encryption, and atomic file replacement off the main actor; tests inject a
/// recorder without touching the user's Keychain.
protocol CotypingLearningPersisting: Sendable {
    func persist(_ snapshot: CotypingLearningSnapshot) async
    func remove() async
}

actor EncryptedCotypingLearningPersistence: CotypingLearningPersisting {
    private let url: URL
    private let key: SymmetricKey?

    init(url: URL, key: SymmetricKey?) {
        self.url = url
        self.key = key
    }

    func persist(_ snapshot: CotypingLearningSnapshot) {
        guard let key else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else {
                throw NSError(
                    domain: "LokalBot",
                    code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "Could not seal cotyping learning data."])
            }
            try combined.write(to: url, options: .atomic)
        } catch {
            // Learning is opportunistic. Match the previous best-effort write
            // behavior without blocking typing or surfacing private content.
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class CotypingLearningStore: ObservableObject {
    private static let keychainAccount = "cotyping-learning-key"
    private static let fileName = "cotyping-learning.enc"

    @Published private(set) var exampleCount = 0

    private let maxExamples: Int
    private let persistence: any CotypingLearningPersisting
    private var persistenceTask: Task<Void, Never>?
    private var revision = 0
    private var enqueuedRevision = 0
    private var snapshot: CotypingLearningSnapshot {
        didSet { exampleCount = snapshot.examples.count }
    }

    init(
        storageRoot: URL,
        maxExamples: Int = 500,
        persistence: (any CotypingLearningPersisting)? = nil,
        initialSnapshot: CotypingLearningSnapshot? = nil
    ) {
        let url = storageRoot.appendingPathComponent(Self.fileName)
        self.maxExamples = maxExamples
        let key: SymmetricKey?
        if let initialSnapshot {
            key = nil
            self.snapshot = initialSnapshot
        } else {
            key = try? KeychainSecrets.symmetricKey(account: Self.keychainAccount)
            self.snapshot = Self.load(from: url, key: key)
        }
        self.persistence = persistence
            ?? EncryptedCotypingLearningPersistence(url: url, key: key)
        self.exampleCount = snapshot.examples.count
    }

    /// Compatibility entry point. Production coordinator code should call the
    /// completed-suggestion name after aggregating its accepted chunks.
    func recordAccepted(field: CotypingField, acceptedText rawText: String) {
        recordCompletedSuggestion(field: field, acceptedText: rawText)
    }

    func recordCompletedSuggestion(field: CotypingField, acceptedText rawText: String) {
        guard CotypingLearningRanker.canLearn(from: field),
              let acceptedText = CotypingLearningRanker.acceptedText(rawText) else { return }

        let example = CotypingLearningExample(
            id: UUID(),
            createdAt: Date(),
            appName: field.appName,
            bundleID: field.bundleID,
            surfaceClass: CotypingLearningRanker.surfaceKey(for: field.bundleID),
            contextHint: CotypingLearningRanker.contextHint(for: field),
            prefixTail: CotypingLearningRanker.prefixTail(field.precedingText) ?? "",
            acceptedText: acceptedText)
        snapshot.examples.append(example)
        if snapshot.examples.count > maxExamples {
            snapshot.examples.removeFirst(snapshot.examples.count - maxExamples)
        }
        revision &+= 1
        enqueuePersistence()
    }

    func examples(for field: CotypingField, limit: Int) -> [String] {
        CotypingLearningRanker.rankedExamples(snapshot.examples, for: field, limit: limit)
    }

    func clear() {
        snapshot = .init()
        revision &+= 1
        enqueuedRevision = revision
        let previous = persistenceTask
        let persistence = persistence
        persistenceTask = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            await persistence.remove()
        }
    }

    /// Forces any dirty in-memory snapshot into the background queue, then
    /// waits for it. Used at app termination; ordinary typing never awaits IO.
    func flushPersistence() async {
        if revision != enqueuedRevision { enqueuePersistence() }
        let pending = persistenceTask
        await pending?.value
    }

    /// Waits only for already-enqueued work. Kept internal for deterministic
    /// tests of the completed-suggestion batching boundary.
    func waitForPendingPersistence() async {
        let pending = persistenceTask
        await pending?.value
    }

    private func enqueuePersistence() {
        let persistedSnapshot = snapshot
        enqueuedRevision = revision
        let previous = persistenceTask
        let persistence = persistence
        persistenceTask = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            await persistence.persist(persistedSnapshot)
        }
    }

    private static func load(from url: URL, key: SymmetricKey?) -> CotypingLearningSnapshot {
        guard let encrypted = try? Data(contentsOf: url),
              let key,
              let sealed = try? AES.GCM.SealedBox(combined: encrypted),
              let data = try? AES.GCM.open(sealed, using: key),
              let snapshot = try? JSONDecoder().decode(CotypingLearningSnapshot.self, from: data)
        else { return .init() }
        return snapshot
    }
}

private extension CotypingSurfaceClass {
    var learningKey: String {
        switch self {
        case .codeEditor: "codeEditor"
        case .terminal: "terminal"
        case .email: "email"
        case .chat: "chat"
        case .browser: "browser"
        case .other: "other"
        }
    }
}
