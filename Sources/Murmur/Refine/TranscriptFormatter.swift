import Foundation

struct FormatterOptions {
    var numberMode: NumberMode = .numerals
    var removeFillers = true
    var spokenLineCommands = true
    var spokenPunctuation = false
    var smartCapitalization = true
    var appendTrailingSpace = true
    var resolveSelfCorrections = true
}

/// Deterministic post-processing over the raw Whisper transcript.
/// Every step is local, instant, and controlled by a user preference.
struct TranscriptFormatter {
    let options: FormatterOptions

    func format(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripArtifacts(text)
        if options.removeFillers { text = removeFillers(text) }
        if options.resolveSelfCorrections {
            text = resolveSelfCorrections(text)
            text = collapseStutters(text)
        }
        if options.spokenPunctuation { text = applySpokenPunctuation(text) }
        if options.spokenLineCommands { text = applyLineCommands(text) }

        switch options.numberMode {
        case .numerals:
            text = NumberEngine.wordsToNumerals(text)
            text = NumberEngine.normalizeUnits(text)
        case .words:
            text = NumberEngine.numeralsToWords(text)
        case .auto:
            text = NumberEngine.wordsToNumerals(text)
            text = NumberEngine.normalizeUnits(text)
            text = NumberEngine.smallNumeralsToWords(text)
        case .off:
            break
        }

        text = cleanupWhitespace(text)
        if options.smartCapitalization { text = capitalizeSentences(text) }
        text = text.trimmingCharacters(in: .whitespaces)
        if options.appendTrailingSpace, !text.isEmpty, !text.hasSuffix("\n") {
            text += " "
        }
        return text
    }

    // MARK: - Steps

    /// Whisper emits noise annotations like [BLANK_AUDIO], (coughs), *sighs*.
    private func stripArtifacts(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(
            of: "\\[[^\\]]{0,40}\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(
            of: "\\*[^*]{0,40}\\*", with: "", options: .regularExpression)
        let noises = "laughs?|laughing|coughs?|coughing|sighs?|sighing|music|applause|"
            + "silence|inaudible|clears throat|breathing|sniffs?|beep(?:ing)?|clicking"
        t = t.replacingOccurrences(
            of: "\\((?:\(noises))\\)", with: "",
            options: [.regularExpression, .caseInsensitive])
        return t
    }

