import Foundation

/// Catches the multilingual recognizer writing your words in the wrong script.
///
/// Parakeet v3 detects language internally and exposes no way to constrain it —
/// there is no language parameter, and no logits hook to bias one. On a short
/// utterance its language ID is unreliable, and when it guesses wrong it does
/// not fail: it transliterates. "Whoa, it works" comes back as "Воу, ит вокс",
/// which is phonetically faithful and completely useless.
///
/// Since the misdetection cannot be prevented at the decoder, it is detected
/// afterwards by comparing the script of the output against the script the
/// user's language is written in.
enum ScriptGuard {

    /// Scripts we can tell apart well enough to act on.
    enum Script {
        case latin
        case cyrillic
        case greek
        case han
        case other
    }

    static func script(of character: Character) -> Script? {
        guard let scalar = character.unicodeScalars.first,
              character.isLetter else { return nil }
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A,     // basic Latin
             0x00C0...0x024F,                       // Latin-1 supplement + extended
             0x1E00...0x1EFF:                       // Latin extended additional
            return .latin
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0400...0x04FF, 0x0500...0x052F:
            return .cyrillic
        case 0x4E00...0x9FFF, 0x3040...0x30FF:
            return .han
        default:
            return .other
        }
    }

    /// The script a language is normally written in. `nil` means we have no
    /// opinion and should not second-guess the recognizer.
    static func expectedScript(for language: String?) -> Script? {
        guard let language, language != "auto" else { return nil }
        switch language {
        case "ru", "uk", "bg", "sr", "be", "mk":
            return .cyrillic
        case "el":
            return .greek
        case "zh", "ja":
            return .han
        default:
            // Every other language Parakeet and Whisper support that we would
            // pin is Latin-script.
            return .latin
        }
    }

    /// True when enough of the transcript is in the wrong script that this is a
    /// misdetection rather than a stray loanword or emoji.
    ///
    /// A quoted Russian phrase inside English dictation is legitimate, so a few
    /// foreign characters are tolerated; a majority is not.
    static func isWrongScript(_ text: String, expected: Script?) -> Bool {
        guard let expected else { return false }

        var matching = 0
        var mismatching = 0
        for character in text {
            guard let s = script(of: character) else { continue }
            if s == expected { matching += 1 } else { mismatching += 1 }
        }
        let total = matching + mismatching
        guard total > 0 else { return false }

        // Text written entirely in another script is a misdetection at any
        // length. This case is the whole reason the guard exists: "free" came
        // back as "Фли", and an earlier version refused to judge anything under
        // six letters — silently standing down on exactly the short utterances
        // where the recognizer's language ID is least reliable.
        if matching == 0 { return true }

        // With some of the expected script present, require a clear majority
        // before overriding, so a quoted foreign word survives.
        guard total >= 6 else { return false }
        return Double(mismatching) / Double(total) > 0.5
    }
}
