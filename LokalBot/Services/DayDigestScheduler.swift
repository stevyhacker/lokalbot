import Foundation

/// Wall-clock scheduler for the automatic day digest. Same minute-tick design
/// as `DailyMemoryExportScheduler` (correct across sleep/wake and DST), with
/// two digest-specific twists:
///
/// - the durable once-per-day marker is the journal file's modification time:
///   written at/after today's scheduled hour means done (survives relaunch,
///   and a manual regenerate after the hour counts too), while a digest the
///   user generated in the morning is refreshed at the scheduled hour with
///   the fuller day;
/// - a day with nothing to digest yet is not a failure — the generate closure
///   reports it and the scheduler simply retries on a later tick, so a
///   meeting that ends at 19:00 still gets digested the same evening.
@MainActor
final class DayDigestScheduler {
    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        /// Local wall-clock hour (0...23) after which today's digest is
        /// generated.
        var hour: Int

        var normalizedHour: Int { min(23, max(0, hour)) }
    }

    /// Generates and persists the digest for the day containing `date`.
    /// Returns `false` when the day has nothing to digest yet; the scheduler
    /// retries on a later tick without burning the failure backoff.
    typealias Generate = @MainActor (Date) async throws -> Bool

    private let calendar: Calendar
    private let now: () -> Date
    private var configuration: Configuration?
    private var digestModifiedAt: ((Date) -> Date?)?
    private var canRun: () -> Bool = { true }
    private var generate: Generate?
    private var errorHandler: ((String) -> Void)?
    private var timer: Timer?
    private var generateTask: Task<Void, Never>?
    private var lastFailure: Date?
    private var generation = 0

    init(calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
    }

    func configure(
        _ configuration: Configuration,
        digestModifiedAt: @escaping (Date) -> Date?,
        canRun: @escaping () -> Bool,
        generate: @escaping Generate,
        onError: @escaping (String) -> Void
    ) {
        let changed = self.configuration != configuration
        self.configuration = configuration
        self.digestModifiedAt = digestModifiedAt
        self.canRun = canRun
        self.generate = generate
        errorHandler = onError
        if changed {
            generation &+= 1
            generateTask?.cancel()
            generateTask = nil
            lastFailure = nil
        }
        timer?.invalidate()
        timer = nil
        guard configuration.enabled else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        generateTask?.cancel()
        generateTask = nil
    }

    func tick() {
        guard generateTask == nil,
              let configuration,
              configuration.enabled,
              let digestModifiedAt,
              let generate else { return }
        let current = now()
        guard Self.shouldRun(
            at: current,
            hour: configuration.normalizedHour,
            digestModifiedAt: digestModifiedAt(current),
            calendar: calendar) else { return }
        // A failed generation (model unreachable, disk error) should be
        // visible but not retried every minute; generation itself can take a
        // while, so give the system room between attempts.
        if let lastFailure, current.timeIntervalSince(lastFailure) < 15 * 60 { return }
        // Not downtime yet — recording, processing, dictation, or cotyping is
        // active. Don't burn the backoff; just wait for a quieter tick.
        guard canRun() else { return }
        let runGeneration = generation
        generateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // `false` means the day is still empty: the journal file is
                // not written, so the marker stays absent and a later tick
                // retries once the day has content.
                _ = try await generate(current)
                if generation == runGeneration { lastFailure = nil }
            } catch is CancellationError {
            } catch {
                if generation == runGeneration {
                    lastFailure = self.now()
                    errorHandler?("Day digest failed: \(error.localizedDescription)")
                }
            }
            if generation == runGeneration { generateTask = nil }
        }
    }

    /// Pure policy: run once the clock passes today's configured hour, unless
    /// the journal file was already written at/after that time. A morning
    /// manual digest (mtime before the target) is refreshed; an evening one
    /// (manual or scheduled) suppresses the run for the rest of the day.
    nonisolated static func shouldRun(
        at date: Date,
        hour: Int,
        digestModifiedAt: Date?,
        calendar: Calendar
    ) -> Bool {
        let target = calendar.date(bySettingHour: min(23, max(0, hour)),
                                   minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
        guard date >= target else { return false }
        if let digestModifiedAt, digestModifiedAt >= target { return false }
        return true
    }
}
