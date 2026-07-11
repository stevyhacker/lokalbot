import Foundation

/// Minimal local llama-server chat surface so tests can substitute a mock.
protocol LlamaChatClient {
    func healthy() async -> Bool
    func complete(messages: [[String: String]]) async throws -> String
}

struct URLSessionLlamaChatClient: LlamaChatClient {
    static let mainServerBaseURL = URL(string: "http://127.0.0.1:17872")!

    var baseURL = URLSessionLlamaChatClient.mainServerBaseURL

    func healthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func complete(messages: [[String: String]]) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": messages,
            "temperature": 0.2,
            "max_tokens": 1024,
        ] as [String: Any])

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }
}

/// Question in, local model reads the library, synthesized answer and
/// citations out. Owns the health probe, app wake, and error taxonomy.
struct AskLibraryEngine {
    var gate: AgentAccessGate
    var client: LlamaChatClient = URLSessionLlamaChatClient()
    var loadMeetings: () throws -> [Meeting] = SessionLookup.loadAllMeetings
    var pollDelay: () async -> Void = {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    var maxPollAttempts = 60

    func ask(_ question: String) async -> ToolResult {
        guard gate.isEnabled else {
            return .error(.accessDisabled, FileLibraryToolProvider.accessDisabledMessage)
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error(
                .invalidArguments,
                "ask_library requires a non-empty \"question\" string.")
        }

        if await !client.healthy(), let failure = await wakeAndWait() {
            return failure
        }

        let meetings = (try? loadMeetings()) ?? []
        guard !meetings.isEmpty else {
            return .text("The meeting library is empty — record a meeting in LokalBot first.")
        }
        let bundle = AskLibraryContext.build(question: trimmed, meetings: meetings)
        guard !bundle.contextText.isEmpty else {
            return .text("I couldn't find anything in your meetings matching that question. Try search_meetings with a specific keyword.")
        }

        let answer: String
        do {
            answer = try await client.complete(messages: AskLibraryContext.messages(
                question: trimmed,
                contextText: bundle.contextText))
        } catch {
            return .error(
                .appNotRunning,
                "Lost the connection to LokalBot's model server mid-answer (\(error.localizedDescription)). Make sure the LokalBot app is running and try again.")
        }
        return render(answer: answer, citations: bundle.citations)
    }

    private func wakeAndWait() async -> ToolResult? {
        gate.clearWakeError()
        do {
            try gate.touchWake()
        } catch {
            return .error(
                .appNotRunning,
                "Could not signal the LokalBot app (\(error.localizedDescription)). Open LokalBot and try again.")
        }

        for _ in 0..<maxPollAttempts {
            await pollDelay()
            if await client.healthy() { return nil }
            if let reason = gate.readWakeError() {
                return .error(.engineUnavailable, reason)
            }
        }
        if gate.pendingWake {
            return .error(
                .appNotRunning,
                "ask_library needs the LokalBot app running (read tools still work without it). Open LokalBot and try again.")
        }
        return .error(
            .modelLoadingTimeout,
            "The model is still loading. Try again in a moment — the first question after a cold start takes the longest.")
    }

    private func render(
        answer: String,
        citations: [AskLibraryContext.Citation]
    ) -> ToolResult {
        guard !citations.isEmpty else { return .text(answer) }
        let sources = citations.map {
            "- \($0.title) (\($0.date), id \($0.meeting_id))"
        }
        return .text(answer + "\n\nSources:\n" + sources.joined(separator: "\n"))
    }
}
