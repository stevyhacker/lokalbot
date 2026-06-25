import Foundation

struct CotypingBenchmarkScenario: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var field: CotypingField
    var expectedTerms: [String]
    var latencyTargetMs: Int

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
            name: "Mid-word continuation",
            field: CotypingField(
                appName: "Notes", bundleID: "com.apple.Notes", processID: 0, role: "AXTextArea",
                precedingText: "Please rec",
                trailingText: "eive the files when ready.", selectionLength: 0, caretRect: .zero,
                isSecure: false, caretIsExact: true, windowTitle: "Project notes", fieldPlaceholder: nil),
            expectedTerms: ["eive"],
            latencyTargetMs: 1_200),
    ]
}

struct CotypingBenchmarkCaseResult: Identifiable, Equatable, Sendable {
    var id: String { scenarioID }
    var scenarioID: String
    var name: String
    var text: String
    var latencyMs: Int
    var expectedTermHits: Int
    var expectedTermCount: Int
    var suppression: CotypingSuppressionReason?
    var error: String?

    var passedSafety: Bool {
        error == nil && suppression == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var metLatencyTarget: Bool
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

    var p95LatencyMs: Int? {
        percentile(0.95)
    }

    var meetsTarget: Bool {
        total > 0 && safetyPassed == total && (p95LatencyMs ?? Int.max) <= 2_000
    }

    private func percentile(_ p: Double) -> Int? {
        guard !results.isEmpty else { return nil }
        let sorted = results.map(\.latencyMs).sorted()
        let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }
}

@MainActor
enum CotypingBenchmarkRunner {
    static func run(
        scenarios: [CotypingBenchmarkScenario] = CotypingBenchmarkScenario.defaults,
        engine: CotypingCompleting,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        learnedExamples: (CotypingField) -> [String] = { _ in [] }
    ) async -> CotypingBenchmarkSummary {
        var results: [CotypingBenchmarkCaseResult] = []
        for scenario in scenarios {
            results.append(await runOne(
                scenario,
                engine: engine,
                config: config,
                personalization: personalization,
                learnedExamples: learnedExamples(scenario.field)))
        }
        return CotypingBenchmarkSummary(results: results)
    }

    static func evaluate(
        scenario: CotypingBenchmarkScenario,
        text: String,
        suppression: CotypingSuppressionReason?,
        latencyMs: Int,
        error: String? = nil
    ) -> CotypingBenchmarkCaseResult {
        let folded = text.lowercased()
        let hits = scenario.expectedTerms.filter { folded.contains($0.lowercased()) }.count
        return CotypingBenchmarkCaseResult(
            scenarioID: scenario.id,
            name: scenario.name,
            text: text,
            latencyMs: max(0, latencyMs),
            expectedTermHits: hits,
            expectedTermCount: scenario.expectedTerms.count,
            suppression: suppression,
            error: error,
            metLatencyTarget: latencyMs <= scenario.latencyTargetMs)
    }

    private static func runOne(
        _ scenario: CotypingBenchmarkScenario,
        engine: CotypingCompleting,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
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
        do {
            let result = try await engine.generate(request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return evaluate(
                scenario: scenario,
                text: result.text,
                suppression: result.suppression,
                latencyMs: latency)
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
