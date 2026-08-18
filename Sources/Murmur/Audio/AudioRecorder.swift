import AVFoundation
import Accelerate

/// Microphone capture, resampled to the 16 kHz mono float the recognizers want.
///
/// Two things here matter for accuracy and are easy to get wrong:
///
/// 1. **One converter for the whole session.** `AVAudioConverter` carries
///    resampler filter state between calls. Creating one per buffer — or feeding
///    each tap buffer as an independent stream — produces a click at every
///    buffer seam, which the recognizers hear as noise.
/// 2. **Pre-roll.** People start talking before the key registers. A rolling
///    buffer keeps the last fraction of a second of audio so the first syllable
///    survives.
final class AudioRecorder {
    /// How much audio before the key press to keep.
    private let preRollSeconds: Double = 0.5

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    private let lock = NSLock()
    private var captured: [Float] = []
    private var preRoll: [Float] = []
    private var isCapturing = false
    private var didClip = false

    private(set) var isRunning = false

    /// Most recent short-window level, 0–1, for the recording indicator.
    private(set) var level: Float = 0

    /// Receives every captured buffer while a capture is active, for the live
    /// caption engine. Called on the audio tap thread.
    var onCaptureBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(Constants.sampleRate),
        channels: 1,
        interleaved: false)!

    private var preRollCapacity: Int { Int(preRollSeconds * Double(Constants.sampleRate)) }

    // MARK: - Permission

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Engine lifecycle

    /// Starts the audio engine and begins filling the pre-roll buffer without
    /// recording. Called when the app arms, so the first dictation does not pay
    /// engine-start latency and the pre-roll is already warm.
    func startMonitoring() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // The node reports a zero format until the engine has run once, and a
        // zero-rate format makes AVAudioConverter return nil.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Murmur", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No microphone input is available."])
        }

        inputFormat = format
        converter = AVAudioConverter(from: format, to: targetFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        // The input device can change under us (AirPods connecting, a dock
        // being plugged in). The tap silently stops delivering when it does.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange, object: engine)
    }

    func stopMonitoring() {
        guard isRunning else { return }
        NotificationCenter.default.removeObserver(
            self, name: .AVAudioEngineConfigurationChange, object: engine)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        lock.withLock {
            captured.removeAll()
            preRoll.removeAll()
            isCapturing = false
        }
    }

    @objc private func handleConfigurationChange(_ note: Notification) {
        Log.log("audio route changed — restarting capture")
        let wasCapturing = lock.withLock { isCapturing }
        stopMonitoring()
        do {
            try startMonitoring()
            if wasCapturing { beginCapture() }
        } catch {
            Log.log("audio restart FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Capture

    /// Begins accumulating, seeded with whatever pre-roll is buffered.
    func beginCapture() {
        lock.withLock {
            captured = preRoll
            isCapturing = true
            didClip = false
        }
    }

    /// Stops accumulating and returns the recording, preprocessed for the
    /// recognizer. Returns an empty array if nothing was captured.
    func finishCapture() -> (samples: [Float], clipped: Bool) {
        let (raw, clipped): ([Float], Bool) = lock.withLock {
            let out = captured
            let c = didClip
            captured.removeAll(keepingCapacity: true)
            isCapturing = false
            return (out, c)
        }
        guard !raw.isEmpty else { return ([], false) }
        return (preprocess(raw), clipped)
    }

    func cancelCapture() {
        lock.withLock {
            captured.removeAll(keepingCapacity: true)
            isCapturing = false
        }
    }

    /// Seconds captured so far.
    var capturedSeconds: Double {
        lock.withLock { Double(captured.count) / Double(Constants.sampleRate) }
    }

    // MARK: - Tap

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        // One buffer per invocation. Returning .noDataNow (rather than
        // .endOfStream) keeps the converter's filter state alive for the next
        // call, which is what avoids discontinuities at buffer boundaries.
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

        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData else {
            if let error { Log.log("audio convert error: \(error.localizedDescription)") }
            return
        }

        let count = Int(out.frameLength)
        let samples = UnsafeBufferPointer(start: channel[0], count: count)

        // Level meter: RMS over this buffer, smoothed, on a perceptual curve.
        var rms: Float = 0
        vDSP_rmsqv(samples.baseAddress!, 1, &rms, vDSP_Length(count))
        var peak: Float = 0
        vDSP_maxmgv(samples.baseAddress!, 1, &peak, vDSP_Length(count))
        let scaled = min(1, sqrt(rms) * 3.2)
        level = level * 0.7 + scaled * 0.3

        let capturingNow = lock.withLock { isCapturing }
        if capturingNow { onCaptureBuffer?(out) }

        lock.withLock {
            if peak > 0.99 { didClip = true }
            if isCapturing {
                captured.append(contentsOf: samples)
            }
            // Keep the rolling pre-roll window topped up either way, so a
            // capture that starts mid-word can still recover the start.
            preRoll.append(contentsOf: samples)
            if preRoll.count > preRollCapacity {
                preRoll.removeFirst(preRoll.count - preRollCapacity)
            }
        }
    }

    // MARK: - Preprocessing

    /// Deliberately does nothing to the signal.
    ///
    /// Gain normalization and DC-offset removal are the obvious things to reach
    /// for here, and both were measured to be worthless: transcribing the same
    /// clip at 1×, 0.1× and 0.03× gain (RMS 0.17 down to 0.005) produced
    /// identical text. Normalizing is worse than neutral — boosting a quiet
    /// room lifts background noise toward speech level, which is a known way to
    /// make Whisper hallucinate. The recognizers do their own mel normalization;
    /// the best thing to hand them is the samples as captured.
    ///
    /// Kept as a seam so any future processing has an obvious home, and so the
    /// reasoning above does not get re-discovered the hard way.
    private func preprocess(_ input: [Float]) -> [Float] {
        input
    }
}
