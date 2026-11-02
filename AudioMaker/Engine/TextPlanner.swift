import Foundation

/// Splits text into paragraphs and sentences, and groups sentences into speakable chunks.
enum TextPlanner {
    private static let sentenceBreak = try! NSRegularExpression(pattern: #"(?<=[.!?…])\s+(?=["'“‘(\[]?[A-Z0-9])"#)
    private static let abbrev = try! NSRegularExpression(pattern: #"\b(Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc|e\.g|i\.e|No|Vol|Fig|Inc|Ltd|Co|[A-Z])\.$"#)

    static func paragraphs(_ text: String) -> [String] {
        text.split(separator: try! Regex(#"\n\s*\n"#)).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func sentences(_ text: String) -> [Sentence] {
        var out: [Sentence] = []
        for (p, para) in paragraphs(text).enumerated() {
            let flat = para.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            var merged: [String] = []
            for piece in split(flat, on: sentenceBreak) {
                if let last = merged.last, matches(abbrev, last) || last.count < 4 {
                    merged[merged.count - 1] = last + " " + piece
                } else if !piece.isEmpty {
                    merged.append(piece)
                }
            }
            out += merged.map { Sentence(t: $0, p: p) }
        }
        return out
    }

    /// Sentences (over-long ones split on spaces) grouped into chunks of at most ~maxChars.
    static func plan(_ text: String, maxChars: Int) -> (sentences: [Sentence], groups: [[Int]]) {
        var sents: [Sentence] = []
        for s in sentences(text) {
            var t = Substring(s.t)
            while t.count > maxChars {
                let window = t.prefix(maxChars)
                let cut = window.lastIndex(of: " ") ?? window.endIndex
                sents.append(Sentence(t: String(t[..<cut]), p: s.p))
                t = t[cut...].drop { $0 == " " }
            }
            if !t.isEmpty { sents.append(Sentence(t: String(t), p: s.p)) }
        }
        var groups: [[Int]] = [], cur: [Int] = [], size = 0
        for (i, s) in sents.enumerated() {
            let newPara = cur.last.map { sents[$0].p != s.p } ?? false
            if !cur.isEmpty && (size + s.t.count + 1 > maxChars || (newPara && Double(size) > Double(maxChars) * 0.6)) {
                groups.append(cur); cur = []; size = 0
            }
            cur.append(i); size += s.t.count + 1
        }
        if !cur.isEmpty { groups.append(cur) }
        return (sents, groups)
    }

    static func groupText(_ sents: [Sentence], _ group: [Int]) -> String {
        var out = ""
        for (n, i) in group.enumerated() {
            if n > 0 { out += sents[i].p != sents[group[n - 1]].p ? "\n\n" : " " }
            out += sents[i].t
        }
        return out
    }

    /// Rough relative speaking time, used to place sentences inside a multi-sentence chunk.
    static func speechWeight(_ s: String) -> Double {
        var letters = 0, digits = 0, pauses = 0
        for c in s {
            if c.isNumber { digits += 1 }
            if c.isLetter || c.isNumber { letters += 1 }
            if ",;:\u{2014}\u{2013}".contains(c) { pauses += 4 }
            if ".!?\u{2026}".contains(c) { pauses += 7 }
        }
        return Double(letters + pauses + digits * 2 + 8)
    }

    // MARK: helpers

    private static func split(_ s: String, on re: NSRegularExpression) -> [String] {
        let ns = s as NSString
        var out: [String] = [], start = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start))
        return out
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}
