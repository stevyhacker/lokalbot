import CryptoKit
import Foundation

enum SHA256Digest {
    static func hex(of string: String, prefixByteCount: Int? = nil) -> String {
        hex(of: Data(string.utf8), prefixByteCount: prefixByteCount)
    }

    static func hex(of data: Data, prefixByteCount: Int? = nil) -> String {
        let digest = Array(SHA256.hash(data: data))
        return digest.prefix(prefixByteCount ?? digest.count)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
