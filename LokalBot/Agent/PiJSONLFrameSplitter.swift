import Foundation

/// Splits a byte stream into JSONL records per pi's RPC framing rules
/// (docs/rpc.md): LF (0x0A) is the only record delimiter; one trailing CR
/// is stripped; U+2028/U+2029 inside JSON strings must NOT split records —
/// which is why this operates on raw bytes and why `PiProcess` must never
/// use a String-based line reader.
struct PiJSONLFrameSplitter {
    private var buffer = Data()

    /// Feed a chunk; returns every complete record it terminates.
    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let lf = buffer.firstIndex(of: 0x0A) {
            var record = buffer[buffer.startIndex..<lf]
            if record.last == 0x0D { record = record.dropLast() }
            if let line = String(data: record, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
            buffer.removeSubrange(buffer.startIndex...lf)
        }
        return lines
    }

    /// Drain an unterminated final record (call on EOF).
    mutating func flush() -> String? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8),
              !line.isEmpty else { return nil }
        return line
    }
}
