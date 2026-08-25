import Foundation

enum AgentSavedSessionOpenError: LocalizedError {
    case unavailable
    case alreadyOpen
    case missingWorkspace
    case maximumLiveSessions

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "That saved session is no longer available. Refresh history and try again."
        case .alreadyOpen:
            "That session is already open in another Agent tab."
        case .missingWorkspace:
            "The saved session’s working folder no longer exists."
        case .maximumLiveSessions:
            "Close a live Agent tab before opening another saved session."
        }
    }
}

/// Owns the live Agent Mode tabs. Every tab has its own controller and pi
/// subprocess, so switching tabs never pauses or replaces another session.
@MainActor
final class AgentSessionTabs: ObservableObject {
    static let maximumLiveSessions = 4

    struct Tab: Identifiable {
        let id: UUID
        let number: Int
        let controller: AgentSessionController

        @MainActor var title: String { controller.sessionTitle ?? "Session \(number)" }
    }

    @Published private(set) var tabs: [Tab]
    @Published private(set) var selectedID: UUID

    private let makeController: @MainActor () -> AgentSessionController
    private var nextNumber: Int

    convenience init(
        settings: @escaping () -> AppSettings,
        storage: StorageManager,
        thinkExecution: ThinkExecution? = nil
    ) {
        let execution = thinkExecution ?? ThinkExecution(storage: storage)
        self.init {
            AgentSessionController(
                settings: settings,
                storage: storage,
                thinkExecution: execution)
        }
    }

    init(makeController: @escaping @MainActor () -> AgentSessionController) {
        self.makeController = makeController
        let first = Tab(id: UUID(), number: 1, controller: makeController())
        tabs = [first]
        selectedID = first.id
        nextNumber = 2
    }

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedID }
    }

    /// Used by the headless Agent Mode command, which needs one controller but
    /// does not mount AgentView. The normal invariant is that a tab always
    /// exists; shutdownAll intentionally clears it only while the app exits.
    func ensureSelectedController() -> AgentSessionController {
        if let selectedTab { return selectedTab.controller }
        return addSession().controller
    }

    @discardableResult
    func addSession() -> Tab {
        if tabs.count >= Self.maximumLiveSessions, let selectedTab {
            return selectedTab
        }
        let tab = Tab(id: UUID(), number: nextNumber, controller: makeController())
        nextNumber += 1
        tabs.append(tab)
        selectedID = tab.id
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    var canOpenAnotherSavedSession: Bool {
        selectedTab?.controller.canReplaceWithSavedSession == true
            || tabs.count < Self.maximumLiveSessions
    }

    func isOpen(_ session: AgentSavedSession) -> Bool {
        let expected = session.fileURL.standardizedFileURL.path
        return tabs.contains { tab in
            tab.controller.activeSessionFile?.standardizedFileURL.path == expected
        }
    }

    func workspaceDisplayName(for workspace: URL) -> String {
        selectedTab?.controller.workspaceDisplayName(for: workspace)
            ?? (workspace.lastPathComponent.isEmpty ? workspace.path : workspace.lastPathComponent)
    }

    func loadSavedSessions() async throws -> [AgentSavedSession] {
        let directory = savedHistoryDirectory
        return try await Task.detached(priority: .userInitiated) {
            try AgentSessionHistory.load(from: directory)
        }.value
    }

    func openSavedSession(_ session: AgentSavedSession) async throws {
        let directory = savedHistoryDirectory
        guard let refreshed = await Task.detached(priority: .userInitiated, operation: {
            AgentSessionHistory.validated(session, in: directory)
        }).value else {
            throw AgentSavedSessionOpenError.unavailable
        }
        guard !isOpen(refreshed) else { throw AgentSavedSessionOpenError.alreadyOpen }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: refreshed.workspace.path,
            isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AgentSavedSessionOpenError.missingWorkspace
        }

        let tab: Tab
        if let selectedTab, selectedTab.controller.canReplaceWithSavedSession {
            tab = selectedTab
        } else {
            guard tabs.count < Self.maximumLiveSessions else {
                throw AgentSavedSessionOpenError.maximumLiveSessions
            }
            tab = addSession()
        }
        selectedID = tab.id
        await tab.controller.resumeSavedSession(refreshed)
    }

    /// Removes the tab immediately, then shuts down only that tab's process.
    /// Closing the final tab creates a fresh empty one so Agent Mode never
    /// lands in a dead-end screen.
    func close(_ id: UUID) async {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs.remove(at: index)

        if tabs.isEmpty {
            _ = addSession()
        } else if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }

        await removed.controller.shutdown()
    }

    /// App-termination path. Unlike close(_:), this deliberately does not
    /// create a replacement tab.
    func shutdownAll() async {
        let controllers = tabs.map(\.controller)
        tabs.removeAll()
        for controller in controllers {
            await controller.shutdown()
        }
    }

    /// Privacy control used by the tab-strip menu. Active processes stop first
    /// so pi cannot append to a session file while its history is removed.
    func clearSavedHistory() async throws {
        let directory = savedHistoryDirectory
        await shutdownAll()
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            _ = addSession()
            throw error
        }
        _ = addSession()
    }

    private var savedHistoryDirectory: URL {
        selectedTab?.controller.sessionStorageDirectory
            ?? AgentRuntimeLayout.sessionsDirectory
    }
}
