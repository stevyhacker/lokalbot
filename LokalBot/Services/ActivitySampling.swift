import AppKit
import ApplicationServices
import Combine
import Foundation

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
    @Published private(set) var lastSampleAt: Date?

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
        lastSampleAt = Date()
        currentApp = appName
        var title = titleResult.title ?? ""
        // Exclusion list (design §3.4): time still counts, content doesn't.
        if isExcluded {
            appName = "Private"
            title = ""
        } else {
            // Window titles are part of screen-memory metadata and external
            // timeline reads. Scrub recognizable credentials before the block
            // ever reaches SQLite, even when richer context capture is off.
            title = ScreenContextPrivacy.redact(title).text
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
