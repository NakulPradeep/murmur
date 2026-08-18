import Foundation

/// Languages offered in Settings. Deliberately short: these are the ones both
/// engines handle well, plus "auto" for people who genuinely switch languages
/// mid-sentence and accept the misdetection risk that comes with it.
struct SpokenLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [SpokenLanguage] = [
        SpokenLanguage(code: "en", name: "English"),
        SpokenLanguage(code: "es", name: "Spanish"),
        SpokenLanguage(code: "fr", name: "French"),
        SpokenLanguage(code: "de", name: "German"),
        SpokenLanguage(code: "it", name: "Italian"),
        SpokenLanguage(code: "pt", name: "Portuguese"),
        SpokenLanguage(code: "nl", name: "Dutch"),
        SpokenLanguage(code: "pl", name: "Polish"),
        SpokenLanguage(code: "ru", name: "Russian"),
        SpokenLanguage(code: "uk", name: "Ukrainian"),
        SpokenLanguage(code: "el", name: "Greek"),
        SpokenLanguage(code: "hi", name: "Hindi"),
        SpokenLanguage(code: "auto", name: "Detect automatically"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }
}
