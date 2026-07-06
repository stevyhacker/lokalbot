import Foundation

struct CotypingBenchmarkScenario: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var field: CotypingField
    var expectedTerms: [String]
    var latencyTargetMs: Int
    var expectsVisibleSuggestion: Bool = true
    var allowedSuppressions: [CotypingSuppressionReason] = []
    /// Word-completion contract (Cotypist parity): the caret sits at the end of
    /// a word fragment and a visible suggestion MUST extend it — begin with a
    /// word character, and (when provided) with one of
    /// `expectedCompletionPrefixes`. An empty result passes only via
    /// `allowedSuppressions`.
    var expectsWordCompletion: Bool = false
    var expectedCompletionPrefixes: [String] = []
    /// Mirrors the coordinator's spell-checker verdict for the fragment at the
    /// caret; drives the normalizer's whitespace-leading rejection.
    var wordPrefixIsValidWord: Bool = true

    private static func field(
        app: String, bundleID: String, role: String = "AXTextArea",
        preceding: String, trailing: String = "",
        windowTitle: String? = nil, placeholder: String? = nil
    ) -> CotypingField {
        CotypingField(
            appName: app, bundleID: bundleID, processID: 0, role: role,
            precedingText: preceding, trailingText: trailing, selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true,
            windowTitle: windowTitle, fieldPlaceholder: placeholder)
    }

    /// 26 scenarios in four groups: next-word continuations, word completions
    /// (the caret is mid-word and the suggestion must finish the word — the
    /// Cotypist parity gap), strictly-inside-word safety, and context/format
    /// robustness. Latency targets: 2000 ms for the cold first case, 1500 ms
    /// steady-state, 1200 ms for short mid-word prompts.
    static let defaults: [CotypingBenchmarkScenario] = [
        // — Next-word continuations —
        CotypingBenchmarkScenario(
            id: "email-follow-up", name: "Email follow-up",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hi Sarah,\nThanks for sending this over. I wanted to follow",
                windowTitle: "Re: Q3 planning"),
            expectedTerms: ["up", "today", "tomorrow", "with"],
            latencyTargetMs: 2_000),
        CotypingBenchmarkScenario(
            id: "chat-ownership", name: "Chat ownership",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Sounds good, I can take",
                windowTitle: "project-launch", placeholder: "Message #project-launch"),
            expectedTerms: ["that", "it", "this", "over", "care"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "browser-prose", name: "Browser prose",
            field: field(
                app: "Safari", bundleID: "com.apple.Safari",
                preceding: "The main tradeoff is",
                windowTitle: "Design note", placeholder: "Leave a comment"),
            expectedTerms: ["that", "between", "latency", "quality", "speed"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "email-update", name: "Email status update",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hi team,\nJust a quick update on the",
                windowTitle: "Weekly sync"),
            expectedTerms: ["project", "status", "progress", "launch", "release"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "email-scheduling", name: "Email scheduling",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Could we move our call to",
                windowTitle: "Re: catch-up"),
            expectedTerms: ["tomorrow", "next", "monday", "friday", "afternoon", "later"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "notes-list", name: "Notes list continuation",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "Top priorities for next week:\n1. Ship the beta\n2.",
                windowTitle: "Planning"),
            expectedTerms: ["fix", "review", "write", "prepare", "follow", "update"],
            latencyTargetMs: 1_500),

        // — Word completion: caret at the end of a fragment no dictionary word
        //   equals, so the ghost text MUST extend it (Cotypist parity) —
        CotypingBenchmarkScenario(
            id: "wc-follow", name: "Complete: follo→w",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hi Sarah,\nThanks for sending this over. I wanted to follo",
                windowTitle: "Re: Q3 planning"),
            expectedTerms: ["up"],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["w"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-conversation", name: "Complete: conversati→on",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Great catching up today — let's continue this conversati",
                windowTitle: "dm-alex"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["on"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-tomorrow", name: "Complete: tomorro→w",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "I'll send over the final report tomorro",
                windowTitle: "Re: deliverables"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["w"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-receive", name: "Complete: recei→ve",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Please let me know as soon as you recei",
                windowTitle: "Re: files"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["ve"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-productive", name: "Complete: producti→ve",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Thanks everyone, that was a really producti",
                windowTitle: "team-standup"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["ve"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-schedule", name: "Complete: schedu→le",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "Let me double-check my schedu",
                windowTitle: "Todo"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["le"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-important", name: "Complete: importa→nt",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "One more thing — this part is really importa",
                windowTitle: "project-launch"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["nt"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-weekend", name: "Complete: weeke→nd",
            field: field(
                app: "Messages", bundleID: "com.apple.MobileSMS",
                preceding: "Sounds great, have a lovely weeke",
                windowTitle: "Mom"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["nd"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-around", name: "Complete: aro→und",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "The budget for Q3 lands somewhere aro",
                windowTitle: "Re: budget"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["und"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-german", name: "Complete (de): Unterstüt→zung",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hallo Jonas,\nvielen Dank für deine Unterstüt",
                windowTitle: "AW: Projekt"),
            expectedTerms: [],
            latencyTargetMs: 1_500,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["zung"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "wc-long-context", name: "Complete in long email: revie→w",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Hi Priya,\n\nThanks for pulling the launch numbers together so quickly. "
                    + "The conversion funnel looks stronger than last quarter, and the retention "
                    + "curve is finally flattening where we hoped it would. Before we share this "
                    + "with the wider team I want to make sure the annotations are right, the "
                    + "cohort definitions match the dashboard, and the appendix links resolve. "
                    + "When you have a moment, could you please revie",
                windowTitle: "Re: launch metrics"),
            expectedTerms: [],
            latencyTargetMs: 2_000,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["w"],
            wordPrefixIsValidWord: false),

        // — Word fragments that are already valid words: both "extend the word"
        //   and "start the next word" are legitimate, so only visibility is
        //   asserted —
        CotypingBenchmarkScenario(
            id: "valid-fragment-the", name: "Valid fragment: the",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "I think we should discuss the",
                windowTitle: "Agenda"),
            expectedTerms: [],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "valid-fragment-can", name: "Valid fragment: can",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Absolutely, we can",
                windowTitle: "support-queue"),
            expectedTerms: [],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "valid-fragment-don", name: "Valid fragment: don('t)",
            field: field(
                app: "Messages", bundleID: "com.apple.MobileSMS",
                preceding: "I'm sure we'll figure it out, don",
                windowTitle: "Alex"),
            expectedTerms: [],
            latencyTargetMs: 1_200),

        // — Strictly inside a word (text after the caret): the suggestion must
        //   continue the word or stay quiet —
        CotypingBenchmarkScenario(
            id: "mid-word", name: "Mid-word safety",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "Please rec",
                trailing: "eive the files when ready.",
                windowTitle: "Project notes"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            allowedSuppressions: [.duplicatesTrailingText, .unsafeToInsert, .wordCompletionMismatch],
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["eive"],
            wordPrefixIsValidWord: false),
        CotypingBenchmarkScenario(
            id: "mid-word-budget", name: "Mid-word safety: bud|get",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "The quarterly bud",
                trailing: "get review is next Thursday.",
                windowTitle: "Finance"),
            expectedTerms: [],
            latencyTargetMs: 1_200,
            allowedSuppressions: [.duplicatesTrailingText, .unsafeToInsert, .wordCompletionMismatch],
            expectsWordCompletion: true,
            expectedCompletionPrefixes: ["get"],
            wordPrefixIsValidWord: false),

        // — Context and format robustness —
        CotypingBenchmarkScenario(
            id: "question", name: "Question continuation",
            field: field(
                app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                preceding: "Could you send over the final version before",
                windowTitle: "design-review"),
            expectedTerms: ["friday", "monday", "tomorrow", "end", "meeting", "we"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "bullet-list", name: "Bullet list item",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "Shopping list:\n- milk\n- eggs\n- ",
                windowTitle: "Groceries"),
            expectedTerms: ["bread", "butter", "cheese", "flour", "sugar", "coffee"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "support-reply", name: "Support reply",
            field: field(
                app: "Safari", bundleID: "com.apple.Safari",
                preceding: "Hi! Sorry for the trouble — I've reset your account and you should",
                windowTitle: "Helpdesk", placeholder: "Reply"),
            expectedTerms: ["be able", "now", "receive", "see", "get"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "german-prose", name: "German continuation",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "Vielen Dank für deine Nachricht. Ich melde mich",
                windowTitle: "AW: Termin"),
            expectedTerms: ["morgen", "später", "nächste", "sobald", "bald", "bei"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "comma-clause", name: "Comma clause continuation",
            field: field(
                app: "Mail", bundleID: "com.apple.mail",
                preceding: "If the numbers hold up through Friday,",
                windowTitle: "Re: forecast"),
            expectedTerms: ["we", "then", "i", "the"],
            latencyTargetMs: 1_500),
        CotypingBenchmarkScenario(
            id: "sentence-start", name: "Fresh sentence start",
            field: field(
                app: "Notes", bundleID: "com.apple.Notes",
                preceding: "The rollout went smoothly overall. ",
                windowTitle: "Retro"),
            expectedTerms: ["we", "the", "there", "a few", "next"],
            latencyTargetMs: 1_500),
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
    var expectedWordCompletion: Bool = false
    var expectedCompletionPrefixes: [String] = []

    var passedSafety: Bool {
        guard error == nil else { return false }
        if expectedWordCompletion {
            // The ghost text must extend the fragment at the caret: no leading
            // whitespace, and the expected word tail when one is specified. A
            // suppressed (empty) result passes only when explicitly allowed.
            let trimmedEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if trimmedEmpty { return allowedSuppression }
            guard let first = text.first, first.isLetter || first.isNumber else { return false }
            guard !expectedCompletionPrefixes.isEmpty else { return true }
            let folded = text.lowercased()
            return expectedCompletionPrefixes.contains { folded.hasPrefix($0.lowercased()) }
        }
        if expectedVisibleSuggestion {
            return suppression == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && allowedSuppression
    }

    /// True when the suggestion extends the caret fragment (word-completion
    /// scenarios only) — surfaced separately so summaries can report the
    /// Cotypist-parity rate on its own.
    var wordCompletionHit: Bool {
        expectedWordCompletion && !text.isEmpty && passedSafety
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

    /// Cotypist-parity signal: of the scenarios that demand a word completion,
    /// how many produced a suggestion that extends the typed fragment.
    var wordCompletionTotal: Int { results.filter(\.expectedWordCompletion).count }
    var wordCompletionPassed: Int { results.filter(\.wordCompletionHit).count }

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

/// Machine-readable rendering for `LokalBot --cotyping-bench` — the scriptable
/// evaluation model consumed by `Benchmarks/Cotyping/side_by_side.py`.
extension CotypingBenchmarkSummary {
    private struct CaseJSON: Codable {
        let id: String
        let name: String
        let text: String
        let latencyMs: Int
        let firstVisibleLatencyMs: Int?
        let suppression: String?
        let error: String?
        let passedSafety: Bool
        let metLatencyTarget: Bool
        let expectedTermHits: Int
        let expectedTermCount: Int
        let expectsWordCompletion: Bool
        let wordCompletionHit: Bool
    }

    private struct ReportJSON: Codable {
        let total: Int
        let passed: Int
        let safetyPassed: Int
        let keywordHits: Int
        let keywordTotal: Int
        let wordCompletionPassed: Int
        let wordCompletionTotal: Int
        let averageLatencyMs: Int?
        let p95LatencyMs: Int?
        let averageFirstVisibleLatencyMs: Int?
        let scenarios: [CaseJSON]
    }

    func jsonReport() -> String {
        let report = ReportJSON(
            total: total,
            passed: passed,
            safetyPassed: safetyPassed,
            keywordHits: keywordHits,
            keywordTotal: keywordTotal,
            wordCompletionPassed: wordCompletionPassed,
            wordCompletionTotal: wordCompletionTotal,
            averageLatencyMs: averageLatencyMs,
            p95LatencyMs: p95LatencyMs,
            averageFirstVisibleLatencyMs: averageFirstVisibleLatencyMs,
            scenarios: results.map { result in
                CaseJSON(
                    id: result.scenarioID,
                    name: result.name,
                    text: result.text,
                    latencyMs: result.latencyMs,
                    firstVisibleLatencyMs: result.firstVisibleLatencyMs,
                    suppression: result.suppression?.rawValue,
                    error: result.error,
                    passedSafety: result.passedSafety,
                    metLatencyTarget: result.metLatencyTarget,
                    expectedTermHits: result.expectedTermHits,
                    expectedTermCount: result.expectedTermCount,
                    expectsWordCompletion: result.expectedWordCompletion,
                    wordCompletionHit: result.wordCompletionHit)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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
            expectedWordCompletion: scenario.expectsWordCompletion,
            expectedCompletionPrefixes: scenario.expectedCompletionPrefixes,
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
            learnedExamples: learnedExamples,
            wordPrefixIsValidWord: scenario.wordPrefixIsValidWord)
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
