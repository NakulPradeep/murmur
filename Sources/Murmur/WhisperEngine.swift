import Foundation
import CWhisper

/// Owns the whisper.cpp context. The model loads once and stays resident,
/// so each dictation pays zero model-load cost.
final class WhisperEngine {
    static let shared = WhisperEngine()

    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "murmur.whisper", qos: .userInitiated)
    private(set) var loadedModelPath: String?
    private var multilingual = false

    // whisper_full_params.language wants a stable C string.
    private let langEN = strdup("en")
    private let langAuto = strdup("auto")

    var isReady: Bool { ctx != nil }
    var onModelStateChange: (() -> Void)?

    private static let silenceLogs: Void = {
        let quiet: ggml_log_callback = { _, _, _ in }
        whisper_log_set(quiet, nil)
        ggml_log_set(quiet, nil)
    }()

    /// Frees the whisper context before process exit; ggml's Metal teardown
    /// asserts if residency sets are still alive inside exit().
    func shutdown() {
        queue.sync {
            if let old = ctx {
                whisper_free(old)
                ctx = nil
            }
        }
    }

    func loadModel(at path: String, completion: ((Bool) -> Void)? = nil) {
        _ = Self.silenceLogs
        queue.async { [self] in
            if let old = ctx {
                whisper_free(old)
                ctx = nil
            }
            var cparams = whisper_context_default_params()
            cparams.use_gpu = true
            cparams.flash_attn = true
            ctx = whisper_init_from_file_with_params(path, cparams)
            let ok = ctx != nil
            if ok {
                loadedModelPath = path
                multilingual = whisper_is_multilingual(ctx) != 0
            } else {
                loadedModelPath = nil
            }
            DispatchQueue.main.async {
                self.onModelStateChange?()
                completion?(ok)
            }
        }
    }

    /// Transcribes 16 kHz mono float samples. Calls back on the main queue.
    func transcribe(samples: [Float], completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            guard let ctx else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.no_timestamps = true
            params.suppress_blank = true
            params.single_segment = false
            params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            params.language = UnsafePointer(multilingual ? langAuto : langEN)

            let status = samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
            guard status == 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var text = ""
            for i in 0..<whisper_full_n_segments(ctx) {
                if let seg = whisper_full_get_segment_text(ctx, i) {
                    text += String(cString: seg)
                }
            }
            DispatchQueue.main.async { completion(text) }
        }
    }
}
