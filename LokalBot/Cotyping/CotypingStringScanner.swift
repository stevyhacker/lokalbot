import Foundation

enum CotypingStringScanner {
    static func trailingLetters(in text: String, endingBefore index: String.Index) -> String {
        var letters: [Character] = []
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous].isLetter else { break }
            letters.append(text[previous])
            cursor = previous
        }
        return String(letters.reversed())
    }
}
