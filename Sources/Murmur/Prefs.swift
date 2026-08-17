import Foundation
import SwiftUI

enum NumberMode: String, CaseIterable, Identifiable {
    case numerals
    case words
    case auto
    case off

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
        case .numerals: return "\u{201C}I need forty two copies\u{201D} \u{2192} \u{201C}I need 42 copies\u{201D}"
        case .words: return "\u{201C}I need 42 copies\u{201D} \u{2192} \u{201C}I need forty-two copies\u{201D}"
        case .auto: return "words for zero\u{2013}nine, numerals for 10 and up"
        case .off: return "whatever the transcriber produced"
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
    static let holdKey = "holdKey"  // legacy (v1 enum), migrated to triggerKey
    static let triggerKey = "triggerKey"
    static let soundFeedback = "soundFeedback"
    static let selectedModel = "selectedModel"
    static let customReplacements = "customReplacements"
}

struct CustomReplacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var find: String
    var replace: String
}

/// Thin typed wrapper over UserDefaults so the dictation pipeline and the
/// SwiftUI settings screens (via @AppStorage on the same keys) stay in sync.
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
            PrefKey.soundFeedback: true,
            PrefKey.selectedModel: "auto",
        ])
    }

    static var numberMode: NumberMode {
        NumberMode(rawValue: defaults.string(forKey: PrefKey.numberMode) ?? "") ?? .numerals
    }

    static var triggerKey: KeySpec {
        get {
            if let data = defaults.data(forKey: PrefKey.triggerKey),
               let spec = try? JSONDecoder().decode(KeySpec.self, from: data) {
                return spec
            }
            // Migrate the v1 enum preference, if present.
            switch defaults.string(forKey: PrefKey.holdKey) {
            case "rightCommand": return KeySpec(keyCode: 54, isModifier: true, display: "Right \u{2318}")
            case "fn": return KeySpec(keyCode: 63, isModifier: true, display: "Fn / Globe")
            case "rightControl": return KeySpec(keyCode: 62, isModifier: true, display: "Right \u{2303}")
            default: return .defaultKey
            }
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: PrefKey.triggerKey)
        }
    }

    static var customReplacements: [CustomReplacement] {
        get {
            guard let data = defaults.data(forKey: PrefKey.customReplacements) else { return [] }
            return (try? JSONDecoder().decode([CustomReplacement].self, from: data)) ?? []
        }
        set {
            defaults.set((try? JSONEncoder().encode(newValue)) ?? Data(), forKey: PrefKey.customReplacements)
        }
    }

    static var formatterOptions: FormatterOptions {
        FormatterOptions(
            numberMode: numberMode,
            removeFillers: defaults.bool(forKey: PrefKey.removeFillers),
            spokenLineCommands: defaults.bool(forKey: PrefKey.spokenLineCommands),
            spokenPunctuation: defaults.bool(forKey: PrefKey.spokenPunctuation),
            smartCapitalization: defaults.bool(forKey: PrefKey.smartCapitalization),
            appendTrailingSpace: defaults.bool(forKey: PrefKey.appendTrailingSpace),
            customReplacements: customReplacements
        )
    }
}
