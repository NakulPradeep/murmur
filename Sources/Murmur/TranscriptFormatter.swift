import Foundation

struct FormatterOptions {
    var numberMode: NumberMode = .numerals
    var removeFillers = true
    var spokenLineCommands = true
    var spokenPunctuation = false
    var smartCapitalization = true
    var appendTrailingSpace = true
    var customReplacements: [CustomReplacement] = []
}

/// Deterministic post-processing over the raw Whisper transcript.
/// Every step is local, instant, and controlled by a user preference.
struct TranscriptFormatter {
    let options: FormatterOptions

    func format(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripArtifacts(text)
        if options.removeFillers { text = removeFillers(text) }
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

        for r in options.customReplacements where !r.find.isEmpty {
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: r.find) + "\\b"
            text = text.replacingOccurrences(
                of: pattern, with: r.replace, options: .regularExpression)
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
