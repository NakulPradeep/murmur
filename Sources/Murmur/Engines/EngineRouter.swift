import Foundation

/// Owns the live recognizer and serializes access to it.
///
/// Engines hold native contexts that are not safe to call concurrently, so every
/// decode runs on one queue. Model loading is queued behind in-flight decodes
/// for the same reason.
final class EngineRouter {
    static let shared = EngineRouter()

    private let queue = DispatchQueue(label: "murmur.engine", qos: .userInitiated)
    private let whisper = WhisperEngine()
    private let parakeet = ParakeetEngine()
    /// A second, independent Whisper used only to rescue utterances the primary
    /// engine rendered in the wrong script. Kept separate so loading it never
    /// disturbs whichever engine is primary.
    private let languageGuard = WhisperEngine()
    private var guardModel: ModelDescriptor?

    private let stateLock = NSLock()
    private var activeKind: EngineKind?
    private var activeModel: ModelDescriptor?
    private var loadError: String?

    /// Fired on the main queue whenever readiness changes.
    var onStateChange: (() -> Void)?

    private init() {}

    // MARK: - State

    private func engine(for kind: EngineKind) -> TranscriptionEngine {
        switch kind {
        case .whisper: return whisper
        case .parakeet: return parakeet
        }
    }

    var current: TranscriptionEngine? {
        guard let kind = stateLock.withLock({ activeKind }) else { return nil }
        let e = engine(for: kind)
        return e.isReady ? e : nil
    }

    var isReady: Bool { current != nil }
    var loadedModel: ModelDescriptor? { stateLock.withLock { activeModel } }
    var lastLoadError: String? { stateLock.withLock { loadError } }

    var statusDescription: String {
        if let model = loadedModel { return "\(model.title) — \(model.engine.displayName)" }
        if let err = lastLoadError { return err }
        return "No model loaded"
    }

    // MARK: - Loading

    /// Picks the best installed model unless the user pinned one.
    static func preferredModel() -> ModelDescriptor? {
        let installed = ModelCatalog.installed
        guard !installed.isEmpty else { return nil }
        let pinned = Prefs.selectedModel
        if pinned != "auto", let match = installed.first(where: { $0.file == pinned }) {
            return match
        }
        return installed.max { $0.autoRank < $1.autoRank }
    }

    /// Loads the preferred model if it is not already the active one.
    func activatePreferredModel(completion: ((Bool) -> Void)? = nil) {
        guard let model = Self.preferredModel() else {
            stateLock.withLock {
                activeKind = nil
                activeModel = nil
                loadError = "No model installed"
            }
            notify()
            completion?(false)
            return
        }
        activate(model, completion: completion)
    }

    func activate(_ model: ModelDescriptor, completion: ((Bool) -> Void)? = nil) {
        let alreadyLoaded = stateLock.withLock { activeModel == model }
        if alreadyLoaded, isReady {
            completion?(true)
            return
        }

        queue.async { [self] in
            // Only one engine stays resident; these models are large enough
            // that keeping both would cost gigabytes for no benefit.
            for kind in EngineKind.allCases where kind != model.engine {
                engine(for: kind).unload()
            }
            loadLanguageGuardIfNeeded(primary: model)

            let target = engine(for: model.engine)
            let path = ModelCatalog.localURL(for: model.file).path
            do {
                try target.load(modelPath: path)
                stateLock.withLock {
                    activeKind = model.engine
                    activeModel = model
                    loadError = nil
                }
                Log.log("engine active: \(model.engine.rawValue) / \(model.file)")
                notify()
                DispatchQueue.main.async { completion?(true) }
            } catch {
                stateLock.withLock {
                    activeKind = nil
                    activeModel = nil
                    loadError = error.localizedDescription
                }
                Log.log("engine load FAILED \(model.file): \(error.localizedDescription)")
                notify()
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    func shutdown() {
        queue.sync {
            whisper.unload()
            parakeet.unload()
            languageGuard.unload()
        }
    }

    // MARK: - Transcription

    /// Runs a decode off the main thread and calls back on the main queue.
    func transcribe(
        _ request: TranscriptionRequest,
        completion: @escaping (Result<TranscriptionResult, Error>) -> Void
    ) {
        queue.async { [self] in
            guard let engine = current else {
                DispatchQueue.main.async { completion(.failure(TranscriptionError.noModelLoaded)) }
                return
            }
            do {
                let result = rescueIfWrongScript(try engine.transcribe(request), request: request)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Synchronous variant for the command-line paths.
    func transcribeSync(_ request: TranscriptionRequest) throws -> TranscriptionResult {
        try queue.sync {
            guard let engine = current else { throw TranscriptionError.noModelLoaded }
            return rescueIfWrongScript(try engine.transcribe(request), request: request)
        }
    }

    /// Called when the spoken language changes: the guard depends on it, and
    /// the primary model may not need reloading.
    func languageDidChange() {
        queue.async { [self] in
            guard let model = stateLock.withLock({ activeModel }) else { return }
            loadLanguageGuardIfNeeded(primary: model)
        }
    }

    // MARK: - Wrong-script rescue

    /// Picks a Whisper model that can be pinned to `language`. English-only
    /// models are preferred when they fit, because the guard runs on the rescue
    /// path where being small and fast matters more than breadth.
    private static func guardModelFor(language: String) -> ModelDescriptor? {
        let installed = ModelCatalog.installed.filter { $0.engine == .whisper }
        guard !installed.isEmpty else { return nil }
        if language == "en" {
            let englishOnly = installed.filter { $0.file.contains(".en.") }
            if let smallest = englishOnly.min(by: { $0.sizeBytes < $1.sizeBytes }) {
                return smallest
            }
        }
        // Non-English needs a multilingual model.
        return installed.filter { !$0.file.contains(".en.") }
            .min { $0.sizeBytes < $1.sizeBytes } ?? installed.min { $0.sizeBytes < $1.sizeBytes }
    }

    /// The guard is only useful when the primary engine cannot be told what
    /// language to expect. Whisper takes a language parameter, so when it is
    /// primary there is nothing to rescue.
    private func loadLanguageGuardIfNeeded(primary: ModelDescriptor) {
        let language = Prefs.language
        guard primary.engine == .parakeet, language != "auto",
              let model = Self.guardModelFor(language: language) else {
            languageGuard.unload()
            guardModel = nil
            return
        }
        guard guardModel != model else { return }
        do {
            try languageGuard.load(modelPath: ModelCatalog.localURL(for: model.file).path)
            guardModel = model
            Log.log("language guard ready: \(model.file) pinned to \(language)")
        } catch {
            guardModel = nil
            Log.log("language guard unavailable: \(error.localizedDescription)")
        }
    }

    /// Re-decodes when the primary engine wrote the wrong script.
    private func rescueIfWrongScript(
        _ result: TranscriptionResult, request: TranscriptionRequest
    ) -> TranscriptionResult {
        let language = Prefs.language
        let expected = ScriptGuard.expectedScript(for: language)
        guard ScriptGuard.isWrongScript(result.text, expected: expected) else { return result }

        Log.log("wrong script from \(result.engineID) — re-decoding pinned to \(language)")
        guard languageGuard.isReady else {
            Log.log("no language guard installed; keeping the misdetected text")
            return result
        }
        var pinned = request
        pinned.language = language
        guard let rescued = try? languageGuard.transcribe(pinned),
              !rescued.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result
        }
        Log.log("rescued via \(rescued.modelName)")
        return rescued
    }

    private func notify() {
        DispatchQueue.main.async { self.onStateChange?() }
    }
}
