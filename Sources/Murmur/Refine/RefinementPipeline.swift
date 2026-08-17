import Foundation

/// Turns a raw recognizer result into the text that gets typed.
///
/// Order matters. Vocabulary correction runs first, while the words still line
/// up with the per-word confidences the engine reported; the deterministic
/// formatter runs second, over text whose proper nouns are already right.
struct RefinementPipeline {
    var formatterOptions: FormatterOptions
    var vocabulary: [VocabularyEntry]

    func refine(_ result: TranscriptionResult) -> String {
        var text = result.text

        if !vocabulary.isEmpty {
            let matcher = VocabularyMatcher(entries: vocabulary)
            text = matcher.correct(text, words: result.words)
        }

        return TranscriptFormatter(options: formatterOptions).format(text)
    }

    /// Text-only entry point for tests and the command-line paths.
    func refine(text: String) -> String {
        refine(TranscriptionResult(text: text, engineID: "test", modelName: "test"))
    }

    static func current() -> RefinementPipeline {
        RefinementPipeline(
            formatterOptions: Prefs.formatterOptions,
            vocabulary: Prefs.vocabulary)
    }
}
