import Foundation
import AVFoundation
#if canImport(Speech)
import Speech
#endif

/// Shows words in the HUD while you are still speaking.
///
/// Apple's on-device recognizer produces partial results in about a second,
/// which the accurate engines cannot do — Parakeet and Whisper only speak once
/// the utterance is over. So this runs alongside them purely for feedback: what
/// it produces is never inserted, and is discarded the moment the real result
/// arrives.
///
/// The important constraint is the audio format. `AnalyzerInput(buffer:)` does
/// not validate and throw — it traps with SIGTRAP, which no `do/catch` can
/// recover from — unless the buffer is Int16 mono at the analyzer's rate. The
/// recorder produces Float32, so every buffer is converted and then checked
/// again before construction.
@MainActor
final class LiveCaptionEngine {

    /// Latest partial transcript, or empty when there is nothing yet.
    private(set) var caption: String = ""
    var onCaptionChange: ((String) -> Void)?

    private var isRunning = false

    #if canImport(Speech)
    @available(macOS 26, *)
    private final class Session {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let format: AVAudioFormat
        var converter: AVAudioConverter?
        var resultsTask: Task<Void, Never>?

        init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber,
             continuation: AsyncStream<AnalyzerInput>.Continuation,
             format: AVAudioFormat) {
            self.analyzer = analyzer
            self.transcriber = transcriber
            self.continuation = continuation
            self.format = format
        }
    }

    @available(macOS 26, *)
    private var session: Session? {
        get { _session as? Session }
        set { _session = newValue }
    }
    private var _session: AnyObject?
    #endif

    /// Installed locales, cached because the framework only exposes them
    /// asynchronously and the audio path cannot await.
    private static var cachedLocales: [Locale] = []
    private(set) static var isAvailable = false

    /// Called once at launch.
    static func prepare() {
        #if canImport(Speech)
        guard #available(macOS 26, *) else { return }
        Task { @MainActor in
            let locales = await SpeechTranscriber.installedLocales
            cachedLocales = locales
            isAvailable = !locales.isEmpty
            Log.log("live caption locales: \(locales.count) installed")
        }
        #endif
    }

    /// Picks an installed locale matching the user's language, falling back to
    /// any installed English, then to whatever is installed.
    #if canImport(Speech)
    @available(macOS 26, *)
    private static func locale(for language: String) -> Locale? {
        let installed = cachedLocales
        guard !installed.isEmpty else { return nil }
        let wanted = language == "auto" ? "en" : language
        if let exact = installed.first(where: { $0.identifier.hasPrefix(wanted) }) {
            return exact
        }
        return installed.first { $0.identifier.hasPrefix("en") } ?? installed.first
    }
    #endif

    // MARK: - Lifecycle

    func start(language: String) {
        #if canImport(Speech)
        guard #available(macOS 26, *), !isRunning else { return }
        guard let locale = Self.locale(for: language) else { return }

        caption = ""
        onCaptionChange?("")

        // volatileResults is what makes partials arrive in ~1s instead of ~4s.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        isRunning = true
        Task { [weak self] in
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]) else {
                await MainActor.run { self?.isRunning = false }
                return
            }
            let session = Session(
                analyzer: analyzer, transcriber: transcriber,
                continuation: continuation, format: format)
            await MainActor.run { self?.session = session }

            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                Log.log("live caption failed to start: \(error.localizedDescription)")
                await MainActor.run { self?.isRunning = false }
                return
            }

            // Feedback only: a failure here must never affect the dictation.
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self, self.isRunning else { return }
                        self.caption = text
                        self.onCaptionChange?(text)
                    }
                }
            } catch {
                Log.log("live caption stream ended: \(error.localizedDescription)")
            }
        }
        #endif
    }

    /// Feeds one recorder buffer. Called on the audio tap thread.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        #if canImport(Speech)
        guard #available(macOS 26, *) else { return }
        Task { @MainActor [weak self] in
            self?.enqueue(buffer)
        }
        #endif
    }

    #if canImport(Speech)
    @available(macOS 26, *)
    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let session else { return }

        guard let converted = convert(buffer, to: session.format, session: session) else { return }
        // Belt and braces: constructing AnalyzerInput with the wrong format is a
        // trap, not an error, so never hand it anything unverified.
        guard converted.format.commonFormat == .pcmFormatInt16,
              converted.format.channelCount == 1,
              converted.frameLength > 0 else { return }

        session.continuation.yield(AnalyzerInput(buffer: converted))
    }

    @available(macOS 26, *)
    private func convert(
        _ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, session: Session
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if session.converter == nil || session.converter?.inputFormat != buffer.format {
            session.converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter = session.converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
    #endif

    /// Stops and clears. Safe to call when not running.
    func stop() {
        #if canImport(Speech)
        guard #available(macOS 26, *) else { return }
        isRunning = false
        if let session {
            session.continuation.finish()
            session.resultsTask?.cancel()
            let analyzer = session.analyzer
            Task { await analyzer.cancelAndFinishNow() }
        }
        session = nil
        #endif
        caption = ""
        onCaptionChange?("")
    }
}
