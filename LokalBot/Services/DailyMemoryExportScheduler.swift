import Foundation

/// Lightweight wall-clock scheduler for the optional daily Markdown export.
/// The app normally lives in the menu bar, so a minute tick is sufficient and
/// remains correct across sleep/wake and daylight-saving changes.
@MainActor
final class DailyMemoryExportScheduler {
    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        var hour: Int
        /// Folder + format identity. Changing either should export to the new
        /// destination even when today's prior destination already succeeded.
        var destinationID: String

        var normalizedHour: Int { min(23, max(0, hour)) }
    }

    typealias Export = @Sendable (Date) async throws -> Void

    private let calendar: Calendar
    private let now: () -> Date
    private var configuration: Configuration?
    private var export: Export?
    private var timer: Timer?
    private var exportTask: Task<Void, Never>?
    private var lastSuccessfulDay: Date?
    private var lastAttempt: Date?
    private var errorHandler: ((String) -> Void)?
    private var generation = 0

    init(calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
    }

    func configure(
        _ configuration: Configuration,
        export: @escaping Export,
        onError: @escaping (String) -> Void
    ) {
        let changed = self.configuration != configuration
        self.configuration = configuration
        self.export = export
        errorHandler = onError
        if changed {
            generation &+= 1
            exportTask?.cancel()
            exportTask = nil
            lastAttempt = nil
            lastSuccessfulDay = nil
        }
        timer?.invalidate()
        timer = nil
        guard configuration.enabled, !configuration.destinationID.isEmpty else { return }
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
        exportTask?.cancel()
        exportTask = nil
    }

    func tick() {
        guard exportTask == nil,
              let configuration,
              configuration.enabled,
              !configuration.destinationID.isEmpty,
              let export else { return }
        let current = now()
        guard Self.shouldRun(
            at: current,
            hour: configuration.normalizedHour,
            lastSuccessfulDay: lastSuccessfulDay,
            calendar: calendar) else { return }
        // A failed filesystem write should be visible but not retried every
        // minute. Fifteen minutes gives removable/network volumes time to return.
        if let lastAttempt, current.timeIntervalSince(lastAttempt) < 15 * 60 { return }
        lastAttempt = current
        let runGeneration = generation
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The scheduler owns a structured utility-priority child. A
                // configure/stop cancellation therefore reaches the actual
                // filesystem worker instead of only cancelling an outer task
                // that is awaiting an unstructured detached task.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask(priority: .utility) {
                        try Task.checkCancellation()
                        try await export(current)
                    }
                    try await group.waitForAll()
                }
                guard !Task.isCancelled else { return }
                guard generation == runGeneration else { return }
                lastSuccessfulDay = calendar.startOfDay(for: current)
            } catch is CancellationError {
            } catch {
                if generation == runGeneration {
                    errorHandler?("Daily memory export failed: \(error.localizedDescription)")
                }
            }
            if generation == runGeneration {
                exportTask = nil
            }
        }
    }

    nonisolated static func shouldRun(
        at date: Date,
        hour: Int,
        lastSuccessfulDay: Date?,
        calendar: Calendar
    ) -> Bool {
        let day = calendar.startOfDay(for: date)
        if let lastSuccessfulDay,
           calendar.isDate(lastSuccessfulDay, inSameDayAs: day) {
            return false
        }
        let target = calendar.date(bySettingHour: min(23, max(0, hour)),
                                   minute: 0, second: 0, of: date)
            ?? day
        return date >= target
    }
}
