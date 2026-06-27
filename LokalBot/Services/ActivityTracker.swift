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

    init(databaseURL: URL) {
        database = SQLiteDatabase(url: databaseURL)
        database?.exec("""
            CREATE TABLE IF NOT EXISTS activity_blocks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app TEXT NOT NULL, title TEXT NOT NULL,
                start REAL NOT NULL, end REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS idx_activity_start ON activity_blocks(start);
            CREATE TABLE IF NOT EXISTS screenshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts USING fts5(
                text, ts UNINDEXED, app UNINDEXED,
                tokenize='unicode61 remove_diacritics 2');
            """)
    }

    nonisolated static func dayInterval(containing day: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .day, for: day)
            ?? DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
    }

    func insert(_ block: ActivityBlock) {
        database?.run(
            "INSERT INTO activity_blocks (app, title, start, end) VALUES (?1, ?2, ?3, ?4)",
            bind: [block.app, block.title, block.start.timeIntervalSince1970, block.end.timeIntervalSince1970])
    }

    // MARK: Screenshots / OCR (M5)

    struct Screenshot: Identifiable {
        var id: Int64
        var ts: Date
        var path: String
        var app: String
    }

    struct OCRHit: Identifiable {
        let id = UUID()
        var ts: Date
        var app: String
        var snippet: String
    }

    func insertScreenshot(ts: Date, path: String, app: String, ocr: String) {
        database?.run("INSERT INTO screenshots (ts, path, app) VALUES (?1, ?2, ?3)",
                      bind: [ts.timeIntervalSince1970, path, app])
        if !ocr.isEmpty {
            database?.run("INSERT INTO ocr_fts (text, ts, app) VALUES (?1, ?2, ?3)",
                          bind: [ocr, ts.timeIntervalSince1970, app])
        }
    }

    func screenshots(on day: Date) -> [Screenshot] {
        let interval = Self.dayInterval(containing: day)
        return database?.query("""
            SELECT id, ts, path, app FROM screenshots
            WHERE ts >= ?1 AND ts < ?2 AND path != '' ORDER BY ts
            """, bind: [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]) { statement in
            Screenshot(id: sqlite3_column_int64(statement, 0),
                       ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                       path: String(cString: sqlite3_column_text(statement, 2)),
                       app: String(cString: sqlite3_column_text(statement, 3)))
        } ?? []
    }

    func searchOCR(_ query: String, limit: Int = 40) -> [OCRHit] {
        guard let match = SearchIndex.ftsQuery(from: query) else { return [] }
        return database?.query("""
            SELECT ts, app, snippet(ocr_fts, 0, '«', '»', '…', 14)
            FROM ocr_fts WHERE ocr_fts MATCH ?1 ORDER BY rank LIMIT \(limit)
            """, bind: [match]) { statement in
            OCRHit(ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                   app: String(cString: sqlite3_column_text(statement, 1)),
                   snippet: String(cString: sqlite3_column_text(statement, 2)))
        } ?? []
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
        return database?.withStatement("""
            SELECT app, text FROM ocr_fts WHERE ts >= ?1 AND ts < ?2 ORDER BY ts
            """, bind: [start.timeIntervalSince1970, end.timeIntervalSince1970]) { statement in
            var out = ""
            while sqlite3_step(statement) == SQLITE_ROW, out.count < maxChars {
                let app = String(cString: sqlite3_column_text(statement, 0))
                let text = String(cString: sqlite3_column_text(statement, 1))
                if includeAppNames {
                    out += "[\(app)] \(text.prefix(600))\n"
                } else {
                    out += "\(text.prefix(600))\n"
                }
            }
            return out
        } ?? ""
    }

    func screenshotPaths(olderThan cutoff: Date) -> [String] {
        database?.query("SELECT path FROM screenshots WHERE ts < ?1 AND path != ''",
                        bind: [cutoff.timeIntervalSince1970]) { statement in
            String(cString: sqlite3_column_text(statement, 0))
        } ?? []
    }

    func clearScreenshotPaths(olderThan cutoff: Date) {
        database?.run("UPDATE screenshots SET path = '' WHERE ts < ?1",
                      bind: [cutoff.timeIntervalSince1970])
    }

    /// All blocks overlapping the given day, oldest first.
    func blocks(on day: Date) -> [ActivityBlock] {
        let interval = Self.dayInterval(containing: day)
        return database?.query("""
            SELECT id, app, title, start, end FROM activity_blocks
            WHERE end > ?1 AND start < ?2 ORDER BY start
            """, bind: [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]) { statement in
            ActivityBlock(
                id: sqlite3_column_int64(statement, 0),
                app: String(cString: sqlite3_column_text(statement, 1)),
                title: String(cString: sqlite3_column_text(statement, 2)),
                start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
        } ?? []
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
    /// Injected by AppState; apps matching these are logged as "Private".
    var excludedApps: () -> [String] = { [] }
    private var timer: Timer?
    private var current: (app: String, title: String, start: Date)?
    private var lastSeen = Date()
    private static let idleLimit: TimeInterval = 180
    private static let minBlock: TimeInterval = 5

    init(store: ActivityStore) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        lokalbotLog("sampler start — AX trusted: \(Self.hasAccessibility ? "yes" : "no")")
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in self?.closeCurrentBlock() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        closeCurrentBlock()
    }

    /// Window titles need Accessibility; we degrade to app-name-only.
    nonisolated static var hasAccessibility: Bool { AXIsProcessTrusted() }
    nonisolated static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func sample() {
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
        currentApp = appName
        var title = Self.focusedWindowTitle(pid: frontmost.processIdentifier) ?? ""
        // Exclusion list (design §3.4): time still counts, content doesn't.
        if excludedApps().contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
            appName = "Private"
            title = ""
        }

        if let current {
            if current.app == appName && current.title == title { return }
            closeCurrentBlock()
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
        guard hasAccessibility else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
            kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,
            kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}
