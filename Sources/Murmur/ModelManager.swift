import Foundation

struct WhisperModel: Identifiable, Equatable {
    let file: String
    let title: String
    let sizeMB: Int
    let note: String

    var id: String { file }
    var url: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!
    }
}

/// Finds, downloads, and selects Whisper models under
/// ~/Library/Application Support/Murmur/models.
final class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    static let catalog: [WhisperModel] = [
        WhisperModel(file: "ggml-base.en.bin", title: "Base (English)", sizeMB: 148,
                     note: "Fastest \u{2014} great for everyday dictation"),
        WhisperModel(file: "ggml-small.en.bin", title: "Small (English)", sizeMB: 488,
                     note: "Balanced speed and accuracy"),
        WhisperModel(file: "ggml-large-v3-turbo.bin", title: "Large v3 Turbo", sizeMB: 1624,
                     note: "Maximum accuracy, all languages"),
    ]

    // Preference order when the user picks "auto"
    private static let autoOrder = ["ggml-large-v3-turbo.bin", "ggml-small.en.bin", "ggml-base.en.bin"]

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var activeModelFile: String?

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session = URLSession(
        configuration: .default, delegate: self, delegateQueue: .main)

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/models", isDirectory: true)
    }

    override init() {
        super.init()
        try? FileManager.default.createDirectory(
            at: Self.modelsDirectory, withIntermediateDirectories: true)
        refreshInstalled()
    }

    func refreshInstalled() {
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: Self.modelsDirectory.path)) ?? []
        installed = Set(files.filter { $0.hasSuffix(".bin") })
    }

    /// Resolves the user's selection ("auto" or a filename) to a model path.
    func resolveSelectedModel() -> URL? {
        refreshInstalled()
        let selection = Prefs.defaults.string(forKey: PrefKey.selectedModel) ?? "auto"
        let file: String?
        if selection == "auto" {
            file = Self.autoOrder.first { installed.contains($0) } ?? installed.sorted().first
        } else if installed.contains(selection) {
            file = selection
        } else {
            file = Self.autoOrder.first { installed.contains($0) }
        }
        guard let file else { return nil }
        return Self.modelsDirectory.appendingPathComponent(file)
    }

    func loadSelectedModel() {
        guard let url = resolveSelectedModel() else {
            activeModelFile = nil
            return
        }
        guard url.lastPathComponent != WhisperEngine.shared.loadedModelPath.map({ ($0 as NSString).lastPathComponent }) else {
            activeModelFile = url.lastPathComponent
            return
        }
        WhisperEngine.shared.loadModel(at: url.path) { [weak self] ok in
            self?.activeModelFile = ok ? url.lastPathComponent : nil
        }
    }

    func download(_ model: WhisperModel) {
        guard downloadTasks[model.file] == nil else { return }
        let task = session.downloadTask(with: model.url)
        task.taskDescription = model.file
        downloadTasks[model.file] = task
        downloadProgress[model.file] = 0
        task.resume()
    }

    func cancelDownload(_ model: WhisperModel) {
        downloadTasks[model.file]?.cancel()
        downloadTasks[model.file] = nil
        downloadProgress[model.file] = nil
    }

    func remove(_ model: WhisperModel) {
        try? FileManager.default.removeItem(
            at: Self.modelsDirectory.appendingPathComponent(model.file))
        refreshInstalled()
        if activeModelFile == model.file { loadSelectedModel() }
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let file = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        downloadProgress[file] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let file = downloadTask.taskDescription else { return }
        let dest = Self.modelsDirectory.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let file = task.taskDescription else { return }
        downloadTasks[file] = nil
        downloadProgress[file] = nil
        refreshInstalled()
        if error == nil { loadSelectedModel() }
    }
}
