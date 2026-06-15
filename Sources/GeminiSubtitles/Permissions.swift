import AppKit
import ScreenCaptureKit

/// Permission handling for ScreenCaptureKit (Screen Recording TCC category).
///
/// ScreenCaptureKit requires the "Screen Recording" TCC permission. There is
/// no synchronous preflight; calling `SCShareableContent.getCurrent` triggers
/// the system prompt on first use. The legacy `CGRequestScreenCaptureAccess`
/// is also called proactively at launch to seed the prompt.
enum Permissions {

    /// Preflight: returns true if Screen Recording permission is already granted.
    /// Calls `CGPreflightScreenCaptureAccess` (macOS 10.15+) — fast, no prompt.
    static func preflight() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Request permission. Triggers the system prompt if not yet decided.
    /// Returns true if already granted (the prompt is async and the result
    /// will come via the next SCShareableContent call).
    static func request() -> Bool {
        return CGRequestScreenCaptureAccess()
    }

    /// Deep-link to **Privacy & Security → Screen Recording**.
    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:"
        ]
        for spec in candidates {
            if let url = URL(string: spec), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
