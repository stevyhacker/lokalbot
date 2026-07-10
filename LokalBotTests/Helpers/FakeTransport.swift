import Foundation
@testable import LokalBot

/// A scriptable transport: records sent lines and lets the test inject
/// incoming lines.
final class FakeTransport: PiLineTransport, @unchecked Sendable {
    private(set) var sent: [String] = []
    private let lock = NSLock()
    let incoming: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        var c: AsyncStream<String>.Continuation!
        incoming = AsyncStream { c = $0 }
        continuation = c
    }

    func send(line: String) async throws {
        lock.lock(); sent.append(line); lock.unlock()
    }

    func inject(_ line: String) { continuation.yield(line) }
    func close() { continuation.finish() }
    var sentLines: [String] { lock.lock(); defer { lock.unlock() }; return sent }
}
