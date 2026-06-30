import Foundation

/// Pure helper for KV-cache reuse. Given the token sequence currently resident
/// in the llama context (`cached`) and the freshly tokenized prompt (`next`),
/// returns the number of leading tokens they share. The runtime keeps that
/// prefix in the KV cache and re-prefills only `next[p...]`, which is what makes
/// per-keystroke decode cheap as the user types forward.
enum IncrementalPrefill {
    static func commonPrefixLength(_ a: [Int32], _ b: [Int32]) -> Int {
        let limit = min(a.count, b.count)
        var p = 0
        while p < limit && a[p] == b[p] { p += 1 }
        return p
    }
}
