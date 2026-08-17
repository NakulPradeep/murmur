import Foundation

/// Downloads and tracks speech models.
///
/// Downloads land in a temporary file and are only moved into place once the
/// size checks out — a truncated file that looks installed would otherwise fail
/// to load with a confusing error every launch.
@MainActor
final class ModelStore: NSObject, ObservableObject {
    static let shared = ModelStore()

    struct Progress {
        var fraction: Double
        var received: Int64
        var expected: Int64

        var description: String {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return "\(f.string(fromByteCount: received)) of \(f.string(fromByteCount: expected))"
        }
    }

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var progress: [String: Progress] = [:]
    @Published private(set) var failures: [String: String] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        refresh()
    }

    func refresh() {
        installed = Set(ModelCatalog.installed.map(\.file))
    }

    func isDownloading(_ model: ModelDescriptor) -> Bool {
        progress[model.file] != nil
    }

    // MARK: - Downloading

    func download(_ model: ModelDescriptor) {
        guard tasks[model.file] == nil else { return }
        failures[model.file] = nil
        progress[model.file] = Progress(fraction: 0, received: 0, expected: model.sizeBytes)

        let task = session.downloadTask(with: model.downloadURL)
        task.taskDescription = model.file
        tasks[model.file] = task
        task.resume()
        Log.log("downloading \(model.file)")
    }

    func cancelDownload(_ model: ModelDescriptor) {
        tasks[model.file]?.cancel()
        tasks[model.file] = nil
        progress[model.file] = nil
    }

    func remove(_ model: ModelDescriptor) {
        try? FileManager.default.removeItem(at: ModelCatalog.localURL(for: model.file))
        refresh()
        // If the active model just went away, fall back to whatever is left.
        if EngineRouter.shared.loadedModel == model {
            EngineRouter.shared.activatePreferredModel()
        }
    }

    fileprivate func finish(file: String, tempURL: URL) {
        guard let model = ModelCatalog.descriptor(for: file) else { return }
        let destination = ModelCatalog.localURL(for: file)
        let fm = FileManager.default

        do {
            let size = (try fm.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
            guard size >= Int64(Double(model.sizeBytes) * 0.98) else {
                try? fm.removeItem(at: tempURL)
                failures[file] = "The download was incomplete. Try again."
                Log.log("download SHORT for \(file): \(size) of \(model.sizeBytes)")
                return
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: tempURL, to: destination)
            Log.log("installed \(file) (\(size) bytes)")
        } catch {
            failures[file] = error.localizedDescription
            Log.log("install FAILED for \(file): \(error.localizedDescription)")
        }
    }

    fileprivate func complete(file: String, error: Error?) {
        tasks[file] = nil
        progress[file] = nil
        refresh()

        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            failures[file] = error.localizedDescription
            Log.log("download FAILED for \(file): \(error.localizedDescription)")
            return
        }
        // A newly installed model becomes active if nothing else is loaded.
        if installed.contains(file), !EngineRouter.shared.isReady {
            EngineRouter.shared.activatePreferredModel()
        }
    }

    fileprivate func update(file: String, received: Int64, expected: Int64) {
        let total = expected > 0 ? expected : (ModelCatalog.descriptor(for: file)?.sizeBytes ?? 0)
        guard total > 0 else { return }
        progress[file] = Progress(
            fraction: min(1, Double(received) / Double(total)),
            received: received, expected: total)
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let file = downloadTask.taskDescription else { return }
        Task { @MainActor in
            self.update(file: file, received: totalBytesWritten,
                        expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let file = downloadTask.taskDescription else { return }
        // The delegate's temp file is deleted the moment this returns, so it has
        // to be moved somewhere durable synchronously — not inside a Task.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: location, to: staged)
        Task { @MainActor in self.finish(file: file, tempURL: staged) }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let file = task.taskDescription else { return }
        Task { @MainActor in self.complete(file: file, error: error) }
    }
}
