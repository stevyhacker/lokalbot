import Darwin
import Foundation

/// Observation-only ledger for model runtimes that do not belong to the GGUF
/// eviction ledger. It covers retained in-process CoreML/MLX models and
/// short-lived ONNX helpers, without changing their established lifetimes.
@MainActor
final class ModelRuntimeRegistry: ObservableObject {
    static let shared = ModelRuntimeRegistry()

    struct Resident: Identifiable, Equatable, Sendable {
        let id: String
        var role: String
        var label: String
        var estimatedBytes: UInt64?
        var processIdentifier: pid_t?
        var processStartTime: UInt64?
    }

    @Published private(set) var residents: [Resident] = []

    func register(id: String, role: String, label: String,
                  estimatedBytes: UInt64?,
                  processIdentifier: pid_t? = nil,
                  processStartTime: UInt64? = nil) {
        let resident = Resident(
            id: id,
            role: role,
            label: label,
            estimatedBytes: estimatedBytes,
            processIdentifier: processIdentifier,
            processStartTime: processStartTime
        )
        if let index = residents.firstIndex(where: { $0.id == id }) {
            residents[index] = resident
        } else {
            residents.append(resident)
        }
    }

    func unregister(id: String) {
        residents.removeAll { $0.id == id }
    }

    nonisolated static func gibibytes(_ value: Double) -> UInt64 {
        UInt64(value * 1_073_741_824)
    }

    nonisolated static func fileBytes(at url: URL) -> UInt64? {
        guard let number = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )[.size] as? NSNumber else { return nil }
        return number.uint64Value
    }
}
