import Foundation

enum EngineKind: String, Codable, CaseIterable {
    case whisper
    case parakeet

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }
}

struct ModelDescriptor: Identifiable, Equatable, Hashable {
    let file: String
    let title: String
    let engine: EngineKind
    let sizeBytes: Int64
    let downloadURL: URL
    /// One line on what this model is good for.
    let note: String
    let languages: String
    /// Higher wins when the user has not picked a model explicitly.
    let autoRank: Int

    var id: String { file }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum ModelCatalog {
    private static func hf(_ repo: String, _ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
    }

    static let all: [ModelDescriptor] = [
        ModelDescriptor(
            file: "ggml-parakeet-tdt-0.6b-v3-f16.bin",
            title: "Parakeet v3",
            engine: .parakeet,
            sizeBytes: 1_255_897_319,
            downloadURL: hf("ggml-org/parakeet-GGUF", "ggml-parakeet-tdt-0.6b-v3-f16.bin"),
            note: "Best accuracy and by far the fastest. Does not hallucinate on silence.",
            languages: "25 European languages",
            autoRank: 100),

        ModelDescriptor(
            file: "ggml-large-v3-turbo.bin",
            title: "Whisper Large v3 Turbo",
            engine: .whisper,
            sizeBytes: 1_624_555_275,
            downloadURL: hf("ggerganov/whisper.cpp", "ggml-large-v3-turbo.bin"),
            note: "Very accurate, understands custom vocabulary hints.",
            languages: "99 languages",
            autoRank: 80),

        ModelDescriptor(
            file: "ggml-small.en.bin",
            title: "Whisper Small (English)",
            engine: .whisper,
            sizeBytes: 487_601_967,
            downloadURL: hf("ggerganov/whisper.cpp", "ggml-small.en.bin"),
            note: "Balanced accuracy and footprint.",
            languages: "English",
            autoRank: 40),

        ModelDescriptor(
            file: "ggml-base.en.bin",
            title: "Whisper Base (English)",
            engine: .whisper,
            sizeBytes: 147_964_211,
            downloadURL: hf("ggerganov/whisper.cpp", "ggml-base.en.bin"),
            note: "Smallest and quickest to download; weakest on names and jargon.",
            languages: "English",
            autoRank: 20),
    ]

    static func descriptor(for file: String) -> ModelDescriptor? {
        all.first { $0.file == file }
    }

    /// Where models live. Kept out of the bundle so rebuilds never re-download.
    static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Murmur/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func localURL(for file: String) -> URL {
        directory.appendingPathComponent(file)
    }

    /// A model counts as installed only when the file is on disk at roughly the
    /// expected size — a half-finished download would otherwise look valid and
    /// then fail to load.
    static func isInstalled(_ model: ModelDescriptor) -> Bool {
        let url = localURL(for: model.file)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size >= Int64(Double(model.sizeBytes) * 0.98)
    }

    static var installed: [ModelDescriptor] {
        all.filter(isInstalled)
    }
}
