// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IrodoriTTS",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "IrodoriTTS", targets: ["IrodoriTTS"]),
        .executable(name: "irodori", targets: ["IrodoriCLI"]),
    ],
    targets: [
        .target(name: "IrodoriNative", publicHeadersPath: "include",
                cxxSettings: [.define("IRODORI_COREML_ONLY", to: "1")],
                linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("CoreML"),
                                 .linkedFramework("Accelerate")]),
        .target(name: "IrodoriTTS", dependencies: ["IrodoriNative"],
                linkerSettings: [.linkedFramework("AVFoundation")]),
        .executableTarget(name: "IrodoriCLI", dependencies: ["IrodoriTTS"]),
        .testTarget(name: "IrodoriTTSTests", dependencies: ["IrodoriTTS"]),
    ],
    cxxLanguageStandard: .cxx17
)
