// swift-tools-version: 6.0
import PackageDescription
import Foundation

let wc = "\(Context.packageDirectory)/vendor/whisper.cpp"

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CWhisper"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["CWhisper"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(wc)/build/src",
                    "-L\(wc)/build/ggml/src",
                    "-L\(wc)/build/ggml/src/ggml-metal",
                    "-L\(wc)/build/ggml/src/ggml-blas",
                    "-lwhisper", "-lparakeet",
                    "-lggml", "-lggml-base", "-lggml-cpu",
                    "-lggml-metal", "-lggml-blas",
                    "-lc++",
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
