import Foundation

/// Commands sent to pi over stdin (JSONL).
enum PiCommand: Equatable {
    case prompt(id: String, message: String, streamingBehavior: String?)
    case steer(id: String, message: String)
    case abort(id: String)
    case newSession(id: String)
    case getState(id: String)
    case getMessages(id: String)
    case getSessionStats(id: String)
    case uiConfirmResponse(requestID: String, confirmed: Bool)
    case uiCancelResponse(requestID: String)

    var jsonLine: String {
        var dict: JSONObject
        switch self {
        case .prompt(let id, let message, let behavior):
            dict = ["type": "prompt", "id": .string(id), "message": .string(message)]
            if let behavior { dict["streamingBehavior"] = .string(behavior) }
        case .steer(let id, let message):
            dict = ["type": "steer", "id": .string(id), "message": .string(message)]
        case .abort(let id):
            dict = ["type": "abort", "id": .string(id)]
        case .newSession(let id):
            dict = ["type": "new_session", "id": .string(id)]
        case .getState(let id):
            dict = ["type": "get_state", "id": .string(id)]
        case .getMessages(let id):
            dict = ["type": "get_messages", "id": .string(id)]
        case .getSessionStats(let id):
            dict = ["type": "get_session_stats", "id": .string(id)]
        case .uiConfirmResponse(let requestID, let confirmed):
            dict = [
                "type": "extension_ui_response",
                "id": .string(requestID),
                "confirmed": .bool(confirmed),
            ]
        case .uiCancelResponse(let requestID):
            dict = ["type": "extension_ui_response", "id": .string(requestID), "cancelled": true]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(dict)),
              let line = String(data: data, encoding: .utf8) else {
            assertionFailure("PiCommand must encode as a UTF-8 JSON object")
            return "{}"
        }
        return line
    }
}

struct PiResponse: Equatable {
    let id: String?
    let command: String
    let success: Bool
    let error: String?
    let dataJSON: String?
}

struct PiUIRequest: Equatable {
    let id: String
    let method: String
    let title: String?
    let message: String?
}

enum PiAssistantDelta: Equatable {
    case textDelta(String)
    case other(kind: String)
}

/// One decoded stdout record from pi RPC mode. Only the fields Agent Mode
/// displays are extracted; everything else lands in `.unknown` so protocol
/// additions never crash the client.
enum PiEvent: Equatable {
    case response(PiResponse)
    case agentStart
    case agentEnd
    case agentSettled
    case messageStart(role: String)
    case messageUpdate(PiAssistantDelta)
    case messageEnd(role: String, text: String)
    case toolExecutionStart(callID: String, name: String, argsJSON: String)
    case toolExecutionUpdate(callID: String, output: String)
    case toolExecutionEnd(callID: String, output: String, isError: Bool)
    case extensionUIRequest(PiUIRequest)
    case extensionError(message: String)
    case unknown(type: String)

    /// Decode one JSONL record; nil when the line isn't a JSON object.
    static func decode(line: String) -> PiEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONValue.decodeObject(from: data),
              let type = obj["type"]?.stringValue else { return nil }
        switch type {
        case "response":
            return .response(PiResponse(
                id: obj["id"]?.stringValue,
                command: obj["command"]?.stringValue ?? "",
                success: obj["success"]?.boolValue ?? false,
                error: obj["error"]?.stringValue,
                dataJSON: compactJSON(obj["data"])))
        case "agent_start": return .agentStart
        case "agent_end": return .agentEnd
        case "agent_settled": return .agentSettled
        case "message_start":
            return .messageStart(role: role(of: obj["message"]))
        case "message_update":
            guard let delta = obj["assistantMessageEvent"]?.objectValue,
                  let kind = delta["type"]?.stringValue else {
                return .messageUpdate(.other(kind: ""))
            }
            if kind == "text_delta", let text = delta["delta"]?.stringValue {
                return .messageUpdate(.textDelta(text))
            }
            return .messageUpdate(.other(kind: kind))
        case "message_end":
            return .messageEnd(role: role(of: obj["message"]), text: text(of: obj["message"]))
        case "tool_execution_start":
            return .toolExecutionStart(
                callID: obj["toolCallId"]?.stringValue ?? "",
                name: obj["toolName"]?.stringValue ?? "",
                argsJSON: compactJSON(obj["args"]) ?? "{}")
        case "tool_execution_update":
            return .toolExecutionUpdate(
                callID: obj["toolCallId"]?.stringValue ?? "",
                output: resultText(obj["partialResult"]))
        case "tool_execution_end":
            return .toolExecutionEnd(
                callID: obj["toolCallId"]?.stringValue ?? "",
                output: resultText(obj["result"]),
                isError: obj["isError"]?.boolValue ?? false)
        case "extension_ui_request":
            guard let id = obj["id"]?.stringValue,
                  let method = obj["method"]?.stringValue else {
                return .unknown(type: type)
            }
            return .extensionUIRequest(PiUIRequest(
                id: id, method: method,
                title: obj["title"]?.stringValue,
                message: obj["message"]?.stringValue))
        case "extension_error":
            return .extensionError(
                message: obj["error"]?.stringValue
                    ?? obj["message"]?.stringValue
                    ?? "extension error")
        default:
            return .unknown(type: type)
        }
    }

    private static func role(of message: JSONValue?) -> String {
        message?.objectValue?["role"]?.stringValue ?? ""
    }

    /// Joins the `text` blocks of an AgentMessage `content` array.
    private static func text(of message: JSONValue?) -> String {
        guard let content = message?.objectValue?["content"]?.objectArrayValue else { return "" }
        return content.compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined()
    }

    /// Joins the `text` blocks of a ToolResult `content` array.
    private static func resultText(_ result: JSONValue?) -> String {
        guard let content = result?.objectValue?["content"]?.objectArrayValue else { return "" }
        return content.compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined(separator: "\n")
    }

    private static func compactJSON(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        guard case .array = value else {
            guard case .object = value else { return nil }
            return encodedJSON(value)
        }
        return encodedJSON(value)
    }

    private static func encodedJSON(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
