import Foundation
import AVFoundation

/// Command-line entry points:
///   --selftest                 formatter, phonetics and vocabulary cases
///   --transcribe FILE          run the pipeline over an audio file
///   --bench FILE               time every installed model on one file
enum SelfTest {
    static func runIfRequested() {
        runTranscribeIfRequested()
        runBenchmarkIfRequested()
        guard CommandLine.arguments.contains("--selftest") else { return }

        var failures = 0
        var checks = 0

        func check(
            _ input: String, _ expected: String,
            mode: NumberMode = .numerals, punctuation: Bool = false,
            corrections: Bool = true, vocabulary: [String] = [],
            label: String = ""
        ) {
            checks += 1
            var options = FormatterOptions()
            options.numberMode = mode
            options.spokenPunctuation = punctuation
            options.resolveSelfCorrections = corrections
            options.appendTrailingSpace = false

            let pipeline = RefinementPipeline(
                formatterOptions: options,
                vocabulary: vocabulary.map { VocabularyEntry(term: $0) })
            let got = pipeline.refine(text: input)

            if got == expected {
                print("  PASS  \(input)  \u{2192}  \(got)")
            } else {
                failures += 1
                print("  FAIL  \(label.isEmpty ? input : label)")
                print("        input:    \(input)")
                print("        expected: \(expected)")
                print("        got:      \(got)")
            }
        }

        print("numbers \u{2014} numerals:")
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
        check("hundreds of people showed up", "Hundreds of people showed up")

        print("numbers \u{2014} words:")
        check("I need 42 copies", "I need forty-two copies", mode: .words)
        check("it costs $15 today", "It costs fifteen dollars today", mode: .words)
        check("about 20% of users", "About twenty percent of users", mode: .words)
        check("pi is 3.14 roughly", "Pi is three point one four roughly", mode: .words)
        check("meet at 3:30 tomorrow", "Meet at 3:30 tomorrow", mode: .words)
        check("version 2.1.3 shipped", "Version 2.1.3 shipped", mode: .words)

        print("numbers \u{2014} auto:")
        check("I have three cats and forty two fish",
              "I have three cats and 42 fish", mode: .auto)
        check("give me five minutes", "Give me five minutes", mode: .auto)
        check("twenty percent done", "20% done", mode: .auto)

        print("commands and cleanup:")
        check("first line new line second line", "First line\nSecond line", mode: .off)
        check("hello new paragraph world", "Hello\n\nWorld", mode: .off)
        check("this works comma right question mark", "This works, right?",
              mode: .off, punctuation: true)
        check("[BLANK_AUDIO] hello there (coughs)", "Hello there", mode: .off)
        check("uh, I think, um, it's fine", "I think, it's fine", mode: .off)
        check("i think i'll go", "I think I'll go", mode: .off)

        print("self-corrections and stutters:")
        // Weekday casing comes from the recognizer, which capitalizes proper
        // nouns itself; these inputs are deliberately lowercase.
        check("ship it on friday no wait monday", "Ship it on monday", mode: .off)
        check("send it to the the report", "Send it to the report", mode: .off)
        check("I I think we we should go", "I think we should go", mode: .off)
        check("call him tuesday, actually i meant wednesday",
              "Call him wednesday", mode: .off)
        check("use the blue one scratch that the red one",
              "Use the red one", mode: .off)
        // Corrections off leaves the words alone.
        check("ship it friday no wait monday", "Ship it friday no wait monday",
              mode: .off, corrections: false)
        // A repeated word across a sentence break is not a stutter.
        check("that is that. that is fine", "That is that. That is fine", mode: .off)
        // Repeated number words are meaningful, not stammers.
        check("it happened in twenty twenty four", "It happened in 2024")
        check("we split it fifty fifty", "We split it fifty fifty", mode: .off)
        check("he said no no no", "He said no", mode: .off)

        print("years:")
        check("born in nineteen eighty four", "Born in 1984")
        check("back in nineteen ninety", "Back in 1990")
        check("the seventeen seventy six revolution", "The 1776 revolution")
        check("it is twenty twenty", "It is 2020")
        // Not years: an ordinary compound, and a range too large to be one.
        check("I have twenty five apples", "I have 25 apples")
        check("forty fifty people came", "40 50 people came")

        print("vocabulary:")
        check("I told karen about it", "I told Kiran about it",
              mode: .off, vocabulary: ["Kiran"])
        check("open ex code", "Open Xcode", mode: .off, vocabulary: ["Xcode"])
        check("I used clawed code", "I used Claude Code",
              mode: .off, vocabulary: ["Claude Code"])
        check("deploy to kubernetes", "Deploy to Kubernetes",
              mode: .off, vocabulary: ["Kubernetes"])
        // Must not over-correct unrelated words.
        check("the car needs a key", "The car needs a key",
              mode: .off, vocabulary: ["Kiran"])
        check("she is very kind", "She is very kind",
              mode: .off, vocabulary: ["Kiran"])

        print("phonetic keys:")
        let keyCases: [(String, String)] = [
            ("Kiran", "Karen"), ("Murmur", "mermer"), ("Xcode", "ex code"),
            ("Claude", "clawed"), ("Parakeet", "para keet"), ("phone", "fone"),
        ]
        for (a, b) in keyCases {
            checks += 1
            let ka = Phonetics.key(a), kb = Phonetics.key(b)
            if ka == kb {
                print("  PASS  \(a) \u{2261} \(b)  (\(ka))")
            } else {
                failures += 1
                print("  FAIL  \(a) [\(ka)] should sound like \(b) [\(kb)]")
            }
        }
        // Distinct words must not collide.
        for (a, b) in [("Kiran", "kitchen"), ("code", "cat"), ("Murmur", "murder")] {
            checks += 1
            if Phonetics.key(a) != Phonetics.key(b) {
                print("  PASS  \(a) \u{2260} \(b)")
            } else {
                failures += 1
                print("  FAIL  \(a) collides with \(b) (\(Phonetics.key(a)))")
            }
        }

        print("wrong-script detection:")
        func scriptCheck(_ text: String, _ language: String, _ expectWrong: Bool, _ label: String) {
            checks += 1
            let expected = ScriptGuard.expectedScript(for: language)
            let got = ScriptGuard.isWrongScript(text, expected: expected)
            if got == expectWrong {
                print("  PASS  \(label)")
            } else {
                failures += 1
                print("  FAIL  \(label): expected wrongScript=\(expectWrong), got \(got)")
            }
        }
        // The reported bug: English spoken, Cyrillic written.
        scriptCheck("\u{412}\u{43E}\u{443}, \u{438}\u{442} \u{432}\u{43E}\u{43A}\u{441}", "en", true,
                    "English pinned, Cyrillic transliteration is caught")
        scriptCheck("Whoa, it works", "en", false, "English pinned, Latin text passes")
        // Someone actually speaking Russian must not be second-guessed.
        scriptCheck("\u{412}\u{43E}\u{443}, \u{438}\u{442} \u{432}\u{43E}\u{43A}\u{441}", "ru", false,
                    "Russian pinned, Cyrillic passes")
        scriptCheck("Whoa, it works", "ru", true, "Russian pinned, Latin is caught")
        // Auto means we have no expectation, so never override.
        scriptCheck("\u{412}\u{43E}\u{443}, \u{438}\u{442} \u{432}\u{43E}\u{43A}\u{441}", "auto", false,
                    "auto never overrides")
        // A borrowed word or a short reply is not evidence of misdetection.
        scriptCheck("The word \u{43C}\u{438}\u{440} means peace", "en", false,
                    "a quoted foreign word is tolerated")
        // The reported recurrence: a single short word, wholly in another
        // script. Must be caught however short it is.
        scriptCheck("\u{424}\u{43B}\u{438}.", "en", true,
                    "short all-Cyrillic word is caught (\"free\" -> \"Фли\")")
        scriptCheck("\u{41E}\u{41A}", "en", true, "two Cyrillic letters are caught")
        scriptCheck("OK", "en", false, "short Latin passes")
        scriptCheck("Hi", "ru", true, "short Latin caught when Russian is pinned")

        print("\n\(checks - failures)/\(checks) passed")
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Transcribe a file

    private static func runTranscribeIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: "--transcribe"),
              index + 1 < CommandLine.arguments.count else { return }
        let path = CommandLine.arguments[index + 1]

