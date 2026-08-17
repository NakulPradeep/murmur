import Foundation

/// A phonetic key tuned for the mistakes speech recognizers actually make.
///
/// Standard Soundex is too lossy (it keeps only four characters and drops all
/// vowels) and plain edit distance is too literal ("Kiran" and "Karen" are two
/// edits apart, but so are "Kiran" and "Kiwi"). This encoder collapses the
/// consonant confusions a recognizer makes — voiced/unvoiced pairs, the many
/// spellings of /f/ and /k/, silent clusters — while keeping enough structure
/// that unrelated words stay apart.
enum Phonetics {

    /// Consonant equivalence classes. Members of a class are routinely swapped
    /// by recognizers, so they encode identically.
    private static let classes: [Character: Character] = [
        "b": "P", "p": "P",
        "d": "T", "t": "T",
        "g": "K", "k": "K", "c": "K", "q": "K",
        "v": "F", "f": "F",
        "z": "S", "s": "S",
        "j": "J",
        "m": "N", "n": "N",
        "l": "L",
        "r": "R",
        "w": "W", "y": "W",
        "h": "H",
    ]

    private static let vowels = Set("aeiou")

    /// Multi-letter clusters, longest first so "sch" wins over "ch".
    private static let digraphs: [(String, String)] = [
        ("sch", "S"), ("tch", "X"),
        ("ph", "F"), ("gh", "F"), ("ck", "K"), ("qu", "KW"),
        ("th", "0"), ("sh", "X"), ("ch", "X"),
        ("kn", "N"), ("gn", "N"), ("pn", "N"), ("wr", "R"), ("ps", "S"),
        ("wh", "W"), ("dg", "J"), ("tz", "S"), ("cq", "K"),
    ]

    /// Encodes a word to its phonetic key. Non-letters are ignored, so
    /// "GPT-4" and "gpt four" reduce comparably.
    static func key(_ word: String) -> String {
        let cleaned = word.lowercased().filter { $0.isLetter }
        guard !cleaned.isEmpty else { return "" }

        var out = ""
        let chars = Array(cleaned)
        var i = 0

        // Vowels are dropped entirely, including leading ones. Keeping a
        // leading-vowel marker would split pairs the recognizer routinely
        // confuses — "Xcode" against "ex code", "specially" against
        // "especially" — for no gain elsewhere.
        while i < chars.count {
            var matchedDigraph = false
            for (pattern, code) in digraphs {
                let n = pattern.count
                guard i + n <= chars.count else { continue }
                if String(chars[i..<(i + n)]) == pattern {
                    out += code
                    i += n
                    matchedDigraph = true
                    break
                }
            }
            if matchedDigraph { continue }

            let ch = chars[i]
            if vowels.contains(ch) {
                i += 1
                continue
            }
            // "x" is two sounds. Encoding it as a bare /s/ separates "Xcode"
            // from "ex code", which is exactly the split we want to avoid.
            if ch == "x" {
                out += "KS"
                i += 1
                continue
            }
            // w and y after a vowel are part of a diphthong, not consonants:
            // the "aw" in "clawed" is the same sound as the "au" in "Claude",
            // and treating them as consonants keeps those two apart.
            if ch == "w" || ch == "y" {
                let precededByVowel = i > 0 && vowels.contains(chars[i - 1])
                if precededByVowel || (ch == "y" && i > 0) {
                    i += 1
                    continue
                }
            }
            // A silent h between letters carries no information.
            if ch == "h", i > 0 {
                i += 1
                continue
            }
            if let code = classes[ch] {
                out.append(code)
            }
            i += 1
        }

        // Collapse runs: recognizers rarely preserve gemination.
        var collapsed = ""
        for ch in out where collapsed.last != ch {
            collapsed.append(ch)
        }

        // Short words have too little consonant structure to stay distinct on
        // their own — "code" and "cat" both reduce to KT. Below three
        // consonants, keep the first vowel so they separate again. Longer words
        // have enough skeleton that dropping vowels is safe, which is what lets
        // "Kiran" and "Karen" still match.
        if collapsed.count < 3, let vowel = cleaned.first(where: { vowels.contains($0) }) {
            collapsed.append(vowel)
        }
        return collapsed
    }

    /// Levenshtein distance, bounded — returns `limit + 1` as soon as it is
    /// clear the true distance exceeds `limit`, so long mismatches cost little.
    static func editDistance(_ a: String, _ b: String, limit: Int = Int.max) -> Int {
        if a == b { return 0 }
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        if abs(x.count - y.count) > limit { return limit + 1 }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowBest = min(rowBest, current[j])
            }
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// 0–1 similarity combining phonetic and literal distance.
    ///
    /// Phonetic agreement dominates, because that is the signal that survives
    /// recognition; spelling distance breaks ties so that homophonous but
    /// clearly different words do not match.
    static func similarity(_ candidate: String, _ target: String) -> Double {
        let a = candidate.lowercased(), b = target.lowercased()
        if a == b { return 1 }

        let ka = key(candidate), kb = key(target)
        guard !ka.isEmpty, !kb.isEmpty else { return 0 }

        let phoneticDistance = editDistance(ka, kb, limit: max(ka.count, kb.count))
        let phonetic = 1.0 - Double(phoneticDistance) / Double(max(ka.count, kb.count))

        let literalDistance = editDistance(a, b, limit: max(a.count, b.count))
        let literal = 1.0 - Double(literalDistance) / Double(max(a.count, b.count))

        return phonetic * 0.75 + literal * 0.25
    }
}
