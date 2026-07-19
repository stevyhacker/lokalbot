import Foundation

/// What one night's synthesis proposed: the retrospective sections plus the
/// full updated memory lists. Pure data — `DreamService` turns it into a
/// `DreamReport` and merges the memory update deterministically.
struct DreamSynthesis: Equatable {
    var narrative: String
    var attention: [String]
    var repeatedWork: [String]
    var suggestedChecks: [String]
    var frictions: [String]
    var topActions: [String]
    var memory: DreamMemoryUpdate

    var isEmpty: Bool {
        narrative.isEmpty && attention.isEmpty && repeatedWork.isEmpty
            && suggestedChecks.isEmpty && frictions.isEmpty && topActions.isEmpty
            && memory.isEmpty
    }

    func report(dayKey: String, generatedAt: Date, engineName: String) -> DreamReport {
        DreamReport(
            day: dayKey,
            generatedAt: generatedAt,
            engineName: engineName,
            narrative: narrative,
            attention: attention,
            repeatedWork: repeatedWork,
            suggestedChecks: suggestedChecks,
            frictions: frictions,
            topActions: topActions)
    }
}

/// Prompt, JSON schema, and tolerant parsing for the overnight dream pass.
/// Same split as `OutcomesExtractor`: grammar-constrained backends get the
/// schema, unconstrained ones rely on the prompt's shape plus the tolerant
/// parse, and everything here is pure so it tests without an engine.
enum DreamPrompts {
    static let maxListItems = 8
    static let maxTopActions = 3
    static let maxLineCharacters = 400

    static let system = """
    You are LokalBot's overnight "dreaming" pass: a read-only retrospective of \
    the user's previous local calendar day, computed entirely on their Mac. You \
    receive that day's evidence (meetings with extracted outcomes, the day \
    digest, app-time totals, saved moments), up to 14 preceding days as a \
    comparison window only, and the current structured work memory. Reply with \
    ONLY a JSON object of this exact shape:
    {"narrative": "...", "attention": ["..."], "repeated_work": ["..."], \
    "suggested_checks": ["..."], "frictions": ["..."], "top_actions": ["..."], \
    "active_projects": [{"name": "...", "status": "...", "evidence": ["..."]}], \
    "work_goals": [{"text": "...", "horizon": "..."}], "recurring_patterns": ["..."]}

    Rules:
    - Analysis and recommendations only. You changed nothing and must never claim otherwise.
    - Distinguish verified facts from inference: prefix inferred items with "Likely:".
    - Cite meeting IDs in backticks exactly as given in the evidence. Never invent \
    activity, names, numbers, or meetings.
    - narrative: 2-4 sentences on how the day actually went. If evidence is sparse, \
    say so plainly instead of padding.
    - attention: critical issues or regressions deserving attention first, most \
    severe first, each with its evidence.
    - repeated_work: manual work that recurred and could be automated further.
    - suggested_checks: recurring review tasks worth adopting where the evidence \
    shows regressions, each with a suggested cadence.
    - frictions: quality or UX improvements suggested by rework, confusion, weak \
    validation, or friction in the day's work.
    - top_actions: the top three actions to consider today, ranked by expected \
    leverage. At most three.
    - active_projects, work_goals, recurring_patterns: return the FULL updated \
    memory. Update statuses from the day's evidence, add new entries only with \
    clear evidence, keep entries you still believe active even if untouched \
    today, and drop an entry only when the evidence shows it finished.
    - Keep every string to one short sentence. Use empty arrays when nothing \
    qualifies — generic advice is worse than an empty list.
    """

    /// JSON schema matching `system`'s shape for grammar-constrained backends.
    static var schema: [String: Any] {
        let stringList: [String: Any] = ["type": "array", "items": ["type": "string"]]
        return [
            "type": "object",
            "properties": [
                "narrative": ["type": "string"],
                "attention": stringList,
                "repeated_work": stringList,
                "suggested_checks": stringList,
                "frictions": stringList,
                "top_actions": stringList,
                "active_projects": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "status": ["type": "string"],
                            "evidence": stringList,
                        ],
                        "required": ["name", "status", "evidence"],
                    ],
                ],
                "work_goals": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "horizon": ["type": "string"],
                        ],
                        "required": ["text", "horizon"],
                    ],
                ],
                "recurring_patterns": stringList,
            ],
            "required": ["narrative", "attention", "repeated_work", "suggested_checks",
                         "frictions", "top_actions", "active_projects", "work_goals",
                         "recurring_patterns"],
        ]
    }

    static func prompt(evidence: DreamEvidence) -> String {
        "Conduct the retrospective of \(evidence.dayKey) from this evidence:\n\n"
            + DreamCompiler.evidencePack(evidence)
    }

    static func context(evidence: DreamEvidence, memory: DreamMemory) -> [String] {
        var context = [
            "Analyzed day: \(evidence.day.formatted(date: .complete, time: .omitted))",
        ]
        if memory.isEmpty {
            context.append("Current structured work memory: empty — this is the first dream.")
        } else {
            context.append("Current structured work memory:\n"
                + PromptContextSanitizer.sanitize(memory.markdown(), maxCharacters: 6_000))
        }
        return context
    }

    /// Tolerant parse of the model's reply: balanced-brace JSON extraction,
    /// per-line cleanup, and hard caps so a rambling model can't oversize the
    /// report or the memory. Nil when no usable object is found, which sends
    /// the service down the deterministic fallback path.
    static func parse(_ output: String) -> DreamSynthesis? {
        guard let json = ChatPrompt.extractJSONObject(strippingReasoning(output)),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let projects = (object["active_projects"] as? [Any] ?? [])
            .prefix(DreamMemory.maxProjects)
            .compactMap { raw -> DreamMemoryUpdate.Project? in
                guard let item = raw as? [String: Any],
                      let name = cleaned(item["name"]) else { return nil }
                return DreamMemoryUpdate.Project(
                    name: name,
                    status: cleaned(item["status"]) ?? "",
                    evidence: Array(strings(item["evidence"])
                        .prefix(DreamMemory.maxEvidencePerProject)))
            }
        let goals = (object["work_goals"] as? [Any] ?? [])
            .prefix(DreamMemory.maxGoals)
            .compactMap { raw -> DreamMemoryUpdate.Goal? in
                guard let item = raw as? [String: Any],
                      let text = cleaned(item["text"]) else { return nil }
                return DreamMemoryUpdate.Goal(text: text, horizon: cleaned(item["horizon"]) ?? "")
            }
        let synthesis = DreamSynthesis(
            narrative: cleaned(object["narrative"], cap: 1_200) ?? "",
            attention: list(object["attention"]),
            repeatedWork: list(object["repeated_work"]),
            suggestedChecks: list(object["suggested_checks"]),
            frictions: list(object["frictions"]),
            topActions: Array(list(object["top_actions"]).prefix(maxTopActions)),
            memory: DreamMemoryUpdate(
                activeProjects: Array(projects),
                workGoals: Array(goals),
                recurringPatterns: Array(strings(object["recurring_patterns"])
                    .prefix(DreamMemory.maxPatterns))))
        return synthesis.isEmpty ? nil : synthesis
    }

    private static func list(_ value: Any?) -> [String] {
        Array(strings(value).prefix(maxListItems))
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { cleaned($0) }
    }

    private static func cleaned(_ value: Any?, cap: Int = maxLineCharacters) -> String? {
        guard let raw = value as? String else { return nil }
        let collapsed = raw.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > cap ? String(collapsed.prefix(cap)) + "…" : collapsed
    }
}