    private func removeFillers(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?i)(?:^|(?<=[\\s.,!?]))(?:um+|uh+|erm+|hmm+|mhm+|mm-hmm)\\b[,.]?\\s*",
            with: "", options: .regularExpression)
    }

    /// Marker phrases that retract what the speaker just said.
    private static let correctionMarkers: [[String]] = [
        ["no", "wait"], ["no", "sorry"], ["sorry", "i", "meant"], ["i", "meant"],
        ["scratch", "that"], ["actually", "i", "meant"], ["i", "mean"],
        ["make", "that"], ["rather", "i", "mean"],
    ]

    /// Spoken retractions: "ship it Friday, no wait, Monday" should keep only
    /// the correction.
    ///
    /// The tricky part is deciding how much to delete. Deleting back to the
    /// clause boundary eats the whole sentence ("Monday"), and deleting a fixed
    /// number of words breaks on longer phrases. What works is the symmetry of
    /// how people actually correct themselves: the replacement mirrors what it
    /// replaces, so "Monday" retracts one word and "the red one" retracts
    /// three. The count is capped, and never crosses a sentence boundary, so a
    /// misfire costs a few words rather than a paragraph.
    private func resolveSelfCorrections(_ text: String) -> String {
        var tokens = Tokenizer.split(text)
        let maxRetraction = 3

        // Indices of word tokens, for walking words while ignoring separators.
        func wordIndices(in tokens: [Tokenizer.Token]) -> [Int] {
            tokens.indices.filter { tokens[$0].isWord }
        }
        func isSentenceBreak(_ token: Tokenizer.Token) -> Bool {
            !token.isWord && token.text.contains(where: { ".!?\n".contains($0) })
        }
        func isClauseBreak(_ token: Tokenizer.Token) -> Bool {
            !token.isWord && token.text.contains(where: { ".!?,;\n".contains($0) })
        }

        var changed = true
        while changed {
            changed = false
            let words = wordIndices(in: tokens)

            for (position, tokenIndex) in words.enumerated() {
                guard let marker = Self.correctionMarkers.first(where: { marker in
                    guard position + marker.count <= words.count else { return false }
                    return zip(marker, words[position..<(position + marker.count)]).allSatisfy {
                        expected, index in
                        tokens[index].text.lowercased() == expected
                    }
                }) else { continue }

                let markerEnd = position + marker.count - 1

                // How many words follow the marker before the next clause
                // break — that is the size of the replacement.
                var following = 0
                var cursor = markerEnd + 1
                while cursor < words.count, following < maxRetraction {
                    let between = (words[cursor - 1] + 1)..<words[cursor]
                    if cursor > markerEnd + 1,
                       tokens[between].contains(where: isClauseBreak) { break }
                    following += 1
                    cursor += 1
                }
                // Nothing after the marker means nothing was corrected.
                guard following > 0 else { continue }

                // Retract the same number of words before the marker, stopping
                // at a sentence boundary.
                var retractFrom = position
                var retracted = 0
                while retracted < following, retractFrom > 0 {
                    let previous = retractFrom - 1
                    let between = (words[previous] + 1)..<words[retractFrom]
                    if tokens[between].contains(where: isSentenceBreak) { break }
                    retractFrom = previous
                    retracted += 1
                }
                guard retracted > 0 else { continue }

                // Remove the retracted words, the marker, and the separators
                // between them, leaving the correction in place.
                let start = words[retractFrom]
                let end = words[markerEnd]
                var removeEnd = end + 1
                while removeEnd < tokens.count, !tokens[removeEnd].isWord,
                      !isSentenceBreak(tokens[removeEnd]) {
                    removeEnd += 1
                }
                tokens.removeSubrange(start..<removeEnd)
                changed = true
                break
            }
        }
        return tokens.map(\.text).joined()
    }

    /// Restarts and stammers: "the the report", "I I think", "we we should".
    /// Only collapses immediate repeats of the same word, which are always
    /// disfluencies in dictation — genuine doubles like "had had" are rare
    /// enough, and reading worse, that removing them is the better default.
    private func collapseStutters(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?i)\\b(\\w+)(\\s+\\1\\b)+", with: "$1",
            options: .regularExpression)
    }

    /// Explicit dictation of punctuation marks. Off by default because Whisper
    /// already punctuates; users who narrate marks can enable it.
    private func applySpokenPunctuation(_ text: String) -> String {
        var t = text
        let map: [(String, String)] = [
            ("full stop|period", "."),
            ("comma", ","),
            ("question mark", "?"),
            ("exclamation (?:mark|point)", "!"),
            ("semicolon", ";"),
            ("colon", ":"),
            ("ellipsis|dot dot dot", "\u{2026}"),
            ("open quotes?", "\u{201C}"),
            ("close quotes?", "\u{201D}"),
            ("open (?:paren|parenthesis|bracket)", "("),
            ("close (?:paren|parenthesis|bracket)", ")"),
        ]
        for (words, mark) in map {
            let leading = mark == "(" || mark == "\u{201C}"
            if leading {
                t = t.replacingOccurrences(
                    of: "(?i)\\b(?:\(words))\\b[,.]?\\s*", with: mark,
                    options: .regularExpression)
            } else {
                t = t.replacingOccurrences(
                    of: "(?i)\\s*\\b(?:\(words))\\b[,.]?", with: mark,
                    options: .regularExpression)
            }
        }
        return t
    }

    private func applyLineCommands(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(
            of: "(?i)[,.]?\\s*\\bnew paragraph\\b[,.]?\\s*", with: "\n\n",
            options: .regularExpression)
        t = t.replacingOccurrences(
            of: "(?i)[,.]?\\s*\\b(?:new ?line)\\b[,.]?\\s*", with: "\n",
            options: .regularExpression)
        return t
    }

    private func cleanupWhitespace(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " +\\n", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n +", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        t = t.replacingOccurrences(of: " +([.,!?;:])", with: "$1", options: .regularExpression)
        // Collapse stutters like ".." or ". ," left by replacements
        t = t.replacingOccurrences(of: "([.,!?;:])\\1+", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "([.!?;:]) *,", with: "$1", options: .regularExpression)
        return t
    }

    private func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
            }
            if ch == "!" || ch == "?" || ch == "\n" {
                capitalizeNext = true
            } else if ch == "." {
                // Only end the sentence if the period isn't inside a number (3.14)
                let next = text.index(after: i)
                capitalizeNext = !(next < text.endIndex && text[next].isNumber)
            } else if ch.isNumber {
                capitalizeNext = false
            }
            i = text.index(after: i)
        }
        // Standalone "i" and contractions
        result = result.replacingOccurrences(
            of: "(?<=^|[\\s\u{201C}(])i(?=[\\s.,!?;:)]|$|'(?:m|ll|ve|d|s))", with: "I",
            options: .regularExpression)
        return result
    }
}
