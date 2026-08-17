import Foundation

/// A word or phrase the user cares about getting right.
struct VocabularyEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// How it should be written.
    var term: String
    /// Optional explicit misrecognitions to always fix, beyond fuzzy matching.
    var aliases: [String] = []
    /// When false the term is still sent to the recognizer as a hint but never
    /// substituted after the fact.
    var autoCorrect: Bool = true

    var words: [String] {
        term.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
    }
}

/// Rewrites near-misses of the user's vocabulary back to the intended spelling.
///
/// Runs over word spans rather than the raw string so that a two-word term can
/// replace a differently-split pair ("clawed code" → "Claude Code"), which a
/// find-and-replace over text cannot do.
struct VocabularyMatcher {
    var entries: [VocabularyEntry]

    /// Minimum similarity to accept a substitution. Tuned so obvious
    /// misrecognitions are fixed and unrelated words are left alone.
    var threshold: Double = 0.82
    /// Words the recognizer was confident about need a higher bar, since a
    /// confident correct word is more likely right than the vocabulary guess.
    var confidentThreshold: Double = 0.93
    var confidenceCutoff: Float = 0.75

    private struct Candidate {
        let entry: VocabularyEntry
        let spanLength: Int
        /// Lowercased, punctuation-free form used for comparison.
        let normalized: String
    }

    /// Applies corrections to `text`. `words` supplies per-word confidence when
    /// the engine reported it; pass an empty array to treat every word as
    /// uncertain.
    func correct(_ text: String, words: [TranscriptWord] = []) -> String {
        let active = entries.filter { $0.autoCorrect && !$0.term.isEmpty }
        guard !active.isEmpty else { return text }

        var candidates: [Candidate] = []
        for entry in active {
            let terms = [entry.term] + entry.aliases
            for variant in terms where !variant.isEmpty {
                let parts = variant.split(whereSeparator: { $0 == " " || $0 == "-" })
                candidates.append(Candidate(
                    entry: entry,
                    spanLength: max(1, parts.count),
                    normalized: normalize(variant)))
            }
        }
        // A term can arrive split across more words than it was written with
        // ("swift u i" for "SwiftUI"), so allow spans wider than the longest
        // term rather than deriving the limit from the vocabulary alone.
        let maxSpan = min(5, (candidates.map(\.spanLength).max() ?? 1) + 2)

        var tokens = Tokenizer.split(text)
        let confidence = confidenceLookup(words)

        // Score every span at every start, then apply the strongest matches
        // first, skipping any that overlap one already taken. Scanning
        // left-to-right and committing greedily lets an early weak span swallow
        // a neighbour that would itself have matched better — "to kubernetes"
        // scores 0.85 against "Kubernetes", but "kubernetes" alone scores 1.0,
        // and only a global ranking prefers the right one.
        var matches: [(range: Range<Int>, entry: VocabularyEntry, score: Double)] = []

        for i in tokens.indices where tokens[i].isWord {
            for span in 1...max(1, min(maxSpan, tokens.count - i)) {
                guard let range = wordSpan(tokens, from: i, wordCount: span) else { continue }
                let normalizedPhrase = normalize(tokens[range].map(\.text).joined())
                if normalizedPhrase.isEmpty { continue }

                // The bar rises when the recognizer was sure of these words: a
                // confident transcription is likelier right than our guess.
                let spanConfidence = tokens[range]
                    .filter(\.isWord)
                    .compactMap { confidence[normalize($0.text)] }
                    .min() ?? 0
                let bar = spanConfidence >= confidenceCutoff ? confidentThreshold : threshold

                for candidate in candidates {
                    let score = Phonetics.similarity(normalizedPhrase, candidate.normalized)
                    if score >= bar {
                        matches.append((range, candidate.entry, score))
                    }
                }
            }
        }

        // Strongest first; ties go to the longer span, which is the fully
        // reassembled term rather than a prefix of it.
        matches.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.range.count > $1.range.count
        }

        var claimed = Set<Int>()
        var applied: [(range: Range<Int>, text: String)] = []
        for match in matches {
            guard !match.range.contains(where: { claimed.contains($0) }) else { continue }
            let original = tokens[match.range].map(\.text).joined()
            // A span that already matches apart from capitalization is still
            // rewritten, so "anthropic" picks up its proper casing.
            guard original != match.entry.term else {
                match.range.forEach { claimed.insert($0) }
                continue
            }
            let replacement = preserveTrailingPunctuation(
                of: original, replacingWith: match.entry.term)
            match.range.forEach { claimed.insert($0) }
            applied.append((match.range, replacement))
            Log.log("vocabulary: \(original) -> \(replacement) "
                + "(\(String(format: "%.2f", match.score)))")
        }

        // Right to left so earlier ranges stay valid as the array shrinks.
        for change in applied.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            tokens.replaceSubrange(
                change.range, with: [Tokenizer.Token(text: change.text, isWord: true)])
        }
        return tokens.map(\.text).joined()
    }

    /// Terms to feed the recognizer as a decoding hint.
    var biasTerms: [String] {
        entries.map(\.term).filter { !$0.isEmpty }
    }

    // MARK: - Helpers

    private func confidenceLookup(_ words: [TranscriptWord]) -> [String: Float] {
        var map: [String: Float] = [:]
        for word in words {
            let key = normalize(word.text)
            guard !key.isEmpty else { continue }
            // Keep the lowest confidence seen for a repeated word.
            map[key] = min(map[key] ?? 1, word.confidence)
        }
        return map
    }

    private func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Range covering `wordCount` words starting at `start`, including the
    /// separators between them but not any trailing separator.
    private func wordSpan(
        _ tokens: [Tokenizer.Token], from start: Int, wordCount: Int
    ) -> Range<Int>? {
        var seen = 0
        var end = start
        var lastWordIndex = start
        while end < tokens.count {
            if tokens[end].isWord {
                seen += 1
                lastWordIndex = end
                if seen == wordCount { return start..<(lastWordIndex + 1) }
            } else {
                // Only a plain space may sit inside a matched phrase; a comma
                // or period means the phrase ended.
                if seen > 0, !tokens[end].text.allSatisfy({ $0 == " " }) { return nil }
            }
            end += 1
        }
        return nil
    }

    /// Carries punctuation that trailed the original text onto the replacement.
    private func preserveTrailingPunctuation(
        of original: String, replacingWith replacement: String
    ) -> String {
        let trailing = original.reversed().prefix { !$0.isLetter && !$0.isNumber }
        return replacement + String(trailing.reversed())
    }
}

/// Splits text into word and separator runs, preserving everything so a join
/// round-trips exactly.
enum Tokenizer {
    struct Token: Equatable {
        var text: String
        var isWord: Bool
    }

    static func split(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false

        for ch in text {
            let isWordChar = ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}"
            if current.isEmpty {
                current.append(ch)
                currentIsWord = isWordChar
            } else if isWordChar == currentIsWord {
                current.append(ch)
            } else {
                tokens.append(Token(text: current, isWord: currentIsWord))
                current = String(ch)
                currentIsWord = isWordChar
            }
        }
        if !current.isEmpty { tokens.append(Token(text: current, isWord: currentIsWord)) }
        return tokens
    }
}
