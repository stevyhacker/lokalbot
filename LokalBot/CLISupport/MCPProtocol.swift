import Foundation


enum MCPTransportLimits {
    static let maximumRecordBytes = 1_048_576
}

/// Incremental newline-delimited stdin reader for the MCP helper. Its buffer
/// never grows with an unterminated record: once the byte limit is crossed it
/// reports one rejection and discards bytes until LF/EOF without constructing
/// an oversized `String`.
struct MCPStdioLineReader {
    enum Record: Equatable {
        case line(String)
        case oversized
        case end
    }

    private let input: FileHandle
    private let maximumRecordBytes: Int
    private let chunkBytes: Int
    private var pending = Data()
    private var reachedEOF = false
    private var discardingOversizedRecord = false

    init(
        input: FileHandle = .standardInput,
        maximumRecordBytes: Int = MCPTransportLimits.maximumRecordBytes,
        chunkBytes: Int = 64 * 1_024
    ) {
        self.input = input
        self.maximumRecordBytes = max(1, maximumRecordBytes)
        self.chunkBytes = max(1, chunkBytes)
    }

    mutating func next() throws -> Record {
        while true {
            switch nextPendingAction() {
            case .record(let record):
                return record
            case .retry:
                continue
            case .read:
                try readMore()
            }
        }
    }

    private enum PendingAction {
        case record(Record)
        case retry
        case read
    }

    private mutating func nextPendingAction() -> PendingAction {
        discardingOversizedRecord ? oversizedDiscardAction() : bufferedRecordAction()
    }

    private mutating func oversizedDiscardAction() -> PendingAction {
        if let newline = pending.firstIndex(of: 0x0A) {
            pending.removeSubrange(pending.startIndex...newline)
            discardingOversizedRecord = false
            return .retry
        }
        pending.removeAll(keepingCapacity: true)
        guard reachedEOF else { return .read }
        discardingOversizedRecord = false
        return .record(.end)
    }

    private mutating func bufferedRecordAction() -> PendingAction {
        if let newline = pending.firstIndex(of: 0x0A) {
            let byteCount = pending.distance(from: pending.startIndex, to: newline)
            guard byteCount <= maximumRecordBytes else {
                pending.removeSubrange(pending.startIndex...newline)
                return .record(.oversized)
            }
            var data = pending.prefix(upTo: newline)
            pending.removeSubrange(pending.startIndex...newline)
            trimCarriageReturn(from: &data)
            return .record(.line(String(decoding: data, as: UTF8.self)))
        }

        if pending.count > maximumRecordBytes {
            pending.removeAll(keepingCapacity: true)
            discardingOversizedRecord = true
            return .record(.oversized)
        }

        guard reachedEOF else { return .read }
        guard !pending.isEmpty else { return .record(.end) }
        var data = pending
        pending.removeAll(keepingCapacity: true)
        trimCarriageReturn(from: &data)
        return .record(.line(String(decoding: data, as: UTF8.self)))
    }

    private func trimCarriageReturn<T: RangeReplaceableCollection & BidirectionalCollection>(
        from data: inout T
    )
    where T.Element == UInt8 {
        if data.last == 0x0D {
            data.removeLast()
        }
    }

    private mutating func readMore() throws {
        let chunk = try input.read(upToCount: chunkBytes) ?? Data()
        if chunk.isEmpty {
            reachedEOF = true
        } else {
            pending.append(chunk)
        }
    }
}

/// One decoded JSON-RPC 2.0 message from an MCP client.
struct MCPRequest: Equatable {
    static let maximumLineBytes = MCPTransportLimits.maximumRecordBytes
    enum RequestID: Equatable {
        case number(Int)
        case string(String)

        var json: JSONValue {
            switch self {
            case .number(let value): .number(Double(value))
            case .string(let value): .string(value)
            }
        }
    }

    /// nil means a notification and the server must not answer it.
    var id: RequestID?
    var method: String
    var params: JSONValue?

    enum ParseOutcome: Equatable {
        case request(MCPRequest)
        case failure(code: Int, message: String, id: RequestID?)
    }

    static func parse(_ line: String) -> ParseOutcome {
        guard line.utf8.count <= maximumLineBytes else {
            return .failure(code: -32600, message: "Request exceeds the 1 MiB limit", id: nil)
        }
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let object = raw.objectValue else {
            return .failure(code: -32700, message: "Parse error", id: nil)
        }

        let id: RequestID?
        switch object["id"] {
        case .some(.number(let value)):
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= Double(Int.min),
                  value <= Double(Int.max) else {
                return .failure(code: -32600, message: "Invalid numeric request id", id: nil)
            }
            id = .number(Int(value))
        case .some(.string(let value)): id = .string(value)
        default: id = nil
        }

        guard case .some(.string("2.0")) = object["jsonrpc"],
              case .some(.string(let method)) = object["method"] else {
            return .failure(code: -32600, message: "Invalid Request", id: id)
        }
        return .request(MCPRequest(id: id, method: method, params: object["params"]))
    }
}

/// Encodes newline-delimited JSON-RPC 2.0 responses with deterministic keys.
enum MCPResponse {
    static func success(id: MCPRequest.RequestID?, result: JSONValue) -> String {
        encode(.object([
            "jsonrpc": "2.0",
            "id": id?.json ?? .null,
            "result": result,
        ]))
    }

    static func failure(id: MCPRequest.RequestID?, code: Int, message: String) -> String {
        encode(.object([
            "jsonrpc": "2.0",
            "id": id?.json ?? .null,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ]))
    }

    private static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return #"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
