import Foundation

struct CotypingBenchmarkScenario: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var field: CotypingField
    var expectedTerms: [String]
    var latencyTargetMs: Int
    var expectsVisibleSuggestion: Bool = true
    var allowedSuppressions: [CotypingSuppressionReason] = []

    static let defaults: [CotypingBenchmarkScenario] = [
        CotypingBenchmarkScenario(
            id: "email-follow-up",
            name: "Email follow-up",
            field: CotypingField(
                appName: "Mail", bundleID: "com.apple.mail", processID: 0, role: "AXTextArea",
                precedingText: "Hi Sarah,\nThanks for sending this over. I wanted to follow",
                trailingText: "", selectionLength: 0, caretRect: .zero, isSecure: false,
                caretIsExact: true, windowTitle: "Re: Q3 planning", fieldPlaceholder: nil),
            expectedTerms: ["up", "today", "tomorrow", "with"],
            latencyTargetMs: 2_000),
        CotypingBenchmarkScenario(
            id: "chat-ownership",
            name: "Chat ownership",
            field: CotypingField(
                appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", processID: 0, role: "AXTextArea",
                precedingText: "Sounds good, I can take",
                trailingText: "", selectionLength: 0, caretRect: .zero, isSecure: false,
                caretIsExact: true, windowTitle: "project-launch", fieldPlaceholder: "Message #project-launch"),
            expectedTerms: ["that", "it", "this", "over"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "browser-prose",
            name: "Browser prose",
            field: CotypingField(
                appName: "Safari", bundleID: "com.apple.Safari", processID: 0, role: "AXTextArea",
                precedingText: "The main tradeoff is",
                trailingText: "", selectionLength: 0, caretRect: .zero, isSecure: false,
                caretIsExact: true, windowTitle: "Design note", fieldPlaceholder: "Leave a comment"),
            expectedTerms: ["that", "between", "latency", "quality"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "mid-word",
            name: "Mid-word safety",
            field: CotypingField(
                appName: "Notes", bundleID: "com.apple.Notes", processID: 0, role: "AXTextArea",
                precedingText: "Please rec",
                trailingText: "eive the files when ready.", selectionLength: 0, caretRect: .zero,
                isSecure: false, caretIsExact: true, windowTitle: "Project notes", fieldPlaceholder: nil),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            expectsVisibleSuggestion: false,
            allowedSuppressions: [.duplicatesTrailingText, .unsafeToInsert]),
    ]
}

struct CotypingBenchmarkCaseResult: Identifiable, Equatable, Sendable {
    var id: String { scenarioID }
    var scenarioID: String
    var name: String
    var text: String
    var latencyMs: Int
    var firstVisibleLatencyMs: Int?
    var expectedTermHits: Int
    var expectedTermCount: Int
    var suppression: CotypingSuppressionReason?
    var error: String?
    var expectedVisibleSuggestion: Bool
    var allowedSuppression: Bool

    var passedSafety: Bool {
        guard error == nil else { return false }
        if expectedVisibleSuggestion {
            return suppression == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && allowedSuppression
    }

    var latencyForTargetMs: Int { firstVisibleLatencyMs ?? latencyMs }
    var metLatencyTarget: Bool { latencyForTargetMs <= latencyTargetMs }
    var latencyTargetMs: Int
    var passed: Bool { passedSafety && metLatencyTarget }
}

struct CotypingBenchmarkSummary: Equatable, Sendable {
    var results: [CotypingBenchmarkCaseResult]

    var total: Int { results.count }
    var passed: Int { results.filter(\.passed).count }
    var safetyPassed: Int { results.filter(\.passedSafety).count }
    var keywordHits: Int { results.map(\.expectedTermHits).reduce(0, +) }
    var keywordTotal: Int { results.map(\.expectedTermCount).reduce(0, +) }

    var averageLatencyMs: Int? {
        guard !results.isEmpty else { return nil }
        return results.map(\.latencyMs).reduce(0, +) / results.count
    }

    var averageFirstVisibleLatencyMs: Int? {
        let values = results.compactMap(\.firstVisibleLatencyMs)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    var p95LatencyMs: Int? {
        percentile(results.map(\.latencyMs), 0.95)
    }

    var p95FirstVisibleLatencyMs: Int? {
        let values = results.compactMap(\.firstVisibleLatencyMs)
        return percentile(values, 0.95)
    }

    var meetsTarget: Bool {
        total > 0 && results.allSatisfy(\.passed)
    }

    private func percentile(_ values: [Int], _ p: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }
}

private final class CotypingBenchmarkLatencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var firstVisibleLatencyMs: Int?

    func recordFirstVisible(start: Date, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard firstVisibleLatencyMs == nil else { return }
        firstVisibleLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
    }

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return firstVisibleLatencyMs
    }
}

@MainActor
enum CotypingBenchmarkRunner {
    static func run(
        scenarios: [CotypingBenchmarkScenario] = CotypingBenchmarkScenario.defaults,
        engine: CotypingCompleting,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        streamPartials: Bool = false,
        learnedExamples: (CotypingField) -> [String] = { _ in [] }
    ) async -> CotypingBenchmarkSummary {
        var results: [CotypingBenchmarkCaseResult] = []
        for scenario in scenarios {
            results.append(await runOne(
                scenario,
                engine: engine,
                config: config,
                personalization: personalization,
                streamPartials: streamPartials,
                learnedExamples: learnedExamples(scenario.field)))
        }
        return CotypingBenchmarkSummary(results: results)
    }

    static func evaluate(
        scenario: CotypingBenchmarkScenario,
        text: String,
        suppression: CotypingSuppressionReason?,
        latencyMs: Int,
        firstVisibleLatencyMs: Int? = nil,
        error: String? = nil
    ) -> CotypingBenchmarkCaseResult {
        let folded = text.lowercased()
        let hits = scenario.expectedTerms.filter { folded.contains($0.lowercased()) }.count
        return CotypingBenchmarkCaseResult(
            scenarioID: scenario.id,
            name: scenario.name,
            text: text,
            latencyMs: max(0, latencyMs),
            firstVisibleLatencyMs: firstVisibleLatencyMs.map { max(0, $0) },
            expectedTermHits: hits,
            expectedTermCount: scenario.expectedTerms.count,
            suppression: suppression,
            error: error,
            expectedVisibleSuggestion: scenario.expectsVisibleSuggestion,
            allowedSuppression: suppression.map { scenario.allowedSuppressions.contains($0) } ?? false,
            latencyTargetMs: scenario.latencyTargetMs)
    }

    private static func runOne(
        _ scenario: CotypingBenchmarkScenario,
        engine: CotypingCompleting,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        streamPartials: Bool,
        learnedExamples: [String]
    ) async -> CotypingBenchmarkCaseResult {
        guard let request = CotypingRequestBuilder.build(
            field: scenario.field,
            config: config,
            personalization: personalization,
            generation: 0,
            learnedExamples: learnedExamples)
        else {
            return evaluate(
                scenario: scenario,
                text: "",
                suppression: .emptyGeneration,
                latencyMs: 0,
                error: "Could not build request.")
        }

        let start = Date()
        let latencyProbe = CotypingBenchmarkLatencyProbe()
        do {
            let result = try await engine.generateStreaming(request) { partial in
                guard streamPartials else { return }
                latencyProbe.recordFirstVisible(start: start, text: partial.text)
            }
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return evaluate(
                scenario: scenario,
                text: result.text,
                suppression: result.suppression,
                latencyMs: latency,
                firstVisibleLatencyMs: latencyProbe.value)
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return evaluate(
                scenario: scenario,
                text: "",
                suppression: nil,
                latencyMs: latency,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// Result of running both cotyping engines over the same scenarios. Deltas are
/// `http − local`, so a positive value means the in-process engine is faster.
struct CotypingABComparison: Equatable, Sendable {
    let local: CotypingBenchmarkSummary
    let http: CotypingBenchmarkSummary

    /// p95 end-to-end latency improvement (ms), or nil if either side has no data.
    var p95DeltaMs: Int? {
        guard let l = local.p95LatencyMs, let h = http.p95LatencyMs else { return nil }
        return h - l
    }

    /// Time-to-first-visible-token improvement (ms), or nil if either side lacks it.
    var ttftDeltaMs: Int? {
        guard let l = local.averageFirstVisibleLatencyMs,
              let h = http.averageFirstVisibleLatencyMs else { return nil }
        return h - l
    }
}

extension CotypingBenchmarkRunner {
    /// Runs the default scenarios through both engines (streaming on, so TTFT is
    /// captured) and returns the comparison. For manual latency validation.
    static func runAB(
        local: CotypingCompleting,
        http: CotypingCompleting,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        learnedExamples: @escaping (CotypingField) -> [String] = { _ in [] }
    ) async -> CotypingABComparison {
        let localSummary = await run(
            engine: local, config: config, personalization: personalization,
            streamPartials: true, learnedExamples: learnedExamples)
        let httpSummary = await run(
            engine: http, config: config, personalization: personalization,
            streamPartials: true, learnedExamples: learnedExamples)
        return CotypingABComparison(local: localSummary, http: httpSummary)
    }
}
