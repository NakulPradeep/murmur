import Foundation

/// Audio handed to an engine: always 16 kHz mono float, the format every
/// supported backend expects.
struct TranscriptionRequest {
    var samples: [Float]

    /// Words the user cares about (names, jargon, brands). Engines that support
    /// prompt biasing inject these; the rest ignore them and rely on the
    /// post-hoc vocabulary matcher instead.
    var vocabulary: [String] = []

    /// The tail of the previous dictation, used as decoder context so a
    /// sentence continued across two key presses stays coherent.
    var priorContext: String?

    /// BCP-47-ish language hint. `nil` means "let the model decide".
    var language: String?

    /// Called periodically; return true to abort the decode. Lets Esc cancel a
    /// transcription that is already running.
    var isCancelled: (() -> Bool)?

    var seconds: Double { Double(samples.count) / Double(Constants.sampleRate) }
}

/// One recognized word with the metadata the refinement stage needs.
struct TranscriptWord {
    var text: String
    /// 0–1. Low values mark spans worth re-checking against the user vocabulary.
    var confidence: Float
    var start: TimeInterval
    var end: TimeInterval
}

struct TranscriptionResult {
    var text: String
    var words: [TranscriptWord] = []
    var engineID: String
    var modelName: String
    /// Wall-clock time the decode took.
    var processingTime: TimeInterval = 0
    var detectedLanguage: String?

    /// Mean per-word confidence, or 1 when the engine reports none.
    var meanConfidence: Float {
        guard !words.isEmpty else { return 1 }
        return words.reduce(0) { $0 + $1.confidence } / Float(words.count)
    }

    /// Words the engine was least sure about, worst first.
    func lowConfidenceWords(below threshold: Float) -> [TranscriptWord] {
        words.filter { $0.confidence < threshold }.sorted { $0.confidence < $1.confidence }
    }
}

enum TranscriptionError: LocalizedError {
    case noModelLoaded
    case modelLoadFailed(String)
    case decodeFailed(Int32)
    case cancelled
    case audioTooShort

    var errorDescription: String? {
        switch self {
        case .noModelLoaded: return "No speech model is loaded."
        case .modelLoadFailed(let path): return "Could not load the model at \(path)."
        case .decodeFailed(let code): return "The recognizer failed (code \(code))."
        case .cancelled: return "Transcription was cancelled."
        case .audioTooShort: return "That recording was too short to transcribe."
        }
    }
}

/// A local speech recognizer. Implementations own a native context and must be
/// safe to call `transcribe` on from one background queue at a time; the router
/// guarantees that serialization.
protocol TranscriptionEngine: AnyObject {
    /// Stable identifier used in preferences and logs.
    static var id: String { get }

    var displayName: String { get }
    var isReady: Bool { get }
    /// File name of the loaded model, for display.
    var loadedModelName: String? { get }

    /// Whether this engine can bias decoding toward a supplied vocabulary.
    var supportsVocabularyBiasing: Bool { get }
    /// Whether results carry per-word timings and confidences.
    var supportsWordTimings: Bool { get }

    func load(modelPath: String) throws
    /// Frees the native context. Safe to call when nothing is loaded.
    func unload()

    func transcribe(_ request: TranscriptionRequest) throws -> TranscriptionResult
}

extension TranscriptionEngine {
    var id: String { Self.id }
}

enum Constants {
    static let sampleRate = 16_000
    /// Whisper pads everything shorter than this to a full 30 s window anyway.
    static let minimumSeconds: Double = 0.25
}
