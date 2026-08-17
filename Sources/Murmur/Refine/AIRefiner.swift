import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional transcript polish using Apple's on-device model.
///
/// Everything stays on the Mac, but it costs roughly a second, so it is off by
/// default and never blocks the deterministic path: callers insert the fast
/// result first and only use this when the user opted in.
///
/// Two findings shaped this implementation:
///   * Plain string prompting fails outright — the model returns
///     "Session ended without producing a response". Guided generation against
///     a `@Generable` type is what actually works.
///   * The model is unreliable at resolving spoken self-corrections, so that
///     job stays with the deterministic formatter and the instructions here
///     explicitly leave it alone.
enum AIRefiner {

    enum Availability: Equatable {
        case ready
        case unsupportedOS
        case appleIntelligenceOff
        case deviceNotEligible
        case modelDownloading
        case unknown(String)

        var isReady: Bool { self == .ready }

        var explanation: String {
            switch self {
            case .ready:
                return "On-device model ready."
            case .unsupportedOS:
                return "Needs macOS 26 or later."
            case .appleIntelligenceOff:
                return "Turn on Apple Intelligence in System Settings to use this."
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence."
            case .modelDownloading:
                return "The system model is still downloading."
            case .unknown(let detail):
                return detail
            }
        }
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .deviceNotEligible: return .deviceNotEligible
            case .modelNotReady: return .modelDownloading
            @unknown default: return .unknown("The on-device model is unavailable.")
            }
        @unknown default:
            return .unknown("The on-device model is unavailable.")
        }
        #else
        return .unsupportedOS
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static let session: LanguageModelSession = {
        let s = LanguageModelSession(instructions: instructions)
        // Warm the model so the first real dictation does not pay load cost.
        s.prewarm()
        return s
    }()

    private static let instructions = """
        You clean up dictated speech. The user gives you a raw speech-to-text \
        transcript and you return the same message written properly.

        Rules:
        - Keep the speaker's own words, meaning, and tone. Do not summarise, \
        translate, answer, or add anything.
        - Remove filler words, false starts, and repeated words.
        - Fix punctuation, capitalisation, and obvious transcription slips.
        - Leave names, technical terms, numbers, and formatting exactly as given.
        - If the text is already clean, return it unchanged.
        """

    // Not `private`: the @Generable macro expands into code that references
    // this type from a broader scope than the declaration.
    @available(macOS 26, *)
    @Generable
    struct Polished {
        @Guide(description: "The cleaned-up dictation, containing only the speaker's words.")
        var text: String
    }
    #endif

    /// Prewarms the model so the first use is not slow. Safe to call always.
    static func prewarm() {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), availability.isReady else { return }
        _ = session
        #endif
    }

    /// Polishes `text`, or returns nil if the model is unavailable, refuses, or
    /// produces something that looks like a rewrite rather than a cleanup. The
    /// caller always keeps the deterministic text on nil.
    static func polish(_ text: String, mode: PolishMode) async -> String? {
        guard mode != .off else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return nil }

        #if canImport(FoundationModels)
        guard #available(macOS 26, *), availability.isReady else { return nil }

        let prompt = mode == .rewrite
            ? "Clean up and lightly tidy the grammar of this dictation:\n\(trimmed)"
            : "Clean up this dictation:\n\(trimmed)"

        do {
            let response = try await session.respond(
                to: prompt,
                generating: Polished.self,
                options: GenerationOptions(temperature: 0.0))
            let candidate = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPlausible(candidate, original: trimmed) else {
                Log.log("ai polish rejected: output diverged from the transcript")
                return nil
            }
            return candidate
        } catch {
            // Guardrails can decline ordinary text, and a refusal must never
            // cost the user their words.
            Log.log("ai polish unavailable: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Guards against the model answering the dictation instead of cleaning it.
    /// Cleanup only ever shortens slightly or leaves length alone; a large
    /// swing in either direction means it did something else.
    private static func isPlausible(_ candidate: String, original: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        let ratio = Double(candidate.count) / Double(max(1, original.count))
        guard ratio > 0.5, ratio < 1.6 else { return false }

        // Require meaningful word overlap with the original.
        let originalWords = Set(
            original.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let candidateWords = Set(
            candidate.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !originalWords.isEmpty else { return false }
        let overlap = Double(originalWords.intersection(candidateWords).count)
            / Double(originalWords.count)
        return overlap >= 0.5
    }
}
