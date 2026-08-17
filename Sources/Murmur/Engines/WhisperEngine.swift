import Foundation
import CWhisper

/// whisper.cpp backend.
///
/// Differences from the naive setup: beam search with a temperature-fallback
/// ladder, an `initial_prompt` carrying the user's vocabulary, non-speech token
/// suppression, per-token confidences, and an abort hook so a decode can be
/// cancelled mid-flight.
final class WhisperEngine: TranscriptionEngine {
    static let id = "whisper"
    var displayName: String { "Whisper" }

    private let lock = NSLock()
    private var ctx: OpaquePointer?
    private var modelName: String?
    private var isMultilingual = false

    /// Set while a decode is running so `unload` can wait instead of freeing
    /// the context out from under whisper_full.
    private var decoding = false
    private let decodeFinished = NSCondition()

    var isReady: Bool { lock.withLock { ctx != nil } }
    var loadedModelName: String? { lock.withLock { modelName } }
    var supportsVocabularyBiasing: Bool { true }
    var supportsWordTimings: Bool { true }

    /// whisper.cpp is chatty on stderr; silence it once per process.
    private static let silenceLogs: Void = {
        let quiet: ggml_log_callback = { _, _, _ in }
        whisper_log_set(quiet, nil)
        ggml_log_set(quiet, nil)
    }()

    // MARK: - Lifecycle

