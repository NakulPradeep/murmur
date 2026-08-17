import Foundation
import AVFoundation

/// `Murmur --selftest` runs the formatter against known cases and exits.
/// `Murmur --transcribe <audio-file>` loads the model, transcribes, formats, prints, exits.
enum SelfTest {
    static func runIfRequested() {
        runTranscribeIfRequested()
        guard CommandLine.arguments.contains("--selftest") else { return }
        var failures = 0

        func check(_ input: String, _ expected: String, mode: NumberMode = .numerals,
                   punctuation: Bool = false) {
            var opts = FormatterOptions()
            opts.numberMode = mode
            opts.spokenPunctuation = punctuation
            opts.appendTrailingSpace = false
            let got = TranscriptFormatter(options: opts).format(input)
            if got == expected {
                print("  PASS  \(input)  \u{2192}  \(got)")
            } else {
                failures += 1
                print("  FAIL  \(input)\n        expected: \(expected)\n        got:      \(got)")
            }
        }

        print("numerals mode:")
        check("I need forty two copies", "I need 42 copies")
        check("one hundred and five people came", "105 people came")
        check("two thousand twenty five is next year", "2025 is next year")
        check("the price is three point one four", "The price is 3.14")
        check("twenty percent of users", "20% of users")
        check("it costs five hundred rupees", "It costs \u{20B9}500")
        check("fifteen dollars for lunch", "$15 for lunch")
        check("one of the things I like", "One of the things I like")
        check("she was first in line", "She was first in line")
        check("the twenty first of March", "The 21st of March")
        check("a hundred and fifty", "150")
        check("um, so basically we need five", "So basically we need 5")
        check("hundreds of people showed up", "Hundreds of people showed up")

        print("words mode:")
        check("I need 42 copies", "I need forty-two copies", mode: .words)
        check("it costs $15 today", "It costs fifteen dollars today", mode: .words)
        check("about 20% of users", "About twenty percent of users", mode: .words)
        check("pi is 3.14 roughly", "Pi is three point one four roughly", mode: .words)
        check("meet at 3:30 tomorrow", "Meet at 3:30 tomorrow", mode: .words)
        check("version 2.1.3 shipped", "Version 2.1.3 shipped", mode: .words)

        print("auto mode:")
        check("I have three cats and forty two fish", "I have three cats and 42 fish", mode: .auto)
        check("give me five minutes", "Give me five minutes", mode: .auto)
        check("twenty percent done", "20% done", mode: .auto)

        print("commands & cleanup:")
        check("first line new line second line", "First line\nSecond line", mode: .off)
        check("hello new paragraph world", "Hello\n\nWorld", mode: .off)
        check("this works comma right question mark", "This works, right?", mode: .off, punctuation: true)
        check("[BLANK_AUDIO] hello there (coughs)", "Hello there", mode: .off)
        check("uh, I think, um, it's fine", "I think, it's fine", mode: .off)
        check("i think i'll go", "I think I'll go", mode: .off)

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runTranscribeIfRequested() {
        guard let idx = CommandLine.arguments.firstIndex(of: "--transcribe"),
              idx + 1 < CommandLine.arguments.count else { return }
        let path = CommandLine.arguments[idx + 1]

        if let modeIdx = CommandLine.arguments.firstIndex(of: "--mode"),
           modeIdx + 1 < CommandLine.arguments.count {
            Prefs.defaults.set(CommandLine.arguments[modeIdx + 1], forKey: PrefKey.numberMode)
        }

        guard let modelURL = ModelManager.shared.resolveSelectedModel() else {
            print("ERROR: no model installed")
            exit(1)
        }
        guard let samples = loadSamples(path: path) else {
            print("ERROR: could not read audio at \(path)")
            exit(1)
        }
        print("model: \(modelURL.lastPathComponent), audio: \(String(format: "%.1f", Double(samples.count) / 16000))s")

        let start = Date()
        WhisperEngine.shared.loadModel(at: modelURL.path) { ok in
            guard ok else {
                print("ERROR: model failed to load")
                exit(1)
            }
            let loaded = Date()
            print("model loaded in \(String(format: "%.2f", loaded.timeIntervalSince(start)))s")
            WhisperEngine.shared.transcribe(samples: samples) { text in
                guard let text else {
                    print("ERROR: transcription failed")
                    exit(1)
                }
                let secs = Date().timeIntervalSince(loaded)
                print("transcribed in \(String(format: "%.2f", secs))s")
                print("raw:       \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                let formatted = TranscriptFormatter(options: Prefs.formatterOptions).format(text)
                print("formatted: \(formatted)")
                WhisperEngine.shared.shutdown()
                fflush(stdout)
                _exit(0)
            }
        }
        RunLoop.main.run()
    }

    private static func loadSamples(path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try? file.read(into: inBuf)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        let ratio = 16000.0 / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        converter.convert(to: outBuf, error: nil) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard let ch = outBuf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}
