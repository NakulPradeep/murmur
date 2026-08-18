import AppKit

/// The dictation state machine: hotkey → record → transcribe → refine → insert.
///
/// Every mutation happens on the main queue. The hotkey tap and the audio tap
/// both run off-main, so each entry point hops to main first; that is what keeps
/// the published state and the state machine itself consistent.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case polishing
    }

    struct HistoryEntry: Identifiable, Codable {
        var id = UUID()
        var text: String
        var date: Date
        var engine: String
        var seconds: Double
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var handsFree = false
    @Published private(set) var history: [HistoryEntry] = []
    /// 0–1 input level, for the recording indicator.
    @Published private(set) var level: Float = 0

    var onStateChange: (() -> Void)?

    let recorder = AudioRecorder()
    private let hotkeys = HotkeyManager()
    private var levelTimer: Timer?
    /// Replaced per recording; the running decode holds its own reference, so
    /// cancelling one dictation can never abort the next.
    private var cancellation = CancellationToken()
    /// Tail of the last insertion, fed back as decoder context so a sentence
    /// split across two presses stays coherent.
    private var priorContext: String?

    /// Presses shorter than this toggle hands-free instead of push-to-talk.
    private let tapThreshold: TimeInterval = 0.35
    private let minimumSeconds: Double = 0.35
    private let maximumSeconds: Double = 300

    // MARK: - Lifecycle

    func start() {
        hotkeys.trigger = Prefs.triggerKey
        hotkeys.onPress = { [weak self] shift in
            Task { @MainActor in self?.hotkeyPressed(withShift: shift) }
        }
        hotkeys.onRelease = { [weak self] duration in
            Task { @MainActor in self?.hotkeyReleased(duration) }
        }
        // These two run inside the CGEventTap callback, which is serviced by the
        // main run loop — so they are already on the main thread and must decide
        // synchronously whether to swallow the key. Dispatching to main here
        // would deadlock the entire app on the first Return press.
        hotkeys.onEnter = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording, self.handsFree else { return false }
                // Return finishes a hands-free recording and is swallowed, so it
                // does not also submit whatever the user is typing into.
                self.finishRecording()
                return true
            }
        }
        hotkeys.onEscape = { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.state == .recording || self.state == .transcribing
                        || self.state == .polishing
                else { return false }
                self.cancel()
                return true
            }
        }
        hotkeys.start()
        loadHistory()
    }

    func reloadHotkey() {
        hotkeys.trigger = Prefs.triggerKey
        hotkeys.start()
    }

    func suspendHotkeys() { hotkeys.stop() }

    var keyListenerActive: Bool { hotkeys.usingEventTap }

    // MARK: - Hotkey handling

    private func hotkeyPressed(withShift shift: Bool) {
        switch state {
        case .idle:
            // Shift locks hands-free straight away, so there is no need to keep
            // holding the key.
            beginRecording(handsFreeIntent: shift)
        case .recording where handsFree:
            finishRecording()
        case .recording, .transcribing, .polishing:
            break
        }
    }

    private func hotkeyReleased(_ duration: TimeInterval) {
        // A release arriving in any state other than an active push-to-talk
        // recording is the tail of a hands-free toggle; ignore it.
        guard state == .recording, !handsFree else { return }
        if duration < tapThreshold {
            handsFree = true
            notify()
        } else {
            finishRecording()
        }
    }

    func toggleHandsFree() {
        switch state {
        case .idle: beginRecording(handsFreeIntent: true)
        case .recording: finishRecording()
        case .transcribing, .polishing: break
        }
    }

    // MARK: - Recording

    private func beginRecording(handsFreeIntent: Bool) {
        guard state == .idle else { return }
        guard EngineRouter.shared.isReady else {
            Log.log("record blocked: no model loaded")
            play(.error)
            AppDelegate.shared?.showModelNeededHint()
            return
        }

        AudioRecorder.requestPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.state == .idle else { return }
                guard granted else {
                    Log.log("record blocked: microphone permission denied")
                    self.showMicrophoneDeniedAlert()
                    return
                }
                do {
                    if !self.recorder.isRunning { try self.recorder.startMonitoring() }
                    self.recorder.beginCapture()
                    self.cancellation = CancellationToken()
                    self.handsFree = handsFreeIntent
                    self.state = .recording
                    self.startLevelUpdates()
                    Log.log("recording started (handsFree=\(handsFreeIntent))")
                    self.play(.start)
                    self.notify()
                } catch {
                    Log.log("recording FAILED to start: \(error.localizedDescription)")
                    self.play(.error)
                }
            }
        }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        stopLevelUpdates()
        handsFree = false
        // The tap delivers in buffers, so the last fraction of a second of
        // speech is still in flight when the key comes up. Harvesting
        // immediately clips the final consonant, which costs a whole word.
        state = .transcribing
        notify()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tailSeconds) { [weak self] in
            self?.harvestAndTranscribe()
        }
    }

    /// Long enough to catch the in-flight tap buffer, short enough to stay
    /// imperceptible.
    private static let tailSeconds: TimeInterval = 0.12

    private func harvestAndTranscribe() {
        guard state == .transcribing else { return }
        let (samples, clipped) = recorder.finishCapture()

        let seconds = Double(samples.count) / Double(Constants.sampleRate)
        guard seconds >= minimumSeconds else {
            Log.log("recording discarded: \(String(format: "%.2f", seconds))s is too short")
            state = .idle
            notify()
            return
        }
        if clipped { Log.log("warning: input clipped — microphone gain may be too high") }
        Log.log("recording stopped: \(String(format: "%.2f", seconds))s, transcribing")

        var request = TranscriptionRequest(samples: Array(samples.prefix(
            Int(maximumSeconds) * Constants.sampleRate)))
        request.vocabulary = Prefs.vocabulary.map(\.term).filter { !$0.isEmpty }
        request.priorContext = priorContext
        request.language = Prefs.language
        // Captured by value: the decode reads this from the engine queue, and
        // it must keep pointing at this recording's token even if a later
        // recording replaces the controller's current one.
        let token = cancellation
        request.isCancelled = { token.isCancelled }

        EngineRouter.shared.transcribe(request) { [weak self] result in
            Task { @MainActor in self?.handle(result, seconds: seconds) }
        }
    }

    private func handle(_ result: Result<TranscriptionResult, Error>, seconds: Double) {
        guard state == .transcribing else { return }

        switch result {
        case .failure(let error):
            state = .idle
            notify()
            if case TranscriptionError.cancelled = error {
                Log.log("transcription cancelled")
                return
            }
            Log.log("transcription FAILED: \(error.localizedDescription)")
            play(.error)

        case .success(let transcription):
            let pipeline = RefinementPipeline.current()
            let text = pipeline.refine(transcription)
            let display = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !display.isEmpty else {
                Log.log("transcript empty after refinement")
                state = .idle
                notify()
                return
            }
            Log.log(String(
                format: "transcribed %d chars in %.0fms via %@ (%.2fx realtime, conf %.2f)",
                display.count, transcription.processingTime * 1000,
                transcription.engineID,
                seconds / max(transcription.processingTime, 0.001),
                transcription.meanConfidence))

            let mode = Prefs.polishMode
            guard mode != .off, AIRefiner.availability.isReady else {
                complete(text: text, display: display, transcription: transcription,
                         seconds: seconds)
                return
            }

            state = .polishing
            notify()
            Task { @MainActor [weak self] in
                let polished = await AIRefiner.polish(display, mode: mode)
                guard let self, self.state == .polishing else { return }
                if let polished {
                    // Re-run formatting so trailing-space and spacing rules
                    // still apply to the rewritten text.
                    let final = TranscriptFormatter(options: Prefs.formatterOptions)
                        .format(polished)
                    self.complete(text: final,
                                  display: final.trimmingCharacters(in: .whitespacesAndNewlines),
                                  transcription: transcription, seconds: seconds)
                } else {
                    self.complete(text: text, display: display,
                                  transcription: transcription, seconds: seconds)
                }
            }
        }
    }

    private func complete(
        text: String, display: String,
        transcription: TranscriptionResult, seconds: Double
    ) {
        state = .idle
        defer { notify() }

        guard !cancellation.isCancelled else {
            Log.log("insertion skipped: cancelled")
            return
        }

        record(HistoryEntry(
            text: display, date: Date(),
            engine: transcription.modelName, seconds: seconds))
        priorContext = String(display.suffix(160))

        let outcome = TextInserter.insert(text)
        switch outcome {
        case .inserted:
            play(.success)
        case .clipboardOnly(let reason):
            Log.log("clipboard only: \(reason)")
            play(.warning)
            AppDelegate.shared?.showInsertionFallbackHint(reason: reason)
        }
    }

    func cancel() {
        guard state != .idle else { return }
        cancellation.cancel()
        stopLevelUpdates()
        recorder.cancelCapture()
        handsFree = false
        state = .idle
        play(.cancel)
        notify()
        Log.log("dictation cancelled by user")
    }

    // MARK: - Level metering

    private func startLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.level = self.recorder.level
            }
        }
    }

    private func stopLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = nil
        level = 0
    }

    // MARK: - History

    private func record(_ entry: HistoryEntry) {
        guard Prefs.defaults.bool(forKey: PrefKey.keepHistory) else { return }
        history.insert(entry, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private static var historyURL: URL {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL) else { return }
        history = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func saveHistory() {
        let snapshot = history
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.historyURL, options: .atomic)
        }
    }

    // MARK: - Feedback

    private enum Feedback { case start, success, warning, error, cancel }

    private func play(_ feedback: Feedback) {
        guard Prefs.defaults.bool(forKey: PrefKey.soundFeedback) else { return }
        let name: String
        switch feedback {
        case .start: name = "Pop"
        case .success: name = "Tink"
        case .warning: name = "Bottle"
        case .error: name = "Basso"
        case .cancel: name = "Bottle"
        }
        let sound = NSSound(named: name)
        sound?.volume = 0.3
        sound?.play()
    }

    private func notify() {
        onStateChange?()
    }

    private func showMicrophoneDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone access is off"
        alert.informativeText = "Murmur needs the microphone to transcribe your voice. "
            + "Enable it in System Settings \u{2192} Privacy & Security \u{2192} Microphone."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
