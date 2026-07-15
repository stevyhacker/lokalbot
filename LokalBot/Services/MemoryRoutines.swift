import Foundation
import SQLite3

struct MemoryRoutineRunRecord: Identifiable, Equatable, Sendable {
    var id: Int64
    var kind: AppSettings.MemoryRoutineKind
    var runToken: String
    var startedAt: Date
    var completedAt: Date?
    var status: String
    var outputPath: String?
    var error: String?
    var meetingID: UUID?
}

/// Durable audit trail for every routine attempt. A `running` row left by a
/// crash is intentionally not success, so the scheduler can retry it after the
/// next launch instead of silently losing a due output.
final class MemoryRoutineRunStore {
    private let database: SQLiteDatabase?
    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
        database = SQLiteDatabase(url: databaseURL)
        do {
            try requiredDatabase().execute("""
                CREATE TABLE IF NOT EXISTS memory_routine_runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    run_token TEXT NOT NULL UNIQUE,
                    started_at REAL NOT NULL,
                    completed_at REAL,
                    status TEXT NOT NULL,
                    output_path TEXT NOT NULL DEFAULT '',
                    error TEXT NOT NULL DEFAULT '',
                    meeting_id TEXT NOT NULL DEFAULT '');
                CREATE INDEX IF NOT EXISTS idx_memory_routine_runs_started
                    ON memory_routine_runs(started_at DESC);
                """)
        } catch {
            lokalbotLog("routine history initialization failed: \(error.localizedDescription)")
        }
    }

    func hasSucceeded(runToken: String) -> Bool {
        do {
            return try requiredDatabase().hasRowChecked("""
                SELECT 1 FROM memory_routine_runs
                WHERE run_token = ?1 AND status = 'succeeded' LIMIT 1
                """, bind: [runToken])
        } catch {
            lokalbotLog("routine history lookup failed: \(error.localizedDescription)")
            return false
        }
    }

    /// A scheduled token is terminal after either success or failure. This
    /// prevents a bad destination or malformed source from becoming a tight
    /// retry loop; manual runs use unique tokens and remain available. A stale
    /// `running` row is deliberately non-terminal so launch recovery can retry.
    func hasFinished(runToken: String) -> Bool {
        do {
            return try requiredDatabase().hasRowChecked("""
                SELECT 1 FROM memory_routine_runs
                WHERE run_token = ?1 AND status IN ('succeeded', 'failed') LIMIT 1
                """, bind: [runToken])
        } catch {
            lokalbotLog("routine history lookup failed: \(error.localizedDescription)")
            return false
        }
    }

    func begin(
        kind: AppSettings.MemoryRoutineKind,
        runToken: String,
        meetingID: UUID?,
        at date: Date
    ) throws -> Int64 {
        let database = try requiredDatabase()
        try database.runChecked("""
            INSERT INTO memory_routine_runs (
                kind, run_token, started_at, completed_at, status,
                output_path, error, meeting_id
            ) VALUES (?1, ?2, ?3, NULL, 'running', '', '', ?4)
            ON CONFLICT(run_token) DO UPDATE SET
                started_at = excluded.started_at,
                completed_at = NULL,
                status = 'running',
                output_path = '',
                error = '',
                meeting_id = excluded.meeting_id
            """, bind: [kind.rawValue, runToken, date.timeIntervalSince1970,
                          meetingID?.uuidString ?? ""])
        guard let id: Int64 = try database.queryChecked(
            "SELECT id FROM memory_routine_runs WHERE run_token = ?1 LIMIT 1",
            bind: [runToken],
            row: { sqlite3_column_int64($0, 0) }).first else {
            throw SQLiteDatabase.DatabaseError.step(
                sql: nil, code: SQLITE_CORRUPT,
                message: "routine run insert did not produce a row id")
        }
        return id
    }

    func finish(id: Int64, outputURL: URL?, error: Error?, at date: Date) {
        do {
            try requiredDatabase().runChecked("""
                UPDATE memory_routine_runs
                SET completed_at = ?1, status = ?2, output_path = ?3, error = ?4
                WHERE id = ?5
                """, bind: [
                    date.timeIntervalSince1970,
                    error == nil ? "succeeded" : "failed",
                    outputURL?.path ?? "",
                    error?.localizedDescription ?? "",
                    id,
                ])
        } catch {
            lokalbotLog("routine history completion failed: \(error.localizedDescription)")
        }
    }

    func recent(limit: Int = 12) -> [MemoryRoutineRunRecord] {
        do {
            return try requiredDatabase().queryChecked("""
                SELECT id, kind, run_token, started_at, completed_at, status,
                       output_path, error, meeting_id
                FROM memory_routine_runs ORDER BY started_at DESC LIMIT \(max(1, limit))
                """) { statement -> MemoryRoutineRunRecord? in
                guard let kindText = sqlite3_column_text(statement, 1),
                      let kind = AppSettings.MemoryRoutineKind(
                        rawValue: String(cString: kindText)) else { return nil }
                let completed = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                let output = Self.optionalText(statement, 6)
                let error = Self.optionalText(statement, 7)
                let meetingID = Self.optionalText(statement, 8).flatMap(UUID.init(uuidString:))
                return MemoryRoutineRunRecord(
                    id: sqlite3_column_int64(statement, 0),
                    kind: kind,
                    runToken: String(cString: sqlite3_column_text(statement, 2)),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    completedAt: completed,
                    status: String(cString: sqlite3_column_text(statement, 5)),
                    outputPath: output,
                    error: error,
                    meetingID: meetingID)
            }
        } catch {
            lokalbotLog("routine history read failed: \(error.localizedDescription)")
            return []
        }
    }

    func runningCount() -> Int {
        do {
            return Int(try requiredDatabase().firstDoubleChecked("""
                SELECT COUNT(*) FROM memory_routine_runs WHERE status = 'running'
                """) ?? 0)
        } catch {
            return 0
        }
    }

    private func requiredDatabase() throws -> SQLiteDatabase {
        guard let database else {
            throw SQLiteDatabase.DatabaseError.unavailable(path: databaseURL.path)
        }
        return database
    }

    private static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
}

