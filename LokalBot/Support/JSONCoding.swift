import Foundation

/// Fresh coders for LokalBot's human-readable, date-bearing persistence files.
/// Returning new instances avoids sharing mutable Foundation coders across
/// actors while keeping the on-disk format consistent between stores.
enum JSONCoding {
    static func prettyPrintedISO8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
