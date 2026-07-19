import Foundation

/// One night's dream, end to end: compile the previous day's evidence, ask
/// the Main LLM engine for the retrospective + memory update, merge and
/// persist. When no model is reachable the deterministic evidence-only brief
/// is written instead — the morning surface is never empty, and the report
/// itself says which kind it is. Evidence comes from the local library;
/// generation follows the configured Main LLM privacy boundary (on-device or
/// an explicitly approved remote origin), and artifacts land inside the
/// storage root.
struct DreamService {
    typealias EngineSelection = (
        engine: TextEngine,
        provenance: DreamInferenceProvenance
    )

    var storageRoot: URL
    /// Resolved per-dream so backend/model changes apply to the next night;
    /// same seam as chat/dictation (`ProcessingPipeline.makeTextEngine`).
    var makeEngine: () async throws -> EngineSelection
    var calendar: Calendar = .current
    var now: () -> Date = Date.init

    @discardableResult
    func dream(day: Date) async throws -> DreamReport {
        let root = storageRoot
        let dreamCalendar = calendar
        // Evidence compilation walks the whole meeting library; keep that off
        // the main actor (the scheduler calls this from a MainActor task).
        let evidence = try await Task.detached(priority: .utility) {
            try DreamCompiler.compile(day: day, storageRoot: root, calendar: dreamCalendar)
        }.value
        try Task.checkCancellation()

        let store = DreamStore(root: storageRoot)
        let memory = store.loadMemory() ?? DreamMemory(updatedAt: now())
        var report: DreamReport
        var updatedMemory = memory

        do {
            let selection = try await makeEngine()
            let output = try await selection.engine.generate(
                system: DreamPrompts.system,
                prompt: DreamPrompts.prompt(evidence: evidence),
                context: DreamPrompts.context(evidence: evidence, memory: memory),
                schema: DreamPrompts.schema)
            try Task.checkCancellation()
            if let synthesis = DreamPrompts.parse(output) {
                report = synthesis.report(dayKey: evidence.dayKey,
                                          generatedAt: now(),
                                          engineName: selection.engine.displayName,
                                          inferenceProvenance: selection.provenance)
                updatedMemory = memory.merging(synthesis.memory,
                                               dreamDay: evidence.dayKey,
                                               at: now(),
                                               calendar: calendar)
            } else {
                lokalbotLog("dreaming: model reply was unparseable, writing evidence-only brief")
                report = DreamCompiler.fallbackReport(
                    from: evidence, generatedAt: now(),
                    reason: .unparseableResponse,
                    note: "The model's reply could not be read, so this brief lists evidence only.")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Engine unavailable (no model prepared, server down, remote origin
            // unapproved…). Still deliver the morning surface — evidence only,
            // memory untouched — and mark the day done so the scheduler doesn't
            // hammer a broken backend all night. "Dream now" can redo the day.
            lokalbotLog("dreaming: engine unavailable, writing evidence-only brief error=\(error.localizedDescription)")
            report = DreamCompiler.fallbackReport(
                from: evidence, generatedAt: now(),
                reason: .engineUnavailable,
                note: "No model was reachable overnight, so this brief lists evidence only.")
        }

        report = report.redacted()
        updatedMemory.lastDreamDay = evidence.dayKey
        updatedMemory.updatedAt = now()
        updatedMemory = updatedMemory.redacted()

        try Task.checkCancellation()
        try store.save(report: report, memory: updatedMemory)
        return report
    }
}