        if let modeIndex = CommandLine.arguments.firstIndex(of: "--mode"),
           modeIndex + 1 < CommandLine.arguments.count {
            Prefs.defaults.set(CommandLine.arguments[modeIndex + 1], forKey: PrefKey.numberMode)
        }
        Prefs.registerDefaults()
        // --vocab "Kiran,Claude Code" exercises the vocabulary path without
        // having to configure it in the UI first.
        if let vocabIndex = CommandLine.arguments.firstIndex(of: "--vocab"),
           vocabIndex + 1 < CommandLine.arguments.count {
            let terms = CommandLine.arguments[vocabIndex + 1]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            Prefs.vocabulary = terms.map { VocabularyEntry(term: $0) }
            print("vocabulary: \(terms.joined(separator: ", "))")
        }

        guard let model = modelFromArguments() else {
            print("ERROR: no model installed. Launch Murmur and download one.")
            exit(1)
        }
        guard var samples = loadSamples(path: path) else {
            print("ERROR: could not read audio at \(path)")
            exit(1)
        }
        // --gain lets us check empirically whether input level actually affects
        // recognition, which decides whether normalizing on capture is worth
        // the hallucination risk of amplifying a quiet room.
        if let gainIndex = CommandLine.arguments.firstIndex(of: "--gain"),
           gainIndex + 1 < CommandLine.arguments.count,
           let gain = Float(CommandLine.arguments[gainIndex + 1]) {
            samples = samples.map { $0 * gain }
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
            print("gain: \(gain)x, resulting RMS \(String(format: "%.5f", rms))")
        }

