import NaturalLanguage
import PDFKit

/// Turns a PDF into sentence-sized pieces of text for speech.
/// Speaking one sentence at a time lets us pause, skip and resume precisely.
enum PDFText {
    static let maxLength = 300

    static func chunks(from data: Data) -> [String] {
        guard let document = PDFDocument(data: data) else { return [] }
        var text = ""
        for i in 0..<document.pageCount {
            if let page = document.page(at: i)?.string { text += page + "\n" }
        }
        return split(clean(text))
    }

    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "(\\w)-\\s*\\n\\s*(\\w)", with: "$1$2", options: .regularExpression) // re-join hyphenated words
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func split(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var sentence = text[range].trimmingCharacters(in: .whitespaces)
            while sentence.count > maxLength {
                let head = sentence.prefix(maxLength)
                let cut = head.range(of: ", ", options: .backwards)?.upperBound
                    ?? head.range(of: " ", options: .backwards)?.upperBound
                    ?? head.endIndex
                out.append(sentence[..<cut].trimmingCharacters(in: .whitespaces))
                sentence = sentence[cut...].trimmingCharacters(in: .whitespaces)
            }
            if !sentence.isEmpty { out.append(sentence) }
            return true
        }
        return out
    }
}