enum MemoryRoutineError: LocalizedError {
    case destinationCollision(URL)
    case unsafeDestination(URL)
    case missingMeeting
    case timedOut

    var errorDescription: String? {
        switch self {
        case .destinationCollision(let url):
            "Routine output stopped because \(url.lastPathComponent) already exists with different content. The existing file was preserved."
        case .unsafeDestination(let url):
            "Routine output stopped because \(url.path) resolves outside the chosen folder or through a file symlink."
        case .missingMeeting:
            "The meeting needed by this routine is no longer in the local library."
        case .timedOut:
            "The routine exceeded its 30-second safety limit."
        }
    }
}

/// Fixed-scope local renderers. They do not invoke a shell, contact a network,
/// mutate meeting data, or accept arbitrary prompts. The sole write is one
/// private Markdown file under the user-selected destination.
enum MemoryRoutineRunner {
    static let generatedMarker = "<!-- Generated by LokalBot routine. -->"

    static func run(
        kind: AppSettings.MemoryRoutineKind,
        referenceDate: Date,
        storageRoot: URL,
        destinationRoot: URL,
        meetingID: UUID?,
        calendar: Calendar = .current
    ) throws -> URL {
        try Task.checkCancellation()
        let storage = StorageManager(rootURL: storageRoot)
        let meetings = try SessionLookup.loadAllMeetings(root: storageRoot)
        try Task.checkCancellation()

        let output: (folder: String, file: String, text: String)
        switch kind {
        case .postMeetingFollowUp:
            guard let meetingID,
                  let meeting = meetings.first(where: { $0.id == meetingID }) else {
                throw MemoryRoutineError.missingMeeting
            }
            output = (
                "Post-meeting follow-ups",
                timestampKey(meeting.startedAt, calendar: calendar)
                    + "-\(SessionLookup.shortID(meeting.id))-follow-up.md",
                postMeeting(meeting, storage: storage))
        case .dailyStandup:
            output = (
                "Daily stand-ups",
                dayKey(referenceDate, calendar: calendar) + "-stand-up.md",
                try dailyStandup(
                    referenceDate, meetings: meetings, storage: storage,
                    storageRoot: storageRoot, calendar: calendar))
        case .weeklyWorkLog:
            output = (
                "Weekly work logs",
                dayKey(referenceDate, calendar: calendar) + "-work-log.md",
                try weeklyWorkLog(
                    referenceDate, meetings: meetings, storage: storage,
                    storageRoot: storageRoot, calendar: calendar))
        case .unfinishedActions:
            output = (
                "Unfinished actions",
                dayKey(referenceDate, calendar: calendar) + "-actions.md",
                unfinishedActions(
                    referenceDate, meetings: meetings, storage: storage,
                    calendar: calendar))
        case .localJournal:
            output = (
                "Journal",
                dayKey(referenceDate, calendar: calendar) + ".md",
                try localJournal(
                    referenceDate, storageRoot: storageRoot, calendar: calendar))
        }

        try Task.checkCancellation()
        let redacted = ScreenContextPrivacy.redact(output.text).text
        let body = generatedMarker + "\n\n" + redacted.trimmingCharacters(
            in: .whitespacesAndNewlines) + "\n"
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destinationRoot.path) {
            try fileManager.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let resolvedRoot = destinationRoot.standardizedFileURL.resolvingSymlinksInPath()
        let requestedDirectory = destinationRoot.appendingPathComponent(
            output.folder, isDirectory: true)
        try fileManager.createDirectory(
            at: requestedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let directory = requestedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard isDescendant(directory, of: resolvedRoot) else {
            throw MemoryRoutineError.unsafeDestination(requestedDirectory)
        }
        let url = directory.appendingPathComponent(output.file, isDirectory: false)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw MemoryRoutineError.unsafeDestination(url)
            }
            let existing = try String(contentsOf: url, encoding: .utf8)
            guard existing == body else { throw MemoryRoutineError.destinationCollision(url) }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }
        try Task.checkCancellation()
        try Data(body.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath != rootPath else { return false }
        return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func postMeeting(_ meeting: Meeting, storage: StorageManager) -> String {
        let folder = meeting.folderURL(in: storage)
        let summary = (try? String(
            contentsOf: folder.appendingPathComponent("summary.md"),
            encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcomes = MeetingOutcomes.load(from: folder) ?? MeetingOutcomes()
        var lines = [
            "# Follow-up draft — \(clean(meeting.title))",
            "",
            "Meeting: `\(SessionLookup.shortID(meeting.id))` · \(displayDate(meeting.startedAt))",
            "",
            "## Draft",
            "",
            "Thanks for the conversation. Here is my understanding of the outcomes:",
        ]
        if !outcomes.decisions.isEmpty {
            lines += ["", "### Decisions", ""]
            lines += outcomes.decisions.map { "- \(clean($0))" }
        }
        if !outcomes.actionItems.isEmpty {
            lines += ["", "### Actions", ""]
            lines += outcomes.actionItems.map(actionLine)
        }
        if !outcomes.openQuestions.isEmpty {
            lines += ["", "### Open questions", ""]
            lines += outcomes.openQuestions.map { "- \(clean($0))" }
        }
        if let summary, !summary.isEmpty {
            lines += ["", "## Source summary", "", String(summary.prefix(18_000))]
        }
        lines += ["", "_Draft only. Review recipients and wording before sending._"]
        return lines.joined(separator: "\n")
    }

    private static func dailyStandup(
        _ day: Date,
        meetings: [Meeting],
        storage: StorageManager,
        storageRoot: URL,
        calendar: Calendar
    ) throws -> String {
        let today = calendar.startOfDay(for: day)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            ?? today.addingTimeInterval(-86_400)
        let interval = DateInterval(start: yesterday, end: today)
        let priorMeetings = meetings.filter { interval.contains($0.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
        let snapshot = try FileDailyMemoryExportSource(root: storageRoot).snapshot(
            for: yesterday,
            interval: interval)
        let actions = recentActions(
            since: calendar.date(byAdding: .day, value: -14, to: today) ?? .distantPast,
            meetings: meetings,
            storage: storage)
        var lines = [
            "# Daily stand-up — \(displayDate(day))",
            "",
            "## Yesterday",
            "",
        ]
        if priorMeetings.isEmpty {
            lines.append("- No recorded meetings.")
        } else {
            lines += priorMeetings.map {
                "- \(clean($0.title)) (`\(SessionLookup.shortID($0.id))`)"
            }
        }
        lines += [
            "- Tracked time: \(duration(snapshot.stats.trackedSeconds)) across \(snapshot.stats.appCount) apps.",
            "",
            "## Carry-forward actions",
            "",
        ]
        lines += actions.isEmpty ? ["- No extracted action candidates."] : actions.prefix(20).map(\.line)
        lines += [
            "",
            "## Today",
            "",
            "- [ ] Choose the priorities to carry forward from the list above.",
            "",
            "_This is a local draft. Nothing was assigned, sent, or marked complete._",
        ]
        return lines.joined(separator: "\n")
    }

    private static func weeklyWorkLog(
        _ day: Date,
        meetings: [Meeting],
        storage: StorageManager,
        storageRoot: URL,
        calendar: Calendar
    ) throws -> String {
        let end = day
        let start = calendar.date(byAdding: .day, value: -7, to: end)
            ?? end.addingTimeInterval(-7 * 86_400)
        let scoped = meetings.filter { $0.startedAt >= start && $0.startedAt <= end }
            .sorted { $0.startedAt < $1.startedAt }
        let reader = SQLiteScreenMemoryReader(
            databaseURL: storageRoot.appendingPathComponent("lokalbotv3.sqlite"))
        let usage = FileManager.default.fileExists(
            atPath: storageRoot.appendingPathComponent("lokalbotv3.sqlite").path)
            ? try reader.appUsage(from: start, to: end, limit: 20)
            : []
        var decisions: [String] = []
        var actions: [String] = []
        for meeting in scoped {
            let outcomes = MeetingOutcomes.load(from: meeting.folderURL(in: storage))
                ?? MeetingOutcomes()
            decisions += outcomes.decisions.map {
                "- \(clean($0)) — `\(SessionLookup.shortID(meeting.id))`"
            }
            actions += outcomes.actionItems.map {
                actionLine($0) + " — `\(SessionLookup.shortID(meeting.id))`"
            }
        }
        var lines = [
            "# Weekly work log — ending \(displayDate(day))",
            "",
            "## Meetings (\(scoped.count))",
            "",
        ]
        lines += scoped.isEmpty ? ["_No recorded meetings._"] : scoped.map {
            "- \(displayDate($0.startedAt)): \(clean($0.title)) (`\(SessionLookup.shortID($0.id))`)"
        }
        lines += ["", "## Decisions", ""]
        lines += decisions.isEmpty ? ["_No extracted decisions._"] : decisions
        lines += ["", "## Action candidates", ""]
        lines += actions.isEmpty ? ["_No extracted actions._"] : actions
        lines += ["", "## App-time totals", ""]
        lines += usage.isEmpty ? ["_No tracked app activity._"] : usage.map {
            "- \(clean($0.app)): \(duration($0.durationSeconds))"
        }
        return lines.joined(separator: "\n")
    }

    private static func unfinishedActions(
        _ day: Date,
        meetings: [Meeting],
        storage: StorageManager,
        calendar: Calendar
    ) -> String {
        let cutoff = calendar.date(byAdding: .day, value: -14, to: day) ?? .distantPast
        let actions = recentActions(since: cutoff, meetings: meetings, storage: storage)
        var lines = [
            "# Unfinished action candidates — \(displayDate(day))",
            "",
            "LokalBot cannot infer completion, so every action extracted in the last fourteen days remains a candidate until you review it.",
            "",
        ]
        lines += actions.isEmpty ? ["_No extracted action candidates._"] : actions.map(\.line)
        lines += ["", "_No source meeting or task system was modified._"]
        return lines.joined(separator: "\n")
    }

    private static func localJournal(
        _ day: Date,
        storageRoot: URL,
        calendar: Calendar
    ) throws -> String {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        let snapshot = try FileDailyMemoryExportSource(root: storageRoot).snapshot(
            for: start,
            interval: DateInterval(start: start, end: end))
        var lines = ["# Journal — \(displayDate(day))", "", "## Digest", ""]
        let digest = snapshot.digest?.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(digest?.isEmpty == false ? digest! : "_No day digest was generated._")
        lines += ["", "## Meetings", ""]
        lines += snapshot.meetings.isEmpty ? ["_No meetings._"] : snapshot.meetings.map {
            "- \(clean($0.title)) (`\($0.id)`)"
        }
        lines += ["", "## Saved moments", ""]
        lines += snapshot.savedMoments.isEmpty ? ["_No saved moments._"] : snapshot.savedMoments.map {
            let label = $0.windowTitle.isEmpty ? $0.app : "\($0.app) — \($0.windowTitle)"
            return "- \(clean(label)) (`screen:\($0.snapshotID)`)"
        }
        lines += [
            "", "## Day stats", "",
            "- Tracked time: \(duration(snapshot.stats.trackedSeconds))",
            "- Apps: \(snapshot.stats.appCount)",
            "- Context captures: \(snapshot.stats.screenshotCount)",
        ]
        return lines.joined(separator: "\n")
    }

    private struct ActionReference {
        var line: String
    }

    private static func recentActions(
        since cutoff: Date,
        meetings: [Meeting],
        storage: StorageManager
    ) -> [ActionReference] {
        meetings
            .filter { $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }
            .flatMap { meeting -> [ActionReference] in
                let outcomes = MeetingOutcomes.load(from: meeting.folderURL(in: storage))
                    ?? MeetingOutcomes()
                return outcomes.actionItems.map {
                    ActionReference(
                        line: actionLine($0) + " — `\(SessionLookup.shortID(meeting.id))`")
                }
            }
    }

    private static func actionLine(_ item: MeetingOutcomes.ActionItem) -> String {
        var suffix: [String] = []
        if let owner = item.owner, !owner.isEmpty { suffix.append("owner: \(clean(owner))") }
        if let due = item.due, !due.isEmpty { suffix.append("due: \(clean(due))") }
        return "- [ ] \(clean(item.text))" + (suffix.isEmpty ? "" : " (\(suffix.joined(separator: ", ")))" )
    }

    private static func clean(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func timestampKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds.rounded()) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

@MainActor
final class MemoryRoutineScheduler: ObservableObject {
    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        var destinationPath: String
        var kinds: [AppSettings.MemoryRoutineKind]
        var hour: Int
        var weekday: Int

        var normalizedHour: Int { min(23, max(0, hour)) }
        var normalizedWeekday: Int { min(7, max(1, weekday)) }
    }

    private struct Job: Sendable {
        var kind: AppSettings.MemoryRoutineKind
        var referenceDate: Date
        var meetingID: UUID?
        var runToken: String
    }

    @Published private(set) var isRunning = false
    @Published private(set) var currentKind: AppSettings.MemoryRoutineKind?
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var recentRuns: [MemoryRoutineRunRecord] = []
    @Published private(set) var dueCount = 0

    private let storageRoot: URL
    private let store: MemoryRoutineRunStore
    private let calendar: Calendar
    private let now: () -> Date
    private let canRun: () -> Bool
    private var configuration: Configuration?
    private var timer: Timer?
    private var runTask: Task<Void, Never>?
    private var errorHandler: ((String) -> Void)?
    private var generation = 0

    init(
        storageRoot: URL,
        databaseURL: URL,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        canRun: @escaping () -> Bool = { true }
    ) {
        self.storageRoot = storageRoot
        store = MemoryRoutineRunStore(databaseURL: databaseURL)
        self.calendar = calendar
        self.now = now
        self.canRun = canRun
        recentRuns = store.recent()
    }

    var pendingCount: Int { dueCount + store.runningCount() }

    func configure(_ configuration: Configuration, onError: @escaping (String) -> Void) {
        let changed = self.configuration != configuration
        self.configuration = configuration
        errorHandler = onError
        if changed {
            generation &+= 1
            runTask?.cancel()
            runTask = nil
            isRunning = false
            currentKind = nil
        }
        timer?.invalidate()
        timer = nil
        guard configuration.enabled, !configuration.destinationPath.isEmpty else {
            dueCount = 0
            return
        }
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
        runTask?.cancel()
        runTask = nil
        isRunning = false
        currentKind = nil
    }

    func tick() {
        guard runTask == nil,
              let configuration,
              configuration.enabled,
              !configuration.destinationPath.isEmpty else { return }
        let jobs = dueJobs(configuration: configuration, at: now())
        dueCount = jobs.count
        guard canRun(), let job = jobs.first else { return }
        start(job, configuration: configuration)
    }

    func runNow(_ kind: AppSettings.MemoryRoutineKind) {
        guard runTask == nil,
              kind != .postMeetingFollowUp,
              let configuration,
              configuration.enabled,
              configuration.kinds.contains(kind),
              !configuration.destinationPath.isEmpty,
              canRun() else { return }
        let date = now()
        start(Job(
            kind: kind,
            referenceDate: date,
            meetingID: nil,
            runToken: "manual:\(kind.rawValue):\(date.timeIntervalSince1970):\(UUID().uuidString)"
        ), configuration: configuration)
    }

    private func start(_ job: Job, configuration: Configuration) {
        let startedAt = now()
        let runID: Int64
        do {
            runID = try store.begin(
                kind: job.kind,
                runToken: job.runToken,
                meetingID: job.meetingID,
                at: startedAt)
        } catch {
            publish(error: error)
            return
        }
        let runGeneration = generation
        isRunning = true
        currentKind = job.kind
        lastError = nil
        let storageRoot = self.storageRoot
        let destinationRoot = URL(
            fileURLWithPath: configuration.destinationPath,
            isDirectory: true)
        let calendar = self.calendar
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try await Self.runWithTimeout(
                    kind: job.kind,
                    referenceDate: job.referenceDate,
                    storageRoot: storageRoot,
                    destinationRoot: destinationRoot,
                    meetingID: job.meetingID,
                    calendar: calendar)
                guard !Task.isCancelled, generation == runGeneration else { return }
                store.finish(id: runID, outputURL: output, error: nil, at: now())
                lastRunAt = now()
                lastOutputURL = output
                lastError = nil
            } catch is CancellationError {
                guard generation == runGeneration else { return }
                store.finish(id: runID, outputURL: nil, error: CancellationError(), at: now())
            } catch {
                guard generation == runGeneration else { return }
                store.finish(id: runID, outputURL: nil, error: error, at: now())
                publish(error: error)
            }
            guard generation == runGeneration else { return }
            isRunning = false
            currentKind = nil
            runTask = nil
            recentRuns = store.recent()
            dueCount = dueJobs(configuration: configuration, at: now()).count
            if dueCount > 0 {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.tick()
                }
            }
        }
    }

    private func publish(error: Error) {
        let message = "Memory routine failed: \(error.localizedDescription)"
        lastError = message
        errorHandler?(message)
        recentRuns = store.recent()
    }

    private func dueJobs(configuration: Configuration, at current: Date) -> [Job] {
        let enabled = Set(configuration.kinds)
        var jobs: [Job] = []

        if enabled.contains(.postMeetingFollowUp),
           let meeting = mostRecentUnprocessedMeeting(at: current) {
            let token = "postMeetingFollowUp:\(meeting.id.uuidString)"
            jobs.append(Job(
                kind: .postMeetingFollowUp,
                referenceDate: meeting.startedAt,
                meetingID: meeting.id,
                runToken: token))
        }

        let today = calendar.startOfDay(for: current)
        let dailyTarget = calendar.date(
            bySettingHour: configuration.normalizedHour,
            minute: 0,
            second: 0,
            of: current) ?? today
        if current >= dailyTarget {
            for kind in AppSettings.MemoryRoutineKind.allCases where
                enabled.contains(kind) && !kind.isEventDriven && !kind.isWeekly {
                let token = "\(kind.rawValue):\(Self.dayKey(today, calendar: calendar))"
                if !store.hasFinished(runToken: token) {
                    jobs.append(Job(
                        kind: kind,
                        referenceDate: current,
                        meetingID: nil,
                        runToken: token))
                }
            }
        }

        if enabled.contains(.weeklyWorkLog),
           let target = mostRecentWeeklyTarget(
                at: current,
                weekday: configuration.normalizedWeekday,
                hour: configuration.normalizedHour) {
            let token = "weeklyWorkLog:\(Self.dayKey(target, calendar: calendar))"
            if !store.hasFinished(runToken: token) {
                jobs.append(Job(
                    kind: .weeklyWorkLog,
                    referenceDate: current,
                    meetingID: nil,
                    runToken: token))
            }
        }
        return jobs
    }

    private func mostRecentUnprocessedMeeting(at current: Date) -> Meeting? {
        let cutoff = current.addingTimeInterval(-14 * 86_400)
        guard let meetings = try? SessionLookup.loadAllMeetings(root: storageRoot) else { return nil }
        return meetings
            .filter { meeting in
                guard meeting.startedAt >= cutoff else { return false }
                let summary = storageRoot
                    .appendingPathComponent(meeting.relativePath, isDirectory: true)
                    .appendingPathComponent("summary.md")
                let token = "postMeetingFollowUp:\(meeting.id.uuidString)"
                return FileManager.default.fileExists(atPath: summary.path)
                    && !store.hasFinished(runToken: token)
            }
            .max { $0.startedAt < $1.startedAt }
    }

    private func mostRecentWeeklyTarget(at current: Date, weekday: Int, hour: Int) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.nextDate(
            after: current.addingTimeInterval(1),
            matching: components,
            matchingPolicy: .nextTime,
            direction: .backward)
    }

    private nonisolated static func runWithTimeout(
        kind: AppSettings.MemoryRoutineKind,
        referenceDate: Date,
        storageRoot: URL,
        destinationRoot: URL,
        meetingID: UUID?,
        calendar: Calendar
    ) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask(priority: .utility) {
                try MemoryRoutineRunner.run(
                    kind: kind,
                    referenceDate: referenceDate,
                    storageRoot: storageRoot,
                    destinationRoot: destinationRoot,
                    meetingID: meetingID,
                    calendar: calendar)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw MemoryRoutineError.timedOut
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