    func load(modelPath: String) throws {
        _ = Self.silenceLogs
        unload()

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true

        guard let newCtx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw TranscriptionError.modelLoadFailed(modelPath)
        }
        lock.withLock {
            ctx = newCtx
            modelName = (modelPath as NSString).lastPathComponent
            isMultilingual = whisper_is_multilingual(newCtx) != 0
        }
        Log.log("whisper loaded \(modelName ?? "?") multilingual=\(isMultilingual)")
    }

    func unload() {
        // Wait for any in-flight decode; freeing the context under whisper_full
        // is a use-after-free, and ggml's Metal teardown asserts on it.
        decodeFinished.lock()
        while decoding { decodeFinished.wait() }
        decodeFinished.unlock()

        lock.withLock {
            if let old = ctx {
                whisper_free(old)
                ctx = nil
                modelName = nil
            }
        }
    }

    deinit { unload() }

    // MARK: - Transcription

    func transcribe(_ request: TranscriptionRequest) throws -> TranscriptionResult {
        guard request.seconds >= Constants.minimumSeconds else {
            throw TranscriptionError.audioTooShort
        }
        guard let ctx = lock.withLock({ self.ctx }) else {
            throw TranscriptionError.noModelLoaded
        }

        decodeFinished.lock()
        decoding = true
        decodeFinished.unlock()
        defer {
            decodeFinished.lock()
            decoding = false
            decodeFinished.broadcast()
            decodeFinished.unlock()
        }

        let started = Date()
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        configure(&params, for: request)

        // The C struct borrows these pointers for the duration of the call, so
        // they must outlive whisper_full — hence the nested withCString scopes
        // rather than a temporary.
        let promptText = initialPrompt(for: request)
        let languageCode = resolveLanguage(request.language)

        var status: Int32 = -1
        var cancelFlag = CancelBox(isCancelled: request.isCancelled)

        try withUnsafeMutablePointer(to: &cancelFlag) { cancelPtr in
            params.abort_callback = { userData in
                guard let userData else { return false }
                return userData.assumingMemoryBound(to: CancelBox.self)
                    .pointee.isCancelled?() ?? false
            }
            params.abort_callback_user_data = UnsafeMutableRawPointer(cancelPtr)

            try languageCode.withCString { langPtr in
                params.language = langPtr
                if let promptText {
                    try promptText.withCString { promptPtr in
                        params.initial_prompt = promptPtr
                        status = run(ctx: ctx, params: params, samples: request.samples)
                    }
                } else {
                    status = run(ctx: ctx, params: params, samples: request.samples)
                }
            }
        }

        if request.isCancelled?() == true { throw TranscriptionError.cancelled }
        guard status == 0 else { throw TranscriptionError.decodeFailed(status) }

        let (text, words) = collectOutput(ctx: ctx)
        let langID = whisper_full_lang_id(ctx)
        let detected = langID >= 0 ? whisper_lang_str(langID).map { String(cString: $0) } : nil

        return TranscriptionResult(
            text: text,
            words: words,
            engineID: Self.id,
            modelName: modelName ?? "?",
            processingTime: Date().timeIntervalSince(started),
            detectedLanguage: detected
        )
    }

    private func run(ctx: OpaquePointer, params: whisper_full_params, samples: [Float]) -> Int32 {
        samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
    }

    /// Boxed so the abort callback can reach the closure through a raw pointer.
    private struct CancelBox {
        var isCancelled: (() -> Bool)?
    }

    // MARK: - Parameters

    private func configure(_ params: inout whisper_full_params, for request: TranscriptionRequest) {
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false

        // Token timestamps give per-word confidence, which the vocabulary
        // matcher uses to decide what is worth second-guessing.
        params.token_timestamps = true
        params.no_timestamps = false
        params.single_segment = false

        // Beam search materially beats greedy on short utterances, and short
        // clips are cheap enough that the extra passes are invisible.
        params.beam_search.beam_size = 5
        params.greedy.best_of = 5

        // Temperature-fallback ladder: retry hotter only when the decode looks
        // degenerate. Without this, one bad window can emit a repeat loop.
        params.temperature = 0.0
        params.temperature_inc = 0.2
        params.entropy_thold = 2.4
        params.logprob_thold = -1.0
        params.no_speech_thold = 0.6

        params.suppress_blank = true
        // Suppresses "(wind blowing)"-style non-speech tokens at the decoder
        // level, which is far more reliable than stripping them with regex.
        params.suppress_nst = true

        // Physical cores only. Counting efficiency cores in slows decoding on
        // Apple silicon because the fast cores wait on the slow ones.
        params.n_threads = Int32(Self.decodeThreadCount)

        params.no_context = request.priorContext == nil
    }

    private static let decodeThreadCount: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Performance-core count; falls back to a sane split of logical cores.
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }()

    /// Whisper conditions on `initial_prompt` as if it were previously
    /// transcribed text, so proper nouns spelled here are far likelier to come
    /// back spelled correctly. Budget is n_text_ctx/2 (~224 tokens); overrunning
    /// it silently truncates and can leak prompt text into the output.
    private func initialPrompt(for request: TranscriptionRequest) -> String? {
        var pieces: [String] = []
        if let prior = request.priorContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prior.isEmpty {
            pieces.append(String(prior.suffix(200)))
        }
        if !request.vocabulary.isEmpty {
            // A plain comma list reads as a glossary and biases without
            // dragging the model toward a particular sentence shape.
            let vocab = request.vocabulary.prefix(60).joined(separator: ", ")
            pieces.append("Glossary: \(vocab).")
        }
        guard !pieces.isEmpty else { return nil }
        return String(pieces.joined(separator: " ").suffix(800))
    }

    private func resolveLanguage(_ requested: String?) -> String {
        guard isMultilingual else { return "en" }
        return requested ?? "auto"
    }

    // MARK: - Output

    private func collectOutput(ctx: OpaquePointer) -> (String, [TranscriptWord]) {
        var text = ""
        var words: [TranscriptWord] = []

        for segment in 0..<whisper_full_n_segments(ctx) {
            if let raw = whisper_full_get_segment_text(ctx, segment) {
                text += String(cString: raw)
            }
            // Whisper emits sub-word tokens; stitch them into words on the
            // leading-space boundary so confidences are per-word, not per-piece.
            var pending: TranscriptWord?
            for i in 0..<whisper_full_n_tokens(ctx, segment) {
                let data = whisper_full_get_token_data(ctx, segment, i)
                // Special tokens (timestamps, SOT) carry no text worth keeping.
                if data.id >= whisper_token_eot(ctx) { continue }
                guard let raw = whisper_full_get_token_text(ctx, segment, i) else { continue }
                let piece = String(cString: raw)
                if piece.isEmpty { continue }

                let start = TimeInterval(data.t0) / 100
                let end = TimeInterval(data.t1) / 100

                if piece.hasPrefix(" ") || pending == nil {
                    if let done = pending { words.append(done) }
                    pending = TranscriptWord(
                        text: piece.trimmingCharacters(in: .whitespaces),
                        confidence: data.p, start: start, end: end)
                } else if var word = pending {
                    word.text += piece
                    // A word is only as trustworthy as its weakest piece.
                    word.confidence = min(word.confidence, data.p)
                    word.end = end
                    pending = word
                }
            }
            if let done = pending, !done.text.isEmpty { words.append(done) }
        }
        return (text, words.filter { !$0.text.isEmpty })
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
