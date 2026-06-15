// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GeminiSubtitles",
    platforms: [
        .macOS(.v14)  // ScreenCaptureKit audio-only capture
    ],
    targets: [
        .executableTarget(
            name: "GeminiSubtitles",
            path: "Sources/GeminiSubtitles",
            exclude: ["Assets/Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia")
            ]
        )
    ]
)

