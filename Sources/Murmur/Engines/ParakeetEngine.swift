import Foundation
import CWhisper

/// NVIDIA Parakeet TDT backend, via the parakeet support vendored in
/// whisper.cpp 1.9.1.
///
/// Parakeet is a transducer rather than an encoder-decoder, which changes the
/// tradeoffs: it is dramatically faster than Whisper, it does not hallucinate
/// text on silence (there is no language-model decoder to run away), and it
/// emits explicit word boundaries. It has no `initial_prompt` equivalent, so
/// vocabulary correction happens after the fact instead of during decoding.
final class ParakeetEngine: TranscriptionEngine {
    static let id = "parakeet"
    var displayName: String { "Parakeet" }

    private let lock = NSLock()
    private var ctx: OpaquePointer?
    private var modelName: String?

    private var decoding = false
    private let decodeFinished = NSCondition()

    var isReady: Bool { lock.withLock { ctx != nil } }
    var loadedModelName: String? { lock.withLock { modelName } }
    /// No prompt-conditioning hook exists in the transducer path.
    var supportsVocabularyBiasing: Bool { false }
    var supportsWordTimings: Bool { true }

    /// Parakeet prints a page of model detail to stderr on every load.
    private static let silenceLogs: Void = {
        let quiet: ggml_log_callback = { _, _, _ in }
        parakeet_log_set(quiet, nil)
        ggml_log_set(quiet, nil)
    }()

    // MARK: - Lifecycle

    func load(modelPath: String) throws {
        _ = Self.silenceLogs
        unload()
        var cparams = parakeet_context_default_params()
        cparams.use_gpu = true

        guard let newCtx = parakeet_init_from_file_with_params(modelPath, cparams) else {
            throw TranscriptionError.modelLoadFailed(modelPath)
        }
        lock.withLock {
            ctx = newCtx
            modelName = (modelPath as NSString).lastPathComponent
        }
        Log.log("parakeet loaded \(modelName ?? "?")")
    }

    func unload() {
        decodeFinished.lock()
        while decoding { decodeFinished.wait() }
        decodeFinished.unlock()

        lock.withLock {
            if let old = ctx {
                parakeet_free(old)
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
        var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        params.n_threads = Int32(Self.decodeThreadCount)
        params.no_context = true

        var cancelBox = CancelBox(isCancelled: request.isCancelled)
        var status: Int32 = -1

        withUnsafeMutablePointer(to: &cancelBox) { cancelPtr in
            params.abort_callback = { userData in
                guard let userData else { return false }
                return userData.assumingMemoryBound(to: CancelBox.self)
                    .pointee.isCancelled?() ?? false
            }
            params.abort_callback_user_data = UnsafeMutableRawPointer(cancelPtr)

            status = request.samples.withUnsafeBufferPointer { buf in
                parakeet_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
        }

        if request.isCancelled?() == true { throw TranscriptionError.cancelled }
        guard status == 0 else { throw TranscriptionError.decodeFailed(status) }

        let (text, words) = collectOutput(ctx: ctx)
        return TranscriptionResult(
            text: text,
            words: words,
            engineID: Self.id,
            modelName: modelName ?? "?",
            processingTime: Date().timeIntervalSince(started),
            detectedLanguage: nil
        )
    }

    private struct CancelBox {
        var isCancelled: (() -> Bool)?
    }

    private static let decodeThreadCount: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }()

    // MARK: - Output

    private func collectOutput(ctx: OpaquePointer) -> (String, [TranscriptWord]) {
        var text = ""
        var words: [TranscriptWord] = []

        for segment in 0..<parakeet_full_n_segments(ctx) {
            if let raw = parakeet_full_get_segment_text(ctx, segment) {
                text += String(cString: raw)
            }
            // Parakeet marks word starts explicitly, so grouping is exact
            // rather than inferred from leading spaces.
            var pending: TranscriptWord?
            for i in 0..<parakeet_full_n_tokens(ctx, segment) {
                guard let raw = parakeet_full_get_token_text(ctx, segment, i) else { continue }
                let data = parakeet_full_get_token_data(ctx, segment, i)
                // The sentencepiece marker doubles as the word delimiter.
                let piece = String(cString: raw).replacingOccurrences(of: "\u{2581}", with: "")
                let start = TimeInterval(data.t0) / 100
                let end = TimeInterval(data.t1) / 100

                if data.is_word_start || pending == nil {
                    if let done = pending, !done.text.isEmpty { words.append(done) }
                    pending = TranscriptWord(
                        text: piece, confidence: data.p, start: start, end: end)
                } else if var word = pending {
                    word.text += piece
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