        let seconds = Double(samples.count) / Double(Constants.sampleRate)
        print("model: \(model.title) [\(model.engine.rawValue)], "
            + "audio: \(String(format: "%.1f", seconds))s")

        let loadStart = Date()
        EngineRouter.shared.activate(model) { ok in
            guard ok else {
                print("ERROR: \(EngineRouter.shared.lastLoadError ?? "model failed to load")")
                exit(1)
            }
            print("loaded in \(String(format: "%.2f", Date().timeIntervalSince(loadStart)))s")

            var request = TranscriptionRequest(samples: samples)
            request.vocabulary = Prefs.vocabulary.map(\.term)
            request.language = Prefs.language
            do {
                let result = try EngineRouter.shared.transcribeSync(request)
                print("transcribed in \(String(format: "%.2f", result.processingTime))s "
                    + "(\(String(format: "%.1f", seconds / max(result.processingTime, 0.001)))x realtime)")
                print("confidence: \(String(format: "%.3f", result.meanConfidence))")
                print("raw:       \(result.text.trimmingCharacters(in: .whitespacesAndNewlines))")
                let refined = RefinementPipeline.current().refine(result)
                print("formatted: \(refined)")

                let weak = result.lowConfidenceWords(below: 0.5).prefix(6)
                if !weak.isEmpty {
                    print("low confidence: "
                        + weak.map { "\($0.text) (\(String(format: "%.2f", $0.confidence)))" }
                            .joined(separator: ", "))
                }
            } catch {
                print("ERROR: \(error.localizedDescription)")
                exit(1)
            }
            EngineRouter.shared.shutdown()
            fflush(stdout)
            _exit(0)
        }
        RunLoop.main.run()
    }

    // MARK: - Benchmark every installed model

    private static func runBenchmarkIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: "--bench"),
              index + 1 < CommandLine.arguments.count else { return }
        let path = CommandLine.arguments[index + 1]
        Prefs.registerDefaults()

        guard let samples = loadSamples(path: path) else {
            print("ERROR: could not read audio at \(path)")
            exit(1)
        }
        let seconds = Double(samples.count) / Double(Constants.sampleRate)
        let models = ModelCatalog.installed
        guard !models.isEmpty else {
            print("ERROR: no models installed.")
            exit(1)
        }
        print("audio: \(String(format: "%.1f", seconds))s, \(models.count) model(s)\n")

        DispatchQueue.global().async {
            for model in models.sorted(by: { $0.autoRank > $1.autoRank }) {
                let semaphore = DispatchSemaphore(value: 0)
                var loaded = false
                let loadStart = Date()
                EngineRouter.shared.activate(model) { ok in
                    loaded = ok
                    semaphore.signal()
                }
                semaphore.wait()
                let loadTime = Date().timeIntervalSince(loadStart)

                guard loaded else {
                    print("\(model.title): FAILED to load")
                    continue
                }
                do {
                    var request = TranscriptionRequest(samples: samples)
                    request.vocabulary = Prefs.vocabulary.map(\.term)
                    request.language = Prefs.language
                    let result = try EngineRouter.shared.transcribeSync(request)
                    let speed = seconds / max(result.processingTime, 0.001)
                    print("\(model.title) [\(model.engine.rawValue)]")
                    print(String(
                        format: "  load %.2fs  decode %.2fs  %.0fx realtime  confidence %.3f",
                        loadTime, result.processingTime, speed, result.meanConfidence))
                    print("  \(result.text.trimmingCharacters(in: .whitespacesAndNewlines))\n")
                } catch {
                    print("\(model.title): ERROR \(error.localizedDescription)\n")
                }
            }
            EngineRouter.shared.shutdown()
            fflush(stdout)
            _exit(0)
        }
        RunLoop.main.run()
    }

    // MARK: - Helpers

    private static func modelFromArguments() -> ModelDescriptor? {
        if let index = CommandLine.arguments.firstIndex(of: "--model"),
           index + 1 < CommandLine.arguments.count {
            let wanted = CommandLine.arguments[index + 1]
            if let exact = ModelCatalog.descriptor(for: wanted) { return exact }
            if let byEngine = ModelCatalog.installed.first(where: {
                $0.engine.rawValue == wanted
            }) { return byEngine }
            print("ERROR: unknown model \(wanted)")
            exit(1)
        }
        return EngineRouter.preferredModel()
    }

    /// Reads any audio file AVFoundation understands and converts it to the
    /// 16 kHz mono float the engines expect.
    static func loadSamples(path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            return nil
        }
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Constants.sampleRate), channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }

        do { try file.read(into: input) } catch { return nil }

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        converter.convert(to: output, error: nil) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
