// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GeminiSubtitles",
    platforms: [
        .macOS(.v14)  // ScreenCaptureKit audio-only capture
    ],
    dependencies: [
        // Sparkle 2 — in-app self-update. Binary xcframework is distributed
        // via SPM; build.sh copies the framework into the .app bundle's
        // Contents/Frameworks/ after `swift build`.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "GeminiSubtitles",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/GeminiSubtitles",
            exclude: ["Assets/Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                // Sparkle.framework is embedded under Contents/Frameworks/.
                // @loader_path at runtime resolves to Contents/MacOS/, so the
                // parent-of-parent lands on Contents/Frameworks/ where dyld
                // finds the embedded framework.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../Frameworks",
                ])
            ]
        )
    ]
)
