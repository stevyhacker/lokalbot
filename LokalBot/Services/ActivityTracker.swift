import Foundation
import AppKit
import SQLite3
import ApplicationServices

/// M4 day tracking, layer 1 (design doc §3.1): sample the frontmost app +
/// window title + idle state, collapse contiguous samples into activity
/// blocks, persist them to the shared SQLite database.

struct ActivityBlock: Identifiable {
    var id: Int64 = 0
    var app: String
    var title: String
    var start: Date
    var end: Date
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Storage for activity blocks (own connection to lokalbotv3.sqlite).
@MainActor
final class ActivityStore {
    private let database: SQLiteDatabase?
    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
        database = SQLiteDatabase(url: databaseURL)
        guard let database else { return }
        do {
            try database.execute("""
                CREATE TABLE IF NOT EXISTS activity_blocks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    app TEXT NOT NULL, title TEXT NOT NULL,
                    start REAL NOT NULL, end REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS idx_activity_start ON activity_blocks(start);
                CREATE TABLE IF NOT EXISTS screenshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL,
                    window_title TEXT NOT NULL DEFAULT '',
                    capture_trigger TEXT NOT NULL DEFAULT 'interval');
                """)
            try migrateScreenshotColumns()
            try migrateOCRTable()
        } catch {
            lokalbotLog("activity store initialization failed: \(error.localizedDescription)")
        }
    }

