import XCTest

/// Source-invariant regression tests for the OSD window's AppKit flags.
///
/// These read `SubtitleWindow.swift` directly rather than instantiating it.
/// The OSD lives in an *executable* target, which SPM test targets can't
/// `@testable import`, and `SubtitleWindow.init()` needs a live `NSApp`
/// (it installs an event monitor and orders the window out). The invariant
/// these tests pin is easy to regress silently: the code compiles fine
/// without `.fullScreenAuxiliary`, but at runtime the OSD silently vanishes
/// behind any fullscreen app. Catching that requires a GUI + audio +
/// fullscreen-app session, so we guard the flag at the source level instead.
final class SubtitleWindowBehaviorTests: XCTestCase {

    /// Returns the contents of SubtitleWindow.swift. `swift test` runs with
    /// the package root as the working directory, so the relative path
    /// resolves regardless of where the test binary is invoked from.
    private func subtitleWindowSource() throws -> String {
        let url = URL(fileURLWithPath: "Sources/GeminiSubtitles/SubtitleWindow.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Extracts the array literal assigned to `collectionBehavior = [...]`
    /// in init(). Returns the substring between the `[` and its matching `]`.
    private func collectionBehaviorArray(in source: String) -> Substring? {
        guard let assign = source.range(of: "collectionBehavior = [") else {
            return nil
        }
        let afterBracket = source[assign.upperBound...]
        guard let close = afterBracket.firstIndex(of: "]") else {
            return nil
        }
        return afterBracket[..<close]
    }

    /// The OSD must render over fullscreen apps. `.canJoinAllSpaces` alone
    /// spans regular Spaces but NOT a fullscreen app's dedicated Space, so
    /// the overlay gets stranded on the desktop and hidden. `.fullScreenAuxiliary`
    /// is the AppKit flag that grants membership in fullscreen Spaces (the
    /// same mechanism system overlays use).
    func testCollectionBehaviorIncludesFullScreenAuxiliary() throws {
        let source = try subtitleWindowSource()
        let array = try XCTUnwrap(
            collectionBehaviorArray(in: source),
            "collectionBehavior = [...] assignment not found in SubtitleWindow.swift")
        XCTAssertTrue(
            array.contains(".fullScreenAuxiliary"),
            "SubtitleWindow.collectionBehavior must include .fullScreenAuxiliary so the " +
            "OSD renders over fullscreen apps. Found: \(array)")
        XCTAssertTrue(
            array.contains(".canJoinAllSpaces"),
            "SubtitleWindow.collectionBehavior must include .canJoinAllSpaces so the " +
            "OSD follows the user across Spaces. Found: \(array)")
    }

    /// `.stationary` keeps the OSD's frame stable when Spaces are switched;
    /// dropping it causes the window to animate/slide during Space changes,
    /// which looks broken for a persistent overlay. Pin it so a cleanup
    /// pass doesn't accidentally remove it.
    func testCollectionBehaviorIncludesStationary() throws {
        let source = try subtitleWindowSource()
        let array = try XCTUnwrap(
            collectionBehaviorArray(in: source),
            "collectionBehavior = [...] assignment not found in SubtitleWindow.swift")
        XCTAssertTrue(
            array.contains(".stationary"),
            "SubtitleWindow.collectionBehavior must include .stationary. Found: \(array)")
    }
}
