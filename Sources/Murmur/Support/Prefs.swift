import Foundation
import SwiftUI

enum NumberMode: String, CaseIterable, Identifiable {
    case numerals, words, auto, off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .numerals: return "Numerals"
        case .words: return "Words"
        case .auto: return "Auto (style guide)"
        case .off: return "Leave as spoken"
        }
    }

    var example: String {
        switch self {
        case .numerals: return "\u{201C}forty two copies\u{201D} \u{2192} \u{201C}42 copies\u{201D}"
        case .words: return "\u{201C}42 copies\u{201D} \u{2192} \u{201C}forty-two copies\u{201D}"
        case .auto: return "words for zero\u{2013}nine, numerals for 10 and up"
        case .off: return "whatever the recognizer produced"
        }
    }
}

/// How aggressively the on-device model is allowed to rewrite a transcript.
enum PolishMode: String, CaseIterable, Identifiable {
    case off
    case cleanup
    case rewrite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off — instant"
        case .cleanup: return "Clean up speech"
        case .rewrite: return "Clean up and tidy grammar"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Deterministic formatting only. No added delay."
        case .cleanup:
            return "Removes false starts and resolves spoken corrections "
                + "(\u{201C}Friday, no wait, Monday\u{201D}). Adds about a second."
        case .rewrite:
            return "Also fixes grammar and tightens phrasing, staying close to your words. "
                + "Adds about a second."
        }
    }
}

enum PrefKey {
    static let numberMode = "numberMode"
    static let removeFillers = "removeFillers"
    static let spokenLineCommands = "spokenLineCommands"
    static let spokenPunctuation = "spokenPunctuation"
    static let smartCapitalization = "smartCapitalization"
    static let appendTrailingSpace = "appendTrailingSpace"
    static let selfCorrections = "selfCorrections"
    static let triggerKey = "triggerKey"
    static let holdKey = "holdKey"  // legacy v1 enum, migrated to triggerKey
    static let soundFeedback = "soundFeedback"
    static let showOverlay = "showOverlay"
    static let selectedModel = "selectedModel"
    static let vocabulary = "vocabularyEntries"
    static let customReplacements = "customReplacements"  // legacy, migrated
    static let polishMode = "polishMode"
    static let launchAtLogin = "launchAtLogin"
    static let keepHistory = "keepHistory"
    static let language = "language"
}

/// Typed wrapper over UserDefaults, shared by the dictation pipeline and the
/// SwiftUI settings screens (which bind to the same keys via @AppStorage).
enum Prefs {
    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            PrefKey.numberMode: NumberMode.numerals.rawValue,
            PrefKey.removeFillers: true,
            PrefKey.spokenLineCommands: true,
            PrefKey.spokenPunctuation: false,
            PrefKey.smartCapitalization: true,
            PrefKey.appendTrailingSpace: true,
            PrefKey.selfCorrections: true,
            PrefKey.soundFeedback: true,
            PrefKey.showOverlay: true,
            PrefKey.selectedModel: "auto",
            PrefKey.polishMode: PolishMode.off.rawValue,
            PrefKey.launchAtLogin: false,
            PrefKey.keepHistory: true,
            PrefKey.language: "en",
        ])
        migrateLegacyReplacements()
        seedVocabularyIfEmpty()
    }

    static var numberMode: NumberMode {
        NumberMode(rawValue: defaults.string(forKey: PrefKey.numberMode) ?? "") ?? .numerals
    }

    static var polishMode: PolishMode {
        PolishMode(rawValue: defaults.string(forKey: PrefKey.polishMode) ?? "") ?? .off
    }

    /// Spoken language, or "auto". Defaults to English rather than auto:
    /// the multilingual recognizer will otherwise sometimes decide a short
    /// English utterance was Russian and transliterate it into Cyrillic.
    static var language: String {
        get { defaults.string(forKey: PrefKey.language) ?? "en" }
        set { defaults.set(newValue, forKey: PrefKey.language) }
    }

    static var selectedModel: String {
        get { defaults.string(forKey: PrefKey.selectedModel) ?? "auto" }
        set { defaults.set(newValue, forKey: PrefKey.selectedModel) }
    }

    static var triggerKey: KeySpec {
        get {
            if let data = defaults.data(forKey: PrefKey.triggerKey),
               let spec = try? JSONDecoder().decode(KeySpec.self, from: data) {
                return spec
            }
            switch defaults.string(forKey: PrefKey.holdKey) {
            case "rightCommand": return KeySpec(keyCode: 54, isModifier: true, display: "Right \u{2318}")
            case "fn": return KeySpec(keyCode: 63, isModifier: true, display: "Fn / Globe")
            case "rightControl": return KeySpec(keyCode: 62, isModifier: true, display: "Right \u{2303}")
            default: return .defaultKey
            }
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: PrefKey.triggerKey) }
    }

    static var vocabulary: [VocabularyEntry] {
        get {
            guard let data = defaults.data(forKey: PrefKey.vocabulary) else { return [] }
            return (try? JSONDecoder().decode([VocabularyEntry].self, from: data)) ?? []
        }
        set {
            defaults.set((try? JSONEncoder().encode(newValue)) ?? Data(), forKey: PrefKey.vocabulary)
        }
    }

    /// v1 stored plain find/replace pairs. Carry them over as vocabulary
    /// entries with an explicit alias so nobody loses their corrections.
    private static func migrateLegacyReplacements() {
        guard defaults.data(forKey: PrefKey.vocabulary) == nil,
              let data = defaults.data(forKey: PrefKey.customReplacements) else { return }

        struct LegacyReplacement: Codable { var find: String; var replace: String }
        guard let legacy = try? JSONDecoder().decode([LegacyReplacement].self, from: data),
              !legacy.isEmpty else { return }

        vocabulary = legacy.map {
            VocabularyEntry(term: $0.replace, aliases: [$0.find])
        }
        Log.log("migrated \(legacy.count) v1 replacements into the vocabulary")
    }

    /// Seeds one entry on first run so the vocabulary feature is discoverable
    /// and the app's own name comes out capitalized when people talk about it.
    private static func seedVocabularyIfEmpty() {
        guard defaults.data(forKey: PrefKey.vocabulary) == nil else { return }
        vocabulary = [VocabularyEntry(term: "Murmur")]
    }

    static var formatterOptions: FormatterOptions {
        FormatterOptions(
            numberMode: numberMode,
            removeFillers: defaults.bool(forKey: PrefKey.removeFillers),
            spokenLineCommands: defaults.bool(forKey: PrefKey.spokenLineCommands),
            spokenPunctuation: defaults.bool(forKey: PrefKey.spokenPunctuation),
            smartCapitalization: defaults.bool(forKey: PrefKey.smartCapitalization),
            appendTrailingSpace: defaults.bool(forKey: PrefKey.appendTrailingSpace),
            resolveSelfCorrections: defaults.bool(forKey: PrefKey.selfCorrections))
    }
}