    /// Screenshots taken by builds before event-driven capture lack the
    /// `window_title` / `capture_trigger` columns. ALTER is cheap and keeps
    /// existing rows; fresh databases already have the full shape.
    private func migrateScreenshotColumns() throws {
        let database = try requiredDatabase()
        let columns = try columnNames(of: "screenshots")
        if !columns.contains("window_title") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN window_title TEXT NOT NULL DEFAULT ''")
        }
        if !columns.contains("capture_trigger") {
            try database.execute(
                "ALTER TABLE screenshots ADD COLUMN capture_trigger TEXT NOT NULL DEFAULT 'interval'")
        }
    }

    /// FTS5 tables cannot ALTER-add columns, so a legacy `ocr_fts`
    /// (text, ts, app) is rebuilt into the new shape with `window_title`
    /// indexed (searchable) plus `text_source` / `snapshot_id` metadata.
    /// `text_source` is always "ocr" today; it exists so Accessibility-first
    /// capture can land later as a data-only change.
    private func migrateOCRTable() throws {
        let database = try requiredDatabase()
        let existing = try columnNames(of: "ocr_fts")
        if existing.isEmpty {
            try database.execute(Self.createOCRTableSQL(named: "ocr_fts"))
            return
        }
        guard !existing.contains("snapshot_id") else { return }
        try database.withTransaction {
            try database.execute(Self.createOCRTableSQL(named: "ocr_fts_v2"))
            try database.execute("""
                INSERT INTO ocr_fts_v2 (text, window_title, ts, app, text_source, snapshot_id)
                    SELECT text, '', ts, app, 'ocr', 0 FROM ocr_fts;
                DROP TABLE ocr_fts;
                ALTER TABLE ocr_fts_v2 RENAME TO ocr_fts;
                """)
        }
    }

    private static func createOCRTableSQL(named name: String) -> String {
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS \(name) USING fts5(
            text, window_title, ts UNINDEXED, app UNINDEXED,
            text_source UNINDEXED, snapshot_id UNINDEXED,
            tokenize='unicode61 remove_diacritics 2');
        """
    }

    private func columnNames(of table: String) throws -> Set<String> {
        let database = try requiredDatabase()
        return Set(try database.queryChecked("PRAGMA table_info(\(table))") { statement in
            String(cString: sqlite3_column_text(statement, 1))
        })
    }

    private func requiredDatabase() throws -> SQLiteDatabase {
        guard let database else {
            throw SQLiteDatabase.DatabaseError.unavailable(path: databaseURL.path)
        }
        return database
    }

    nonisolated static func dayInterval(containing day: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .day, for: day)
            ?? DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
    }

    @discardableResult
    func insert(_ block: ActivityBlock) -> Bool {
        do {
            try requiredDatabase().runChecked(
                "INSERT INTO activity_blocks (app, title, start, end) VALUES (?1, ?2, ?3, ?4)",
                bind: [block.app, block.title, block.start.timeIntervalSince1970,
                       block.end.timeIntervalSince1970])
            return true
        } catch {
            lokalbotLog("activity block persistence failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Screenshots / OCR (M5)

    struct Screenshot: Identifiable {
        var id: Int64
        var ts: Date
        var path: String
        var app: String
        var windowTitle: String = ""
        var trigger: String = "interval"
    }

    struct OCRHit: Identifiable {
        let id = UUID()
        var ts: Date
        var app: String
        var windowTitle: String = ""
        var snippet: String
    }

    /// Insert one paired capture row (pixels bookkeeping + searchable text).
    /// Returns the screenshot rowid so the OCR row links back to its pixels.
    @discardableResult
    func insertScreenshot(ts: Date, path: String, app: String,
                          windowTitle: String = "", trigger: String = "interval",
                          textSource: String = "ocr", ocr: String) throws -> Int64 {
        let database = try requiredDatabase()
        return try database.withTransaction {
            try database.runChecked("""
                INSERT INTO screenshots (ts, path, app, window_title, capture_trigger)
                VALUES (?1, ?2, ?3, ?4, ?5)
                """, bind: [ts.timeIntervalSince1970, path, app, windowTitle, trigger])
            let snapshotID = database.lastInsertRowID()
            guard snapshotID > 0 else {
                throw SQLiteDatabase.DatabaseError.step(
                    sql: nil, code: SQLITE_CORRUPT,
                    message: "screenshot insert did not produce a row id")
            }
            if !ocr.isEmpty {
                try database.runChecked("""
                    INSERT INTO ocr_fts (text, window_title, ts, app, text_source, snapshot_id)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                    """, bind: [ocr, windowTitle, ts.timeIntervalSince1970, app,
                                 textSource, snapshotID])
            }
            return snapshotID
        }
    }

    func screenshots(on day: Date) -> [Screenshot] {
        let interval = Self.dayInterval(containing: day)
        do {
            return try requiredDatabase().queryChecked("""
                SELECT id, ts, path, app, window_title, capture_trigger FROM screenshots
                WHERE ts >= ?1 AND ts < ?2 AND path != '' ORDER BY ts
                """, bind: [interval.start.timeIntervalSince1970,
                             interval.end.timeIntervalSince1970]) { statement in
                Screenshot(id: sqlite3_column_int64(statement, 0),
                           ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                           path: String(cString: sqlite3_column_text(statement, 2)),
                           app: String(cString: sqlite3_column_text(statement, 3)),
                           windowTitle: String(cString: sqlite3_column_text(statement, 4)),
                           trigger: String(cString: sqlite3_column_text(statement, 5)))
            }
        } catch {
            lokalbotLog("screenshot query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// FTS search over screen text (and window titles). `matchAll: false`
    /// relaxes a natural-language query to OR'd content keywords — same
    /// rescue the meeting search uses.
    func searchOCR(_ query: String, limit: Int = 40,
                   matchAll: Bool = true, dropStopWords: Bool = false) -> [OCRHit] {
        guard let match = SearchIndex.ftsQuery(from: query, matchAll: matchAll,
                                               dropStopWords: dropStopWords) else { return [] }
        do {
            return try requiredDatabase().queryChecked("""
                SELECT ts, app, window_title, snippet(ocr_fts, 0, '«', '»', '…', 14)
                FROM ocr_fts WHERE ocr_fts MATCH ?1 ORDER BY rank LIMIT \(limit)
                """, bind: [match]) { statement in
                OCRHit(ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                       app: String(cString: sqlite3_column_text(statement, 1)),
                       windowTitle: String(cString: sqlite3_column_text(statement, 2)),
                       snippet: String(cString: sqlite3_column_text(statement, 3)))
            }
        } catch {
            lokalbotLog("OCR search failed: \(error.localizedDescription)")
            return []
        }
    }

    /// OCR text for a day, for the "ask your day" LLM context.
    func ocrText(on day: Date, maxChars: Int = 9_000) -> String {
        let interval = Self.dayInterval(containing: day)
        return ocrText(from: interval.start, to: interval.end, maxChars: maxChars, includeAppNames: true)
    }

    /// OCR text for a precise interval. Used for meeting-local participant
    /// hints, where the current day's whole screen history would be too broad.
    func ocrText(from start: Date, to end: Date, maxChars: Int = 9_000,
                 includeAppNames: Bool = false) -> String {
        guard maxChars > 0 else { return "" }
        do {
            var out = ""
            try requiredDatabase().forEachRowChecked("""
                SELECT app, text FROM ocr_fts WHERE ts >= ?1 AND ts < ?2 ORDER BY ts
                """, bind: [start.timeIntervalSince1970, end.timeIntervalSince1970]) { statement in
                let app = String(cString: sqlite3_column_text(statement, 0))
                let text = String(cString: sqlite3_column_text(statement, 1))
                let line = includeAppNames
                    ? "[\(app)] \(text.prefix(600))\n"
                    : "\(text.prefix(600))\n"
                out += line.prefix(maxChars - out.count)
                return out.count < maxChars
            }
            return out
        } catch {
            lokalbotLog("OCR context query failed: \(error.localizedDescription)")
            return ""
        }
    }

    func screenshotPaths(olderThan cutoff: Date) -> [String] {
        do {
            return try requiredDatabase().queryChecked(
                "SELECT path FROM screenshots WHERE ts < ?1 AND path != ''",
                bind: [cutoff.timeIntervalSince1970]) { statement in
                String(cString: sqlite3_column_text(statement, 0))
            }
        } catch {
            lokalbotLog("screenshot retention query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Clear only the row whose file was successfully removed. This avoids
    /// losing the sole reference to an encrypted file when filesystem cleanup
    /// fails (permissions, transient volume error, and so on).
    func clearScreenshotPath(_ path: String) throws {
        try requiredDatabase().runChecked(
            "UPDATE screenshots SET path = '' WHERE path = ?1", bind: [path])
    }

    @discardableResult
    func clearOCRText(olderThan cutoff: Date) -> Bool {
        do {
            try requiredDatabase().runChecked(
                "DELETE FROM ocr_fts WHERE ts < ?1", bind: [cutoff.timeIntervalSince1970])
            return true
        } catch {
            lokalbotLog("OCR retention cleanup failed: \(error.localizedDescription)")
            return false
        }
    }

    /// All blocks overlapping the given day, oldest first.
    func blocks(on day: Date) -> [ActivityBlock] {
        let interval = Self.dayInterval(containing: day)
        do {
            return try requiredDatabase().queryChecked("""
                SELECT id, app, title, start, end FROM activity_blocks
                WHERE end > ?1 AND start < ?2 ORDER BY start
                """, bind: [interval.start.timeIntervalSince1970,
                             interval.end.timeIntervalSince1970]) { statement in
                ActivityBlock(
                    id: sqlite3_column_int64(statement, 0),
                    app: String(cString: sqlite3_column_text(statement, 1)),
                    title: String(cString: sqlite3_column_text(statement, 2)),
                    start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
            }
        } catch {
            lokalbotLog("activity block query failed: \(error.localizedDescription)")
            return []
        }
    }
}

struct FocusedWindowTitleLookupResult: Equatable, Sendable {
    let title: String?
    let timedOut: Bool

    static let timeout = Self(title: nil, timedOut: true)
}

/// Keeps cross-process Accessibility title reads off the main actor and bounds
/// both queue growth and caller latency. One resolver may be active at a time;
/// same-PID callers share it, while a different PID fails closed instead of
/// accumulating behind a wedged target process.
final class FocusedWindowTitleLookup: @unchecked Sendable {
    typealias Resolver = @Sendable (pid_t) -> String?

    static let shared = FocusedWindowTitleLookup()
    static let defaultDeadlineMilliseconds = 120
    static let perElementMessagingTimeout: Float = 0.04

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<FocusedWindowTitleLookupResult, Never>
    }

    private struct Work {
        let id: UInt64
        let processID: pid_t
        var waiters: [UInt64: Waiter]
    }

    private let stateQueue = DispatchQueue(label: "me.dotenv.LokalBot.ax-window-title-state")
    private let workerQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.ax-window-title-worker",
        qos: .utility)
    private let deadlineMilliseconds: Int
    private let resolver: Resolver
    private var nextIdentifier: UInt64 = 0
    private var active: Work?

    init(
        deadlineMilliseconds: Int = defaultDeadlineMilliseconds,
        resolver: @escaping Resolver = { processID in
            FocusedWindowTitleLookup.resolveTitle(processID: processID)
        }
    ) {
        self.deadlineMilliseconds = max(1, deadlineMilliseconds)
        self.resolver = resolver
    }

    func title(for processID: pid_t) async -> FocusedWindowTitleLookupResult {
        guard processID > 0 else { return .init(title: nil, timedOut: false) }
        return await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                nextIdentifier &+= 1
                let waiter = Waiter(id: nextIdentifier, continuation: continuation)
                enqueue(waiter: waiter, processID: processID)
            }
        }
    }

    private func enqueue(waiter: Waiter, processID: pid_t) {
        if var active {
            guard active.processID == processID else {
                waiter.continuation.resume(returning: .timeout)
                return
            }
            active.waiters[waiter.id] = waiter
            self.active = active
            scheduleExpiration(for: waiter.id)
            return
        }

        nextIdentifier &+= 1
        let work = Work(
            id: nextIdentifier,
            processID: processID,
            waiters: [waiter.id: waiter])
        active = work
        scheduleExpiration(for: waiter.id)
        workerQueue.async { [weak self] in
            guard let self else { return }
            let title = resolver(processID)
            stateQueue.async { [weak self] in
                self?.finish(workID: work.id, title: title)
            }
        }
    }

    private func scheduleExpiration(for waiterID: UInt64) {
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(deadlineMilliseconds)) { [weak self] in
            self?.expire(waiterID: waiterID)
        }
    }

    private func expire(waiterID: UInt64) {
        guard var active, let waiter = active.waiters.removeValue(forKey: waiterID) else { return }
        self.active = active
        waiter.continuation.resume(returning: .timeout)
    }

    private func finish(workID: UInt64, title: String?) {
        guard let completed = active, completed.id == workID else { return }
        active = nil
        let result = FocusedWindowTitleLookupResult(title: title, timedOut: false)
        for waiter in completed.waiters.values {
            waiter.continuation.resume(returning: result)
        }
    }

    static func resolveTitle(processID: pid_t) -> String? {
        guard AXIsProcessTrusted(), processID > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(appElement, perElementMessagingTimeout)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &rawWindow) == .success,
              let rawWindow,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let window = rawWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(window, perElementMessagingTimeout)
        var rawTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &rawTitle) == .success else { return nil }
        return rawTitle as? String
    }
}

/// The sampler: 5 s poll (cheap), block boundaries on app/title change,
/// idle > 3 min, pause, or app quit. No screenshots here — that's M5.
@MainActor
final class ActivitySampler: ObservableObject {

    @Published var isPaused = false {
        didSet { if isPaused { closeCurrentBlock() } }
    }
    @Published private(set) var currentApp: String?

    private let store: ActivityStore
    private let windowTitleLookup: FocusedWindowTitleLookup
    /// Injected by AppState; apps matching these are logged as "Private".
    var excludedApps: () -> [String] = { [] }
    /// Event-driven capture hook: fired when the sampled (app, title) pair
    /// changes — i.e. at the same boundaries that close activity blocks.
    /// `appChanged` distinguishes an app switch from a window/tab change
    /// inside the same app. Excluded apps arrive as ("Private", "").
    var onActivityBoundary: ((_ app: String, _ title: String, _ appChanged: Bool) -> Void)?
    private var timer: Timer?
    private let notificationCenter: NotificationCenter
    private var terminationObserver: NSObjectProtocol?
    private var current: (app: String, title: String, start: Date)?
    private var lastSeen = Date()
    private static let idleLimit: TimeInterval = 180
    private static let minBlock: TimeInterval = 5

    init(
        store: ActivityStore,
        notificationCenter: NotificationCenter = .default,
        windowTitleLookup: FocusedWindowTitleLookup = .shared
    ) {
        self.store = store
        self.notificationCenter = notificationCenter
        self.windowTitleLookup = windowTitleLookup
    }

    var hasTerminationObserver: Bool { terminationObserver != nil }

    func start() {
        guard timer == nil else { return }
        lokalbotLog("sampler start — AX trusted: \(Self.hasAccessibility ? "yes" : "no")")
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sample() }
        }
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.closeCurrentBlock() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let terminationObserver {
            notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        closeCurrentBlock()
    }

    deinit {
        if let terminationObserver {
            notificationCenter.removeObserver(terminationObserver)
        }
    }

    /// Window titles need Accessibility; we degrade to app-name-only.
    nonisolated static var hasAccessibility: Bool { AXIsProcessTrusted() }
    nonisolated static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func sample() async {
        guard !isPaused else { return }

        // Idle: any input event type, session-wide.
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > Self.idleLimit {
            closeCurrentBlock(at: lastSeen)
            return
        }
        lastSeen = Date()

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              var appName = frontmost.localizedName else { return }
        let processID = frontmost.processIdentifier
        let isExcluded = ScreenshotCaptureLayout.isExcluded(
            appName: appName, excludedApps: excludedApps())
        let titleResult = isExcluded
            ? FocusedWindowTitleLookupResult(title: nil, timedOut: false)
            : await windowTitleLookup.title(for: processID)
        guard !titleResult.timedOut,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return }
        currentApp = appName
        var title = titleResult.title ?? ""
        // Exclusion list (design §3.4): time still counts, content doesn't.
        if isExcluded {
            appName = "Private"
            title = ""
        }

        if let current {
            if current.app == appName && current.title == title { return }
            let appChanged = current.app != appName
            closeCurrentBlock()
            onActivityBoundary?(appName, title, appChanged)
        }
        current = (appName, title, Date())
    }

    private func closeCurrentBlock(at end: Date = Date()) {
        guard let block = current else { return }
        current = nil
        guard end.timeIntervalSince(block.start) >= Self.minBlock else { return }
        store.insert(ActivityBlock(app: block.app, title: block.title,
                                   start: block.start, end: end))
    }

    nonisolated static func focusedWindowTitle(pid: pid_t) -> String? {
        FocusedWindowTitleLookup.resolveTitle(processID: pid)
    }
}
