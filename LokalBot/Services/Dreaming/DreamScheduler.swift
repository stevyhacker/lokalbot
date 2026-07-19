import Foundation

/// Wall-clock scheduler for the overnight dream. Same minute-tick design as
/// `DailyMemoryExportScheduler` (correct across sleep/wake and DST), with two
/// dreaming-specific twists:
///
/// - the durable once-per-day marker is the report file itself (via the
///   injected `hasReport`), so a night the Mac slept through is caught up at
///   the next launch or wake, right before the user opens Today;
/// - a `canRun` downtime gate keeps the dream from competing with recording,
///   processing, dictation, or cotyping — it simply waits for the next tick.
@MainActor
final class DreamScheduler: ObservableObject {
    /// Match screen-memory's definition of an inactive session: no keyboard,
    /// pointer, or other combined-session input for three minutes.
    nonisolated static let minimumSystemIdleSeconds: TimeInterval = 180

    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        /// Local wall-clock hour (0...23) after which the previous day may be
        /// dreamed. Before it, the previous day is considered still "in use"
        /// (a late session past midnight belongs to the evening's context).
        var hour: Int

        var normalizedHour: Int { min(23, max(0, hour)) }
    }

    typealias Dream = @MainActor (_ day: Date) async throws -> Void

    @Published private(set) var isDreaming = false
    @Published private(set) var lastDreamedAt: Date?
    @Published private(set) var lastError: String?

    private let calendar: Calendar
    private let now: () -> Date
    private var configuration: Configuration?
    private var dream: Dream?
    private var hasReport: ((String) -> Bool)?
    private var canRun: () -> Bool = { true }
    private var errorHandler: ((String) -> Void)?
    private var timer: Timer?
    private var dreamTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private var generation = 0

    init(calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
    }

    func configure(
        _ configuration: Configuration,
        hasReport: @escaping (String) -> Bool,
        canRun: @escaping () -> Bool,
        dream: @escaping Dream,
        onError: @escaping (String) -> Void
    ) {
        let changed = self.configuration != configuration
        self.configuration = configuration
        self.hasReport = hasReport
        self.canRun = canRun
        self.dream = dream
        errorHandler = onError
        if changed {
            generation &+= 1
            dreamTask?.cancel()
            dreamTask = nil
            isDreaming = false
            lastAttempt = nil
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
        dreamTask?.cancel()
        dreamTask = nil
        isDreaming = false
    }

    func tick() {
        guard dreamTask == nil,
              let configuration,
              configuration.enabled,
              let hasReport,
              dream != nil else { return }
        let current = now()
        let target = Self.previousDay(of: current, calendar: calendar)
        guard Self.shouldRun(
            at: current,
            hour: configuration.normalizedHour,
            hasReportForPreviousDay: hasReport(DreamDay.key(for: target, calendar: calendar)),
            calendar: calendar) else { return }
        // A failed dream (model unreachable mid-boot, disk error) should be
        // visible but not retried every minute; generation can also take a
        // while, so give the system room between attempts.
        if let lastAttempt, current.timeIntervalSince(lastAttempt) < 15 * 60 { return }
        // Not downtime yet — recording, processing, dictation, or cotyping is
        // active. Don't burn the backoff; just wait for a quieter tick.
        guard canRun() else { return }
        lastAttempt = current
        start(day: target)
    }

    /// Manual run from Settings: ignores the hour, the existing report (the
    /// day is re-dreamed and its files replaced), and the downtime gate — the
    /// user explicitly asked. Still one dream at a time.
    func dreamNow() {
        guard dreamTask == nil,
              let configuration,
              configuration.enabled,
              dream != nil else { return }
        start(day: Self.previousDay(of: now(), calendar: calendar))
    }

    private func start(day: Date) {
        guard let dream else { return }
        let runGeneration = generation
        isDreaming = true
        lastError = nil
        dreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await dream(day)
                guard !Task.isCancelled, generation == runGeneration else { return }
                lastDreamedAt = now()
            } catch is CancellationError {
            } catch {
                guard generation == runGeneration else { return }
                let message = "Dreaming failed: \(error.localizedDescription)"
                lastError = message
                errorHandler?(message)
            }
            guard generation == runGeneration else { return }
            isDreaming = false
            dreamTask = nil
        }
    }

    /// The day a dream analyzes: the local calendar day before `date`.
    nonisolated static func previousDay(of date: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -1, to: today)
            ?? today.addingTimeInterval(-86_400)
    }

    /// Run once the clock passes today's configured hour, unless the previous
    /// day already has a report. No same-day memory needed: writing the report
    /// flips `hasReportForPreviousDay` durably.
    nonisolated static func shouldRun(
        at date: Date,
        hour: Int,
        hasReportForPreviousDay: Bool,
        calendar: Calendar
    ) -> Bool {
        guard !hasReportForPreviousDay else { return false }
        let target = calendar.date(bySettingHour: min(23, max(0, hour)),
                                   minute: 0, second: 0, of: date)
            ?? calendar.startOfDay(for: date)
        return date >= target
    }

    nonisolated static func isSystemIdle(
        for idleSeconds: TimeInterval,
        minimum: TimeInterval = minimumSystemIdleSeconds
    ) -> Bool {
        idleSeconds.isFinite && idleSeconds >= max(0, minimum)
    }
}
