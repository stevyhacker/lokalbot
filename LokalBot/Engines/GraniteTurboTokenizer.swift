import Foundation

/// Decode only: greedy CTC produces IDs directly, so no BPE encoder or merges
/// are needed. Hugging Face ByteLevel maps all 256 bytes to Unicode scalars.
struct GraniteTurboTokenizer {
    private let vocabulary: [Int: String]

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocabulary = model["vocab"] as? [String: Int],
              let decoder = root["decoder"] as? [String: Any],
              decoder["type"] as? String == "ByteLevel",
              vocabulary["<|blank|>"] == 0,
              vocabulary.count == 16_384,
              Set(vocabulary.values) == Set(0..<16_384) else {
            throw GraniteTurboError.invalidModel("Unexpected tokenizer vocabulary or decoder.")
        }
        self.vocabulary = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.value, $0.key) })
    }

    static func collapse(_ ids: [Int32], blank: Int32 = 0) -> [Int] {
        var previous: Int32?
        return ids.compactMap { id in
            defer { previous = id }
            return id != blank && id != previous ? Int(id) : nil
        }
    }

    func decode(_ ids: [Int32]) throws -> String {
        let byteMap = Self.byteMap()
        var bytes = [UInt8]()
        for id in Self.collapse(ids) {
            guard let piece = vocabulary[id] else {
                throw GraniteTurboError.invalidModel("Unknown CTC token ID.")
            }
            for scalar in piece.unicodeScalars {
                guard let byte = byteMap[scalar.value] else {
                    throw GraniteTurboError.invalidModel("Invalid ByteLevel token.")
                }
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func byteMap() -> [UInt32: UInt8] {
        let visible = Array(33...126) + Array(161...172) + Array(174...255)
        let visibleSet = Set(visible)
        var result = Dictionary(uniqueKeysWithValues: visible.map { (UInt32($0), UInt8($0)) })
        var next = UInt32(256)
        for byte in 0...255 where !visibleSet.contains(byte) {
            result[next] = UInt8(byte)
            next += 1
        }
        return result
    }
}

enum GraniteTurboError: LocalizedError {
    case invalidModel(String)
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .invalidModel(let detail): "Granite 5 could not load: \(detail)"
        case .unsupportedLanguage:
            "Granite 5 fast mode supports English only. Select English or use another speech model."
        }
    }
}
