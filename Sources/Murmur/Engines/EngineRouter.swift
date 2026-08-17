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
                let result = try engine.transcribe(request)
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
            return try engine.transcribe(request)
        }
    }

    private func notify() {
        DispatchQueue.main.async { self.onStateChange?() }
    }
}
