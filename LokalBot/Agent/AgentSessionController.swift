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

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var items: [AgentTranscriptItem] = []
    @Published var workspace: URL
    @Published var autoApproveSession = false {
        didSet { policy.autoApproveAll = autoApproveSession }
    }

    private let settings: () -> AppSettings
    private let storage: StorageManager
    private let runtimeRoot: URL
    private let makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)?

    private var policy = AgentApprovalPolicy()
    private var folder = AgentTranscriptFolder()
    private var client: PiRPCClient?
    private var process: PiProcess?
    private var eventTask: Task<Void, Never>?
    private var nextRequestID = 0

    init(settings: @escaping () -> AppSettings,
         storage: StorageManager,
         runtimeRoot: URL = AgentRuntimeLayout.defaultRoot,
         makeTransport: ((PiLaunchPlan) async throws -> PiLineTransport)? = nil) {
        self.settings = settings
        self.storage = storage
        self.runtimeRoot = runtimeRoot
        self.makeTransport = makeTransport
        self.workspace = storage.rootURL
    }

    // MARK: - Lifecycle

    func start() async {
        guard state == .idle || isFailed else { return }
        state = .starting
        do {
            let endpoint = try await resolveEndpoint()
            let plan = makePlan(endpoint: endpoint)
            let transport: PiLineTransport
            if let makeTransport {
                transport = try await makeTransport(plan)
            } else {
                let piProcess = PiProcess(plan: plan)
                try await piProcess.start()
                process = piProcess
                transport = piProcess
            }
            let rpc = PiRPCClient(transport: transport)
            await rpc.run()
            client = rpc
            consumeEvents(from: rpc)
            state = .ready
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        await process?.stop()
        process = nil
        client = nil
        state = .idle
    }

    // MARK: - Prompting

    func send(prompt: String) async {
        guard let client, state == .ready || state == .running else { return }
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
            fail(with: error)
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
            folder = AgentTranscriptFolder()
            policy.resetSession()
            publish()
            state = .ready
        } catch {
            fail(with: error)
        }
    }

    // MARK: - Approvals

    func respondToApproval(id: String, approved: Bool, scope: ApprovalScope) async {
        guard let client else { return }
        if approved, scope == .session,
           let tool = pendingApprovalTool(requestID: id) {
            policy.allowForSession(tool: tool)
        }
        folder.resolveApproval(requestID: id)
        publish()
        try? await client.sendResponse(.uiConfirmResponse(requestID: id, confirmed: approved))
    }

    // MARK: - Event loop

    private func consumeEvents(from client: PiRPCClient) {
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await client.events {
                guard !Task.isCancelled else { return }
                await self.handle(event)
            }
            // shutdown() cancels this task and only later sets .idle; a
            // cancelled iteration ending must not fold a spurious failure.
            guard !Task.isCancelled else { return }
            await self.handleStreamEnd()
        }
    }

    private func handle(_ event: PiEvent) async {
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
        let (tool, summary) = Self.parseApprovalPayload(request)
        switch policy.verdict(tool: tool) {
        case .allow:
            try? await client.sendResponse(.uiConfirmResponse(requestID: request.id, confirmed: true))
        case .ask:
            folder.addApproval(requestID: request.id, tool: tool, argsJSON: summary)
        }
    }

    private func handleStreamEnd() async {
        guard state != .idle else { return }
        var detail = "The agent process exited unexpectedly."
        if let process {
            let tail = await process.stderrTail
            if !tail.isEmpty { detail += "\n" + tail.suffix(5).joined(separator: "\n") }
        }
        folder.appendNotice(detail, isError: true)
        publish()
        state = .failed(detail)
    }

    // MARK: - Endpoint + plan

    private func resolveEndpoint() async throws -> AgentLLMEndpoint {
        switch AgentLLMEndpointResolver.resolve(settings: settings()) {
        case .ready(let endpoint):
            return endpoint
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(id: modelID, custom: settings().customBuiltInModels)
                    ?? ModelCatalog.entry(id: modelID),
                  let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                throw StartError.notReady("The built-in model isn't downloaded yet. Download it under Settings → Models.")
            }
            try await LlamaServer.shared.ensureRunning(modelAt: modelURL)
            return AgentLLMEndpoint(baseURL: LlamaServer.shared.baseURL,
                                    model: entry.id,
                                    contextTokens: AgentLLMEndpoint.defaultContextTokens,
                                    apiKey: nil)
        case .unsupported(let reason):
            throw StartError.notReady(reason)
        }
    }

    private func makePlan(endpoint: AgentLLMEndpoint) -> PiLaunchPlan {
        let resources = Bundle.main.resourceURL
        let extensionDir = resources?.appendingPathComponent("pi/lokalbot-extension")
            ?? URL(fileURLWithPath: "pi/lokalbot-extension")
        let skillDir = resources?.appendingPathComponent("pi/lokalbot-cli-skill")
        let skillExists = skillDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let sessions = AgentRuntimeLayout.sessionsDirectory
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return PiLaunchPlanner.plan(
            bun: AgentRuntimeLayout.bunBinary(under: runtimeRoot),
            piCLI: AgentRuntimeLayout.piCLI(under: runtimeRoot),
            extensionDirectory: extensionDir,
            skillDirectory: skillExists ? skillDir : nil,
            sessionDirectory: sessions,
            workspace: workspace,
            endpoint: endpoint,
            helpersDirectory: FileManager.default.fileExists(atPath: helpers.path) ? helpers : nil)
    }

    // MARK: - Helpers

    private var isFailed: Bool {
        if case .failed = state { return true } else { return false }
    }

    private func publish() {
        items = folder.items
    }

    private func freshID(_ prefix: String) -> String {
        nextRequestID += 1
        return "\(prefix)\(nextRequestID)"
    }

    private func pendingApprovalTool(requestID: String) -> String? {
        for item in folder.items {
            if case .approval(let id, let tool, _) = item, id == requestID { return tool }
        }
        return nil
    }

    private func fail(with error: Error) {
        let message = Self.message(for: error)
        folder.appendNotice(message, isError: true)
        publish()
        state = .failed(message)
    }

    /// Our extension (Task 12) sends title "lokalbot_tool_approval" with a JSON
    /// message {"tool": "...", "summary": "..."}. Anything else (a foreign confirm)
    /// falls back to displaying the title/message verbatim.
    static func parseApprovalPayload(_ request: PiUIRequest) -> (tool: String, summary: String) {
        if request.title == "lokalbot_tool_approval",
           let data = request.message?.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tool = obj["tool"] as? String {
            return (tool, obj["summary"] as? String ?? "")
        }
        return (request.title ?? "action", request.message ?? "")
    }

    enum StartError: Error { case notReady(String) }

    private static func message(for error: Error) -> String {
        switch error {
        case StartError.notReady(let reason): return reason
        case PiProcessError.executableNotFound:
            return "The agent runtime isn't installed. Enable Agent Mode to download it."
        case PiRPCError.transportClosed:
            return "The agent process exited unexpectedly."
        default:
            return error.localizedDescription
        }
    }
}
