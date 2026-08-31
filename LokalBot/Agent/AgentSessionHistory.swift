import Foundation

/// Lightweight metadata for one durable Pi session. Conversation contents
/// stay in Pi's JSONL file and are loaded only when the user opens the session.
struct AgentSavedSession: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let fileURL: URL
    let workspace: URL
    let title: String
    let createdAt: Date
    let modifiedAt: Date
    let messageCount: Int

    var searchableText: String {
        "\(title) \(workspace.lastPathComponent) \(workspace.path)"
    }
}

/// Bounded, streaming reader for the local session directory. It intentionally
/// extracts only list metadata instead of retaining full prompts or responses.
enum AgentSessionHistory {
    private static let readChunkBytes = 64 * 1_024
    private static let maximumJSONLineBytes = 4 * 1_024 * 1_024

    static func load(from directory: URL) throws -> [AgentSavedSession] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey,
        ]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
        return files.compactMap { file in
            guard file.pathExtension.lowercased() == "jsonl",
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return nil }
            return parse(file: file, resourceValues: values)
        }
        .sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.title < $1.title }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    /// Re-reads the selected file immediately before launch so a stale list
    /// item, replaced file, or symlink cannot redirect an exact-session open.
    static func validated(
        _ session: AgentSavedSession,
        in directory: URL
    ) -> AgentSavedSession? {
        let expectedParent = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let actualParent = session.fileURL.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard actualParent == expectedParent,
              session.fileURL.pathExtension.lowercased() == "jsonl" else { return nil }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey,
        ]
        guard let values = try? session.fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let refreshed = parse(file: session.fileURL, resourceValues: values),
              refreshed.sessionID == session.sessionID,
              refreshed.workspace.standardizedFileURL.path
                == session.workspace.standardizedFileURL.path else { return nil }
        return refreshed
    }

    private static func parse(
        file: URL,
        resourceValues: URLResourceValues
    ) -> AgentSavedSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var parser = MetadataParser(
            fallbackCreatedAt: resourceValues.creationDate ?? resourceValues.contentModificationDate ?? .distantPast,
            fallbackModifiedAt: resourceValues.contentModificationDate ?? resourceValues.creationDate ?? .distantPast)
        var buffer = Data()
        var droppingOversizedLine = false

        readLoop: while true {
            switch readChunk(from: handle) {
            case .data(let chunk):
                append(
                    chunk,
                    to: &buffer,
                    droppingOversizedLine: &droppingOversizedLine)
                consumeCompleteLines(from: &buffer, with: &parser)
                trimOversizedRemainder(
                    buffer: &buffer,
                    droppingOversizedLine: &droppingOversizedLine)
            case .end:
                break readLoop
            case .failure:
                return nil
            }
        }

        if !droppingOversizedLine, !buffer.isEmpty, buffer.count <= maximumJSONLineBytes {
            parser.consume(buffer)
        }
        return parser.session(file: file)
    }

    private enum ChunkRead {
        case data(Data)
        case end
        case failure
    }

    private static func readChunk(from handle: FileHandle) -> ChunkRead {
        do {
            guard let chunk = try handle.read(upToCount: readChunkBytes),
                  !chunk.isEmpty else { return .end }
            return .data(chunk)
        } catch {
            return .failure
        }
    }

    private static func append(
        _ chunk: Data,
        to buffer: inout Data,
        droppingOversizedLine: inout Bool
    ) {
        var appendStart = chunk.startIndex
        if droppingOversizedLine {
            guard let newline = chunk.firstIndex(of: 0x0A) else { return }
            appendStart = chunk.index(after: newline)
            droppingOversizedLine = false
        }
        guard appendStart < chunk.endIndex else { return }
        buffer.append(contentsOf: chunk[appendStart...])
    }

    private static func consumeCompleteLines(
        from buffer: inout Data,
        with parser: inout MetadataParser
    ) {
        var consumedThrough = buffer.startIndex
        while let newline = buffer[consumedThrough...].firstIndex(of: 0x0A) {
            let line = buffer[consumedThrough..<newline]
            if line.count <= maximumJSONLineBytes {
                parser.consume(Data(line))
            }
            consumedThrough = buffer.index(after: newline)
            if consumedThrough == buffer.endIndex { break }
        }
        guard consumedThrough > buffer.startIndex else { return }
        buffer.removeSubrange(buffer.startIndex..<consumedThrough)
    }

    private static func trimOversizedRemainder(
        buffer: inout Data,
        droppingOversizedLine: inout Bool
    ) {
        guard buffer.count > maximumJSONLineBytes else { return }
        buffer.removeAll(keepingCapacity: true)
        droppingOversizedLine = true
    }

    private struct MetadataParser {
        let fallbackCreatedAt: Date
        let fallbackModifiedAt: Date
        private let iso8601 = ISO8601DateFormatter()
        private let fractionalISO8601: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private var sessionID: String?
        private var workspace: URL?
        private var createdAt: Date?
        private var modifiedAt: Date?
        private var explicitName: String?
        private var firstUserMessage: String?
        private var messageCount = 0

        init(fallbackCreatedAt: Date, fallbackModifiedAt: Date) {
            self.fallbackCreatedAt = fallbackCreatedAt
            self.fallbackModifiedAt = fallbackModifiedAt
        }

        mutating func consume(_ data: Data) {
            guard !data.isEmpty,
                  let object = try? JSONValue.decodeObject(from: data),
                  let type = object["type"]?.stringValue else { return }
            if sessionID == nil {
                guard type == "session",
                      let id = object["id"]?.stringValue,
                      !id.isEmpty,
                      let cwd = object["cwd"]?.stringValue,
                      !cwd.isEmpty else { return }
                sessionID = id
                workspace = URL(fileURLWithPath: cwd).standardizedFileURL
                createdAt = date(from: object["timestamp"]) ?? fallbackCreatedAt
                return
            }

            if type == "session_info" {
                explicitName = object["name"]?.stringValue?.trimmingCharacters(
                    in: .whitespacesAndNewlines).nilIfEmpty
                return
            }
            guard type == "message",
                  let message = object["message"]?.objectValue,
                  let role = message["role"]?.stringValue,
                  role == "user" || role == "assistant" else { return }
            messageCount += 1
            if let activity = date(from: message["timestamp"]) ?? date(from: object["timestamp"]),
               activity > (modifiedAt ?? .distantPast) {
                modifiedAt = activity
            }
            if role == "user", firstUserMessage == nil {
                firstUserMessage = Self.text(from: message["content"])
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
        }

        func session(file: URL) -> AgentSavedSession? {
            guard let sessionID, let workspace, messageCount > 0 else { return nil }
            let titleSource = explicitName ?? firstUserMessage ?? "Untitled session"
            return AgentSavedSession(
                id: file.standardizedFileURL.path,
                sessionID: sessionID,
                fileURL: file.standardizedFileURL,
                workspace: workspace,
                title: Self.displayTitle(titleSource),
                createdAt: createdAt ?? fallbackCreatedAt,
                modifiedAt: modifiedAt ?? createdAt ?? fallbackModifiedAt,
                messageCount: messageCount)
        }

        private func date(from value: JSONValue?) -> Date? {
            if let milliseconds = value?.doubleValue {
                return Date(timeIntervalSince1970: milliseconds / 1_000)
            }
            guard let value = value?.stringValue else { return nil }
            return fractionalISO8601.date(from: value) ?? iso8601.date(from: value)
        }

        private static func text(from value: JSONValue?) -> String {
            if let value = value?.stringValue { return value }
            guard let blocks = value?.objectArrayValue else { return "" }
            return blocks.compactMap { block in
                block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
            }.joined(separator: "\n")
        }

        private static func displayTitle(_ text: String) -> String {
            let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
            let collapsed = firstLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard collapsed.count > 80 else { return collapsed }
            let prefix = String(collapsed.prefix(79))
            let wordBoundary = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
            return wordBoundary + "…"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
