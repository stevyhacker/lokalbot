import Foundation

/// Orchestrates one Agent Mode session: resolves the LLM endpoint, spawns
/// the pi subprocess (or a test transport), pumps pi events into the
/// transcript, and round-trips tool approvals between pi's confirm dialogs
/// and the UI. Lives on the main actor because it feeds SwiftUI directly.
@MainActor
final class AgentSessionController: ObservableObject {

    enum SessionState: Equatable {
        case idle, starting, ready, running
        case failed(String)
    }

    enum RecoveryAction: Equatable {
        case openModels
        case restart
    }

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var items: [AgentTranscriptItem] = []
    @Published private(set) var recoveryAction: RecoveryAction?
    @Published private(set) var sessionTitle: String?
    @Published var workspace: URL
    @Published var draft = ""
    @Published var autoApproveSession = false {
        didSet { policy.autoApproveFileChanges = autoApproveSession }
    }

    private let settings: () -> AppSettings
    private let storage: StorageManager
    private let runtimeRoot: URL
    private let sessionsDirectory: URL
    private let broker: InferenceBroker
    private let makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)?
    private let accessGate: AgentAccessGate

    private var policy = AgentApprovalPolicy()
    private var folder = AgentTranscriptFolder()
    private var client: PiRPCClient?
    private var process: PiProcess?
    private var eventTask: Task<Void, Never>?
    private var deltaFlushTask: Task<Void, Never>?
    private var pendingTextDelta = ""
    private var nextRequestID = 0
    private var launchMode: LaunchMode = .fresh
    /// Invalidates an in-flight start when its tab is closed or restarted.
    /// Without this, a close during model warm-up could finish spawning pi
    /// after shutdown() had already returned.
    private var lifecycleGeneration = 0
    /// Serializes failure cleanup with shutdown/restart. A failed state is not
    /// published until this returns to false, so a replacement process can
    /// never launch while its predecessor is still being terminated.
    private var failureTeardownInProgress = false
    /// Held from resolveEndpoint (built-in engine only) until shutdown or
    /// failure, so the Main LLM cannot be evicted mid-conversation by an
    /// unrelated model load.
    private var llmLease: InferenceLease?
    private var accessCapability: AgentAccessCapability?

    init(settings: @escaping () -> AppSettings,
         storage: StorageManager,
         runtimeRoot: URL = AgentRuntimeLayout.defaultRoot,
         sessionsDirectory: URL = AgentRuntimeLayout.sessionsDirectory,
         broker: InferenceBroker = .shared,
         accessGate: AgentAccessGate? = nil,
         makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)? = nil) {
        self.settings = settings
        self.storage = storage
        self.runtimeRoot = runtimeRoot
        self.sessionsDirectory = sessionsDirectory
        self.broker = broker
        self.accessGate = accessGate ?? AgentAccessGate(root: storage.rootURL)
        self.makeTransport = makeTransport
        self.workspace = storage.rootURL
    }

    // MARK: - Lifecycle

    func start() async {
        guard !failureTeardownInProgress,
              state == .idle || isFailed else { return }
#if LOKALBOT_UI_TEST_HOST
        // Keep Agent Mode UI tests hermetic: no model warm-up, capability
        // issuance, subprocess, or network. Production builds never compile
        // this path, and host runs must opt in explicitly.
        if ProcessInfo.processInfo.environment["LOKALBOT_AGENT_UI_TEST_READY"] == "1" {
            recoveryAction = nil
            state = .ready
            return
        }
#endif
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        state = .starting
        recoveryAction = nil
        do {
            let endpoint = try await resolveEndpoint()
            guard generation == lifecycleGeneration else {
                // shutdown() may have run while the broker was still ensuring,
                // before resolveEndpoint had assigned the lease.
                releaseLLMLease()
                return
            }
            var capabilityToken: String?
            if makeTransport == nil {
                accessGate.removeExpiredCapabilities()
                let capability = try accessGate.issueScopedCapability()
                accessCapability = capability
                capabilityToken = capability.token
            }
            let plan = makePlan(endpoint: endpoint, capabilityToken: capabilityToken)
            let transport: PiLineTransport
            var spawnedProcess: PiProcess?
            if let makeTransport {
                transport = try await makeTransport(plan)
            } else {
                let piProcess = PiProcess(plan: plan)
                try await piProcess.start()
                spawnedProcess = piProcess
                transport = piProcess
            }
            guard generation == lifecycleGeneration else {
                await spawnedProcess?.stop()
                return
            }
            process = spawnedProcess
            let rpc = PiRPCClient(transport: transport)
            await rpc.run()
            guard generation == lifecycleGeneration else {
                await spawnedProcess?.stop()
                return
            }
            client = rpc
            consumeEvents(from: rpc, generation: generation)
            if launchMode == .continueRecent {
                await restorePreviousMessages(using: rpc)
            }
            state = .ready
        } catch {
            guard generation == lifecycleGeneration else { return }
            revokeAccessCapability()
            setFailure(error)
        }
    }

    func shutdown() async {
        while failureTeardownInProgress {
            try? await Task.sleep(for: .milliseconds(10))
        }
        lifecycleGeneration += 1
        await cancelPendingApprovals()
        eventTask?.cancel()
        eventTask = nil
        discardPendingTextDelta()
        // Revoke access before giving a hung child its SIGTERM grace period.
        // Closing a tab must close the meeting-library capability immediately,
        // even if pi ignores termination until the SIGKILL fallback.
        revokeAccessCapability()
        await process?.stop()
        process = nil
        client = nil
        policy.resetSession()
        autoApproveSession = false
        releaseLLMLease()
        state = .idle
    }

    // MARK: - Prompting

    func send(prompt: String) async {
        guard let client, state == .ready || state == .running else { return }
        if sessionTitle == nil {
            sessionTitle = Self.makeSessionTitle(from: prompt)
        }
        folder.noteUserPrompt(prompt)
        publish()
        let behavior = state == .running ? "followUp" : nil
        do {
            let response = try await client.request(
                .prompt(id: freshID("p"), message: prompt, streamingBehavior: behavior))
            if !response.success {
                folder.appendNotice(response.error ?? "pi rejected the prompt", isError: true)
                publish()
            }
        } catch {
            await fail(with: error)
        }
    }

    func abort() async {
        guard let client else { return }
        _ = try? await client.request(.abort(id: freshID("a")))
    }

    func newSession() async {
        guard let client else { return }
        do {
            _ = try await client.request(.newSession(id: freshID("n")))
            discardPendingTextDelta()
            folder = AgentTranscriptFolder()
            policy.resetSession()
            launchMode = .fresh
            sessionTitle = nil
            draft = ""
            publish()
            state = .ready
        } catch {
            await fail(with: error)
        }
    }

    func resumePreviousSession() async {
        guard canResumePreviousSession else { return }
        await shutdown()
        discardPendingTextDelta()
        folder = AgentTranscriptFolder()
        policy.resetSession()
        autoApproveSession = false
        sessionTitle = nil
        draft = ""
        publish()
        launchMode = .continueRecent
        await start()
    }

    // MARK: - Approvals

    func respondToApproval(id: String, approved: Bool, scope: ApprovalScope) async {
        guard let client else { return }
        guard let request = pendingApprovalRequest(requestID: id) else { return }
        if approved, scope == .session {
            policy.allowForSession(
                tool: request.tool,
                path: request.path,
                requestWorkspace: request.workspace,
                selectedWorkspace: workspace)
        }
        folder.resolveApproval(requestID: id)
        if !approved {
            folder.appendNotice("You denied this \(request.tool) request. Nothing changed.")
        }
        publish()
        try? await client.sendResponse(.uiConfirmResponse(requestID: id, confirmed: approved))
    }

    /// Unattended callers have nobody available to inspect sensitive requests.
    /// Resolve every card as a one-time denial so the pi turn cannot hang.
    func denyAllPendingApprovals() async {
        for id in folder.pendingApprovalIDs {
            await respondToApproval(id: id, approved: false, scope: .once)
        }
    }

    // MARK: - Event loop

    private func consumeEvents(from client: PiRPCClient, generation: Int) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.events {
                guard !Task.isCancelled else { return }
                await self.handle(event, generation: generation)
            }
            // shutdown() cancels this task and only later sets .idle; a
            // cancelled iteration ending must not fold a spurious failure.
            guard !Task.isCancelled else { return }
            await self.handleStreamEnd(generation: generation)
        }
    }

    private func handle(_ event: PiEvent, generation: Int) async {
        guard generation == lifecycleGeneration,
              state != .idle,
              !isFailed else { return }
        // Pi can emit hundreds of token deltas per second. Fold and publish
        // those as one string at display cadence; structural events flush the
        // pending text first so message/tool/approval ordering stays exact.
        if case .messageUpdate(.textDelta(let delta)) = event {
            enqueueTextDelta(delta)
            return
        }
        flushPendingTextDelta()

        switch event {
        case .agentStart:
            state = .running
        case .agentSettled, .agentEnd:
            state = .ready
        case .extensionUIRequest(let request):
            await handleUIRequest(request)
        default:
            break
        }
        folder.fold(event)
        publish()
    }

    private func handleUIRequest(_ request: PiUIRequest) async {
        guard let client else { return }
        guard request.method == "confirm" else {
            folder.appendNotice("The agent asked for an unsupported interaction (\(request.method)); declined.", isError: false)
            try? await client.sendResponse(.uiCancelResponse(requestID: request.id))
            return
        }
        let approval = Self.parseApprovalPayload(request)
        switch policy.verdict(
            tool: approval.tool,
            path: approval.path,
            requestWorkspace: approval.workspace,
            selectedWorkspace: workspace) {
        case .allow:
            try? await client.sendResponse(.uiConfirmResponse(requestID: request.id, confirmed: true))
        case .ask:
            if !folder.addApproval(approval) {
                folder.appendNotice(
                    "The newest tool approval exceeded safety limits or too many are already waiting; it was declined.",
                    isError: true)
                try? await client.sendResponse(.uiCancelResponse(requestID: request.id))
            }
        }
    }

    private func handleStreamEnd(generation: Int) async {
        guard generation == lifecycleGeneration,
              state != .idle,
              !isFailed else { return }
        flushPendingTextDelta()
        var detail = "The agent process exited unexpectedly."
        if let process {
            let tail = await process.stderrTail
            if !tail.isEmpty { detail += "\n" + tail.suffix(5).joined(separator: "\n") }
        }
        guard generation == lifecycleGeneration else { return }
        await transitionToFailure(message: detail, recovery: .restart)
    }

    // MARK: - Endpoint + plan

    private func resolveEndpoint() async throws -> AgentLLMEndpoint {
        switch AgentLLMEndpointResolver.resolve(settings: settings()) {
        case .ready(let endpoint):
            return endpoint
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(id: modelID, custom: settings().customBuiltInModels)
                    ?? ModelCatalog.entry(id: modelID) else {
                throw StartError.modelConfiguration("The built-in model isn't downloaded yet. Download it under Settings → Models.")
            }
            guard let modelURL = await ModelDownloadManager.shared.verifiedExistingURL(
                entry, storage: storage) else {
                throw StartError.modelConfiguration("The built-in model isn't downloaded yet. Download it under Settings → Models.")
            }
            releaseLLMLease()
            llmLease = try await broker.lease(.mainLLM, model: modelURL,
                                              priority: .interactive,
                                              purpose: "agent session")
            let authenticationToken = await LlamaServer.shared.authenticationToken()
            return AgentLLMEndpoint(baseURL: LlamaServer.shared.baseURL,
                                    model: entry.id,
                                    contextTokens: AgentLLMEndpoint.defaultContextTokens,
                                    apiKey: authenticationToken)
        case .unsupported(let reason):
            throw StartError.modelConfiguration(reason)
        }
    }

    private func makePlan(endpoint: AgentLLMEndpoint, capabilityToken: String?) -> PiLaunchPlan {
        let resources = Bundle.main.resourceURL
        let extensionDir = resources?.appendingPathComponent("pi/lokalbot-extension")
            ?? URL(fileURLWithPath: "pi/lokalbot-extension")
        let skillDir = resources?.appendingPathComponent("pi/lokalbot-cli-skill")
        let skillExists = skillDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let sessions = sessionsDirectory
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return PiLaunchPlanner.plan(
            bun: AgentRuntimeLayout.bunBinary(under: runtimeRoot),
            piCLI: AgentRuntimeLayout.piCLI(under: runtimeRoot),
            extensionDirectory: extensionDir,
            skillDirectory: skillExists ? skillDir : nil,
            sessionDirectory: sessions,
            workspace: workspace,
            endpoint: endpoint,
            helpersDirectory: FileManager.default.fileExists(atPath: helpers.path) ? helpers : nil,
            agentAccessCapability: capabilityToken,
            continuePreviousSession: launchMode == .continueRecent)
    }

    // MARK: - Helpers

    private var isFailed: Bool {
        if case .failed = state { return true } else { return false }
    }

    private func publish() {
        folder.enforceResourceLimits()
        items = folder.items
    }

    private func enqueueTextDelta(_ delta: String) {
        let room = max(0, AgentTranscriptFolder.maximumMessageCharacters - pendingTextDelta.count)
        if room > 0 { pendingTextDelta.append(contentsOf: delta.prefix(room)) }
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            guard !Task.isCancelled else { return }
            self?.flushPendingTextDelta()
        }
    }

    private func flushPendingTextDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !pendingTextDelta.isEmpty else { return }
        let delta = pendingTextDelta
        pendingTextDelta = ""
        folder.fold(.messageUpdate(.textDelta(delta)))
        publish()
    }

    private func discardPendingTextDelta() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        pendingTextDelta = ""
    }

    /// Fire-and-forget so the synchronous failure paths can call it; the
    /// broker serializes the release internally.
    private func releaseLLMLease() {
        guard let lease = llmLease else { return }
        llmLease = nil
        let broker = self.broker
        Task { await broker.release(lease) }
    }

    private func revokeAccessCapability() {
        guard let capability = accessCapability else { return }
        accessCapability = nil
        accessGate.revoke(capability)
    }

    private func cancelPendingApprovals() async {
        let ids = folder.pendingApprovalIDs
        if let client {
            for id in ids {
                try? await client.sendResponse(.uiCancelResponse(requestID: id))
            }
        }
        folder.resolveAllApprovals()
        publish()
    }

    private func freshID(_ prefix: String) -> String {
        nextRequestID += 1
        return "\(prefix)\(nextRequestID)"
    }

    private func pendingApprovalRequest(requestID: String) -> AgentApprovalRequest? {
        for item in folder.items {
            if case .approval(let request) = item, request.id == requestID { return request }
        }
        return nil
    }

    func canAllowForSession(_ request: AgentApprovalRequest) -> Bool {
        AgentApprovalPolicy.canPersistApproval(
            tool: request.tool,
            path: request.path,
            requestWorkspace: request.workspace,
            selectedWorkspace: workspace)
    }

    private func fail(with error: Error) async {
        flushPendingTextDelta()
        let message = Self.message(for: error)
        await transitionToFailure(message: message, recovery: .restart)
    }

    /// Invalidates the current event generation before awaiting subprocess
    /// shutdown. That prevents already-buffered frames from reviving `.ready`
    /// or `.running` while teardown yields, and keeps restart disabled until
    /// the old process has actually been terminated.
    private func transitionToFailure(message: String, recovery: RecoveryAction) async {
        guard !failureTeardownInProgress,
              state != .idle,
              !isFailed else { return }
        failureTeardownInProgress = true
        lifecycleGeneration += 1
        let failureGeneration = lifecycleGeneration
        recoveryAction = nil
        eventTask?.cancel()
        eventTask = nil
        discardPendingTextDelta()
        let oldProcess = process
        process = nil
        client = nil
        folder.resolveAllApprovals()
        policy.resetSession()
        autoApproveSession = false
        revokeAccessCapability()
        folder.appendNotice(message, isError: true)
        publish()
        releaseLLMLease()
        await oldProcess?.stop()
        failureTeardownInProgress = false
        guard failureGeneration == lifecycleGeneration else { return }
        state = .failed(message)
        recoveryAction = recovery
    }

    private func setFailure(_ error: Error) {
        folder.resolveAllApprovals()
        policy.resetSession()
        autoApproveSession = false
        revokeAccessCapability()
        releaseLLMLease()
        state = .failed(Self.message(for: error))
        if case StartError.modelConfiguration = error {
            recoveryAction = .openModels
        } else {
            recoveryAction = .restart
        }
    }

    /// Our extension sends title "lokalbot_tool_approval" with exact structured
    /// fields. Older payloads containing only `summary` remain readable.
    static func parseApprovalPayload(_ request: PiUIRequest) -> AgentApprovalRequest {
        if request.title == "lokalbot_tool_approval",
           let data = request.message?.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ApprovalPayload.self, from: data) {
            return AgentApprovalRequest(
                id: request.id,
                tool: payload.tool,
                workspace: payload.workspace,
                path: payload.path,
                command: payload.command,
                content: payload.content,
                edits: (payload.edits ?? []).map {
                    AgentApprovalRequest.Edit(oldText: $0.oldText, newText: $0.newText)
                },
                summary: payload.summary,
                isTruncated: payload.truncated ?? false)
        }
        return AgentApprovalRequest(
            id: request.id,
            tool: request.title ?? "action",
            workspace: nil,
            path: nil,
            command: nil,
            content: nil,
            edits: [],
            summary: request.message,
            isTruncated: false)
    }

    var workspaceDisplayName: String {
        if workspace.standardizedFileURL == storage.rootURL.standardizedFileURL {
            return "Meeting Library"
        }
        return workspace.lastPathComponent.isEmpty ? workspace.path : workspace.lastPathComponent
    }

    var requiresCloseConfirmation: Bool {
        state == .running
            || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !items.isEmpty
    }

    var canResumePreviousSession: Bool {
        Self.hasResumableSession(in: sessionsDirectory, workspace: workspace)
    }

    var sessionStorageDirectory: URL { sessionsDirectory }

    static func hasResumableSession(in directory: URL, workspace: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return false }
        let expectedCWD = workspace.standardizedFileURL.path
        for file in files where file.pathExtension == "jsonl" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 16 * 1024),
                  let firstLine = data.split(separator: 0x0A).first,
                  let header = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
                  header["type"] as? String == "session",
                  let cwd = header["cwd"] as? String else { continue }
            if URL(fileURLWithPath: cwd).standardizedFileURL.path == expectedCWD {
                return true
            }
        }
        return false
    }

    private static func makeSessionTitle(from prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 36 else { return trimmed }
        let prefix = String(trimmed.prefix(35))
        let wordBoundary = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
        return wordBoundary.trimmingCharacters(in: .whitespaces) + "…"
    }

    private struct ApprovalPayload: Decodable {
        struct Edit: Decodable {
            let oldText: String
            let newText: String
        }

        let tool: String
        let workspace: String?
        let path: String?
        let command: String?
        let content: String?
        let edits: [Edit]?
        let summary: String?
        let truncated: Bool?
    }

    private enum LaunchMode {
        case fresh
        case continueRecent
    }

    private func restorePreviousMessages(using client: PiRPCClient) async {
        do {
            let response = try await client.request(.getMessages(id: freshID("history")))
            guard response.success else {
                folder.appendNotice(response.error ?? "Couldn't restore the previous session.", isError: true)
                publish()
                return
            }
            let messages = Self.historyMessages(from: response.dataJSON)
            guard !messages.isEmpty else {
                folder.appendNotice("No previous conversation was found for this working folder.")
                publish()
                return
            }
            folder = AgentTranscriptFolder()
            for message in messages {
                switch message.role {
                case "user":
                    if sessionTitle == nil { sessionTitle = Self.makeSessionTitle(from: message.text) }
                    folder.noteUserPrompt(message.text)
                case "assistant":
                    folder.appendAssistantMessage(message.text)
                default:
                    break
                }
            }
            folder.appendNotice("Resumed the most recent session for this working folder.")
            publish()
        } catch {
            folder.appendNotice("Couldn't restore the previous session: \(Self.message(for: error))",
                                isError: true)
            publish()
        }
    }

    private static func historyMessages(from dataJSON: String?) -> [(role: String, text: String)] {
        guard let dataJSON,
              let data = dataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { message in
            guard let role = message["role"] as? String,
                  role == "user" || role == "assistant" else { return nil }
            let text: String
            if let content = message["content"] as? String {
                text = content
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.compactMap { block in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }.joined()
            } else {
                return nil
            }
            guard !text.isEmpty else { return nil }
            return (role, text)
        }
    }

    enum StartError: Error { case modelConfiguration(String) }

    private static func message(for error: Error) -> String {
        switch error {
        case StartError.modelConfiguration(let reason): return reason
        case PiProcessError.executableNotFound:
            return "The agent runtime isn't installed. Enable Agent Mode to download it."
        case PiRPCError.transportClosed:
            return "The agent process exited unexpectedly."
        default:
            return error.localizedDescription
        }
    }
}
