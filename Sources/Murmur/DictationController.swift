import AppKit

/// The dictation state machine: hotkey → record → transcribe → format → insert.
final class DictationController: ObservableObject {
    enum State {
        case idle
        case recording
        case transcribing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var handsFree = false
    @Published private(set) var history: [String] = []

    var onStateChange: (() -> Void)?

    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyManager()
    private var recordingStartedAt: Date?

    /// Taps shorter than this count as "toggle hands-free" instead of push-to-talk.
    private let tapThreshold: TimeInterval = 0.35
    private let minimumAudioSeconds: Double = 0.4

    func start() {
        hotkeys.trigger = Prefs.triggerKey
        hotkeys.onPress = { [weak self] shift in self?.hotkeyPressed(withShift: shift) }
        hotkeys.onRelease = { [weak self] duration in self?.hotkeyReleased(duration) }
        hotkeys.onEnter = { [weak self] in
            // Return finishes a hands-free recording (and is swallowed).
            guard let self, self.state == .recording, self.handsFree else { return false }
            self.finishRecording()
            return true
        }
        hotkeys.onEscape = { [weak self] in
            guard let self, self.state == .recording else { return false }
            self.cancelRecording()
            return true
        }
        hotkeys.start()
    }

    func reloadHotkey() {
        hotkeys.trigger = Prefs.triggerKey
        hotkeys.start()
    }

    /// Pauses global key handling (used while the settings screen captures a new key).
    func suspendHotkeys() {
        hotkeys.stop()
    }

    /// True when the active CGEventTap is armed (vs. degraded fallback monitors).
    var keyListenerActive: Bool { hotkeys.usingEventTap }

    // MARK: - Hotkey events

    private func hotkeyPressed(withShift shift: Bool) {
        switch state {
        case .idle:
            // Shift+key locks hands-free immediately — no need to keep holding.
            beginRecording(handsFreeIntent: shift)
        case .recording where handsFree:
            // Second press while hands-free: stop and transcribe.
            finishRecording()
        case .recording, .transcribing:
            break
        }
    }

    private func hotkeyReleased(_ duration: TimeInterval) {
        guard state == .recording, !handsFree else {
            // The release that follows the stopping tap of hands-free mode.
            return
        }
        if duration < tapThreshold {
            handsFree = true  // quick tap: keep recording hands-free
            notifyChange()
        } else {
            finishRecording()
        }
    }

    // MARK: - Toggle from the menu

    func toggleHandsFree() {
        switch state {
        case .idle:
            beginRecording(handsFreeIntent: true)
        case .recording:
            finishRecording()
        case .transcribing:
            break
        }
    }

    // MARK: - Recording lifecycle

    private func beginRecording(handsFreeIntent: Bool = false) {
        guard WhisperEngine.shared.isReady else {
            Log.log("record blocked: no model loaded")
            playSound("Basso")
            AppDelegate.shared?.showNoModelHint()
            return
        }
        AudioRecorder.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Log.log("record blocked: microphone permission denied")
                self.showMicDeniedAlert()
                return
            }
            guard self.state == .idle else { return }
            do {
                try self.recorder.start()
                self.recordingStartedAt = Date()
                self.handsFree = handsFreeIntent
                self.state = .recording
                Log.log("recording started (handsFree=\(handsFreeIntent))")
                self.playSound("Pop")
                self.notifyChange()
            } catch {
                Log.log("recording FAILED to start: \(error.localizedDescription)")
                self.playSound("Basso")
            }
        }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        handsFree = false

        let seconds = Double(samples.count) / 16000.0
        guard seconds >= minimumAudioSeconds else {
            Log.log("recording discarded: too short (\(String(format: "%.2f", seconds))s)")
            state = .idle
            notifyChange()
            return
        }

        Log.log("recording stopped: \(String(format: "%.2f", seconds))s of audio, transcribing")
        state = .transcribing
        notifyChange()
        let transcribeStart = Date()

        WhisperEngine.shared.transcribe(samples: samples) { [weak self] text in
            guard let self else { return }
            self.state = .idle
            defer { self.notifyChange() }

            let ms = Int(Date().timeIntervalSince(transcribeStart) * 1000)
            guard var text, !text.isEmpty else {
                Log.log("transcription EMPTY/FAILED after \(ms)ms")
                self.playSound("Basso")
                return
            }
            text = TranscriptFormatter(options: Prefs.formatterOptions).format(text)
            let display = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty else {
                Log.log("transcript empty after formatting (\(ms)ms)")
                return
            }
            Log.log("transcribed \(display.count) chars in \(ms)ms")

            self.history.insert(display, at: 0)
            if self.history.count > 8 { self.history.removeLast() }

            let pasted = TextInserter.insert(text)
            Log.log(pasted ? "inserted via paste" : "CLIPBOARD ONLY — accessibility not effective")
            self.playSound(pasted ? "Tink" : "Bottle")
            if !pasted {
                AppDelegate.shared?.showAccessibilityHint()
            }
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        recorder.stop()
        handsFree = false
        state = .idle
        playSound("Bottle")
        notifyChange()
    }

    // MARK: - Helpers

    private func notifyChange() {
        DispatchQueue.main.async { self.onStateChange?() }
    }

    private func playSound(_ name: String) {
        guard Prefs.defaults.bool(forKey: PrefKey.soundFeedback) else { return }
        let sound = NSSound(named: name)
        sound?.volume = 0.35
        sound?.play()
    }

    private func showMicDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone access is off"
        alert.informativeText = "Murmur needs the microphone to transcribe your voice. "
            + "Enable it in System Settings \u{2192} Privacy & Security \u{2192} Microphone."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
