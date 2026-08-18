import Foundation

/// Converts numbers between spoken-word and numeral form.
///
/// The three public entry points correspond to the user-facing number modes:
/// - `wordsToNumerals` — "forty two" → "42"          (Numerals mode, and pass 1 of Auto)
/// - `numeralsToWords` — "42" → "forty-two"          (Words mode)
/// - `smallNumeralsToWords` — "3" → "three"          (pass 2 of Auto: words below ten)
enum NumberEngine {

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "lakh": 100_000, "million": 1_000_000,
        "crore": 10_000_000, "billion": 1_000_000_000, "trillion": 1_000_000_000_000,
    ]

    // MARK: - Words → numerals

    private enum Tok {
        case word(String)   // original word token (lowercased for matching)
        case other(String)  // whitespace / punctuation, preserved verbatim
    }

    private static func tokenize(_ text: String) -> [(raw: String, isWord: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var currentIsWord = false
        for ch in text {
            let isWord = ch.isLetter || ch == "-" || ch == "'"
            if current.isEmpty || isWord == currentIsWord {
                current.append(ch)
                currentIsWord = isWord
            } else {
                result.append((current, currentIsWord))
                current = String(ch)
                currentIsWord = isWord
            }
        }
        if !current.isEmpty { result.append((current, currentIsWord)) }
        return result
    }

    /// A single spoken-number word, or a hyphenated compound like "forty-two" / "twenty-first".
    private struct NumberWord {
        var value = 0
        var isUnit = false
        var isTens = false
        var isTeen = false
        var isScale = false
        var isZero = false
        var ordinalSuffix: String?  // "st"/"nd"/"rd"/"th" when the word was ordinal
        var compound = false        // came from a hyphenated pair
    }

    private static let ordinalUnits: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]
    private static let ordinalTeens: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    private static let ordinalTens: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]

    private static func ordinalSuffix(for n: Int) -> String {
        let mod100 = n % 100
        if (11...13).contains(mod100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func parseNumberWord(_ lower: String) -> NumberWord? {
        if let v = units[lower] {
            return NumberWord(value: v, isUnit: true, isZero: v == 0)
        }
        if let v = teens[lower] { return NumberWord(value: v, isTeen: true) }
        if let v = tens[lower] { return NumberWord(value: v, isTens: true) }
        if let v = scales[lower] { return NumberWord(value: v, isScale: true) }

        // Hyphenated compounds: forty-two, twenty-first
        if lower.contains("-") {
            let parts = lower.split(separator: "-").map(String.init)
            if parts.count == 2, let t = tens[parts[0]] {
                if let u = units[parts[1]], u != 0 {
                    return NumberWord(value: t + u, isTeen: true, compound: true)
                }
                if let ou = ordinalUnits[parts[1]] {
                    return NumberWord(value: t + ou, isTeen: true,
                                      ordinalSuffix: ordinalSuffix(for: t + ou), compound: true)
                }
            }
            return nil
        }
        return nil
    }

    /// Parses ordinal words only when they extend an in-progress number
    /// ("twenty first" → 21st). Standalone "first/second/third" are left alone —
    /// they're usually not numbers in ordinary speech.
    private static func parseOrdinalContinuation(_ lower: String) -> NumberWord? {
        if let v = ordinalUnits[lower] {
            return NumberWord(value: v, isUnit: true, ordinalSuffix: ordinalSuffix(for: v))
        }
        if let v = ordinalTeens[lower] {
            return NumberWord(value: v, isTeen: true, ordinalSuffix: ordinalSuffix(for: v))
        }
        if let v = ordinalTens[lower] {
            return NumberWord(value: v, isTens: true, ordinalSuffix: ordinalSuffix(for: v))
        }
        if lower == "hundredth" {
            return NumberWord(value: 100, isScale: true, ordinalSuffix: "th")
        }
        if lower == "thousandth" {
            return NumberWord(value: 1000, isScale: true, ordinalSuffix: "th")
        }
        return nil
    }

    /// Accumulator for one spoken number phrase ("one hundred and forty two").
    private struct Accumulator {
        var total = 0
        var current = 0
        var consumedWords = 0
        var sawAnything = false
        var lastWasUnit = false
        var lastWasTens = false
        var lastWasTeen = false
        var zeroOnly = false
        var ordinalSuffix: String?
        /// Set when the spoken number is too large to represent; the phrase is
        /// then left exactly as the recognizer produced it.
        var overflowed = false
        /// Set once a two-part year has been folded in, so "twenty twenty
        /// twenty" cannot keep compounding.
        var didYear = false

        var value: Int {
            let (sum, overflow) = total.addingReportingOverflow(current)
            return overflow ? Int.max : sum
        }

        /// True when `w` reads as the second half of a year: "nineteen |
        /// eighty four", "twenty | twenty four". The leading part is limited to
        /// 10–29 so this covers 1000–2999 and leaves "forty fifty" alone.
        func startsYearTail(_ w: NumberWord) -> Bool {
            guard !didYear, total == 0, (10...29).contains(current),
                  w.isTens || w.isTeen else { return false }
            return true
        }

        mutating func canAccept(_ w: NumberWord) -> Bool {
            if !sawAnything { return true }
            if ordinalSuffix != nil { return false }  // ordinal terminates a number
            if w.isZero { return false }
            if startsYearTail(w) { return true }
            if w.isUnit { return !lastWasUnit && !lastWasTeen }
            if w.isTens || w.isTeen { return !lastWasUnit && !lastWasTens && !lastWasTeen }
            if w.isScale { return true }
            return false
        }

        mutating func accept(_ w: NumberWord) {
            if startsYearTail(w) {
                // "nineteen" + "eighty" -> 1900 + 80, so a following unit
                // ("four") lands in the tens slot and completes 1984.
                total = current * 100
                current = w.value
                didYear = true
                sawAnything = true
                lastWasUnit = false
                lastWasTens = w.isTens
                lastWasTeen = w.isTeen
                consumedWords += 1
                return
            }
            sawAnything = true
            if w.isZero && consumedWords == 0 { zeroOnly = true }
            if w.isScale {
                // A recognizer repetition loop ("hundred hundred hundred…")
                // overflows Int here and traps. Saturate instead: the phrase is
                // nonsense either way, but the app must not die on it.
                if w.value == 100 {
                    let (product, overflow) = max(current, 1).multipliedReportingOverflow(by: 100)
                    if overflow { overflowed = true } else { current = product }
                } else {
                    let (product, mulOverflow) =
                        max(current, 1).multipliedReportingOverflow(by: w.value)
                    let (sum, addOverflow) = total.addingReportingOverflow(
                        mulOverflow ? 0 : product)
                    if mulOverflow || addOverflow { overflowed = true } else { total = sum }
                    current = 0
                }
                lastWasUnit = false; lastWasTens = false; lastWasTeen = false
            } else {
                current += w.value
                lastWasUnit = w.isUnit && !w.compound
                lastWasTens = w.isTens
                lastWasTeen = w.isTeen || w.compound
            }
            ordinalSuffix = w.ordinalSuffix
            consumedWords += 1
        }
    }

    static func wordsToNumerals(_ text: String) -> String {
        let toks = tokenize(text)
        var out = ""
        var i = 0

        while i < toks.count {
            let (raw, isWord) = toks[i]
            guard isWord else { out += raw; i += 1; continue }

            let lower = raw.lowercased()
            var start = parseNumberWord(lower)

            // "a hundred", "a million" — treat leading article as one
            var articlePrefix = false
            if start == nil, lower == "a" || lower == "an" {
                if let (nextIdx, nextWord) = nextWordToken(toks, after: i),
                   let nw = parseNumberWord(nextWord.lowercased()), nw.isScale {
                    _ = nextIdx
                    start = NumberWord(value: 1, isUnit: true)
                    articlePrefix = true
                }
            }

            guard var first = start else { out += raw; i += 1; continue }

            // Standalone "one" is usually a pronoun-ish word ("one of the things").
            // Only convert when it starts a longer phrase: "one hundred", "one point five".
            if !articlePrefix, lower == "one" {
                let continues: Bool = {
                    guard let (_, next) = nextWordToken(toks, after: i) else { return false }
                    let nl = next.lowercased()
                    if let nw = parseNumberWord(nl), nw.isScale { return true }
                    return nl == "point"
                }()
                if !continues { out += raw; i += 1; continue }
            }

            if articlePrefix {
                // Skip the article; the scale word is consumed by the loop below.
                first = NumberWord(value: 1, isUnit: true)
            }

            var acc = Accumulator()
            acc.accept(first)
            var j = i
            var lastConsumed = i
            j = advanceToNextToken(toks, from: i)

            var pendingAnd = false
            while j < toks.count {
                let (r2, w2) = toks[j]
                if !w2 {
                    // Separators: plain spaces continue a phrase; anything else ends it.
                    if r2.allSatisfy({ $0 == " " }) { j += 1; continue }
                    break
                }
                let l2 = r2.lowercased()
                if l2 == "and", !pendingAnd, acc.ordinalSuffix == nil {
                    pendingAnd = true
                    j += 1
                    continue
                }
                var parsed = parseNumberWord(l2)
                if parsed == nil, acc.sawAnything, acc.ordinalSuffix == nil {
                    parsed = parseOrdinalContinuation(l2)
                }
                guard let w = parsed else { break }
                var acc2 = acc
                if !acc2.canAccept(w) { break }
                if pendingAnd, w.isScale { break }  // "and thousand" — not a continuation
                acc2.accept(w)
                acc = acc2
                pendingAnd = false
                lastConsumed = j
                j += 1
            }

            // Decimal: "three point one four" / "zero point five"
            var decimalDigits = ""
            var decimalEnd = lastConsumed
            if acc.ordinalSuffix == nil {
                let k = advanceToNextToken(toks, from: lastConsumed)
                if k < toks.count, toks[k].isWord, toks[k].raw.lowercased() == "point" {
                    var digits = ""
                    var m = advanceToNextToken(toks, from: k)
                    var lastDigitIdx = -1
                    while m < toks.count, toks[m].isWord,
                          let d = units[toks[m].raw.lowercased()] ?? teens[toks[m].raw.lowercased()].flatMap({ $0 <= 9 ? $0 : nil }) {
                        digits += String(d)
                        lastDigitIdx = m
                        m = advanceToNextToken(toks, from: m)
                    }
                    if !digits.isEmpty, lastDigitIdx >= 0 {
                        decimalDigits = digits
                        decimalEnd = lastDigitIdx
                        _ = k
                    }
                }
            }

            let phraseIsMultiWord = acc.consumedWords > 1 || first.compound
                || !decimalDigits.isEmpty || acc.ordinalSuffix != nil

            // Single plain words: convert units/teens/tens ("five" → "5") but leave
            // "zero-only" pronouncements and bare scales ("a hundred" handled above,
            // bare "hundred" as in "hundreds of people" stays).
            if !phraseIsMultiWord {
                if first.isScale { out += raw; i += 1; continue }
            }

            // A number too large to represent is a recognizer repetition loop,
            // not something the user said. Leave the words untouched.
            if acc.overflowed {
                out += raw
                i += 1
                continue
            }

            var rendered = String(acc.value)
            if !decimalDigits.isEmpty { rendered += "." + decimalDigits }
            if let suffix = acc.ordinalSuffix { rendered += suffix }
            if acc.zeroOnly && acc.consumedWords == 1 && decimalDigits.isEmpty { rendered = "0" }

            out += rendered
            i = (decimalDigits.isEmpty ? lastConsumed : decimalEnd) + 1
        }
        return out
    }

    private static func nextWordToken(_ toks: [(raw: String, isWord: Bool)], after i: Int) -> (Int, String)? {
        var j = i + 1
        while j < toks.count {
            if toks[j].isWord { return (j, toks[j].raw) }
            if !toks[j].raw.allSatisfy({ $0 == " " }) { return nil }
            j += 1
        }
        return nil
    }

    /// Index of the next token that isn't a plain run of spaces.
    private static func advanceToNextToken(_ toks: [(raw: String, isWord: Bool)], from i: Int) -> Int {
        var j = i + 1
        while j < toks.count, !toks[j].isWord, toks[j].raw.allSatisfy({ $0 == " " }) { j += 1 }
        return j
    }

    // MARK: - Unit normalization (numerals mode): "20 percent" → "20%", "15 dollars" → "$15"

    static func normalizeUnits(_ text: String) -> String {
        var t = text
        let numeric = "([0-9]+(?:\\.[0-9]+)?)"

        t = t.replacingOccurrences(
            of: "\(numeric) ?percent\\b", with: "$1%",
            options: [.regularExpression, .caseInsensitive])

        let currencies: [(String, String)] = [
            ("dollars?|bucks?", "$"),
            ("rupees?", "\u{20B9}"),
            ("euros?", "\u{20AC}"),
            ("pounds? sterling|quid", "\u{00A3}"),
        ]
        for (words, symbol) in currencies {
            let escaped = symbol == "$" ? "\\$" : symbol
            t = t.replacingOccurrences(
                of: "\(numeric) (?:\(words))\\b", with: "\(escaped)$1",
                options: [.regularExpression, .caseInsensitive])
        }
        return t
    }

    // MARK: - Numerals → words

    private static let spellOut: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    static func spell(_ n: Int) -> String {
        spellOut.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// "42" → "forty-two"; "$15" → "fifteen dollars"; "20%" → "twenty percent";
    /// "3.5" → "three point five". Leaves dates, times, versions, and codes alone.
    static func numeralsToWords(_ text: String) -> String {
        var t = text

        // Currency first: $15 → fifteen dollars
        t = replaceMatches(in: t, pattern: "(?<![\\w.])[$]([0-9]+)(?![\\w.,:/-])") { groups in
            guard let n = Int(groups[1]), n < 1_000_000_000 else { return nil }
            return spell(n) + (n == 1 ? " dollar" : " dollars")
        }
        t = replaceMatches(in: t, pattern: "(?<![\\w.])\u{20B9}([0-9]+)(?![\\w.,:/-])") { groups in
            guard let n = Int(groups[1]), n < 1_000_000_000 else { return nil }
            return spell(n) + (n == 1 ? " rupee" : " rupees")
        }

        // Percent: 20% → twenty percent
        t = replaceMatches(in: t, pattern: "(?<![\\w.])([0-9]+)%") { groups in
            guard let n = Int(groups[1]), n < 1_000_000_000 else { return nil }
            return spell(n) + " percent"
        }

        // Decimals: 3.14 → three point one four
        t = replaceMatches(in: t, pattern: "(?<![\\w.,:/$-])([0-9]+)\\.([0-9]+)(?![\\w.,:/%-])") { groups in
            guard let intPart = Int(groups[1]), intPart < 1_000_000_000 else { return nil }
            let digits = groups[2].compactMap { $0.wholeNumberValue }.map { spell($0) }
            return spell(intPart) + " point " + digits.joined(separator: " ")
        }

        // Ordinals: 3rd → third
        t = replaceMatches(in: t, pattern: "(?<![\\w.,:/$-])([0-9]+)(st|nd|rd|th)(?![\\w-])") { groups in
            guard let n = Int(groups[1]), n <= 1000 else { return nil }
            let f = NumberFormatter()
            f.numberStyle = .ordinal
            f.locale = Locale(identifier: "en_US")
            _ = f
            return spellOutOrdinal(n)
        }

        // Plain integers not adjacent to date/time/code punctuation
        t = replaceMatches(in: t, pattern: "(?<![\\w.,:/$\u{20B9}%-])([0-9]+)(?![\\w.,:/%-])") { groups in
            guard let n = Int(groups[1]), n < 1_000_000_000 else { return nil }
            return spell(n)
        }
        return t
    }

    /// Auto mode pass 2: single digits 0–9 → words, when not attached to units or symbols.
    static func smallNumeralsToWords(_ text: String) -> String {
        replaceMatches(in: text, pattern: "(?<![\\w.,:/$\u{20B9}%-])([0-9])(?![\\w.,:/%-])") { groups in
            guard let n = Int(groups[1]) else { return nil }
            return spell(n)
        }
    }

    private static func spellOutOrdinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_US")
        // NumberFormatter has no ordinal-words style; build from cardinal.
        let cardinal = f.string(from: NSNumber(value: n)) ?? String(n)
        let irregular: [String: String] = [
            "one": "first", "two": "second", "three": "third", "five": "fifth",
            "eight": "eighth", "nine": "ninth", "twelve": "twelfth",
        ]
        for (word, ord) in irregular where cardinal.hasSuffix(word) {
            return String(cardinal.dropLast(word.count)) + ord
        }
        if cardinal.hasSuffix("y") {
            return String(cardinal.dropLast()) + "ieth"
        }
        return cardinal + "th"
    }

    // MARK: - Regex helper

    static func replaceMatches(
        in text: String, pattern: String,
        transform: ([String]) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            if let replacement = transform(groups) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                result += replacement
                last = match.range.location + match.range.length
            }
        }
        result += ns.substring(from: last)
        return result
    }
}
