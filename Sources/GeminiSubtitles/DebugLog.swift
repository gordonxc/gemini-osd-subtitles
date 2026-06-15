import Foundation

/// File-based debug logger. NSLog output is privacy-masked by macOS unified
/// logging, making on-device diagnosis nearly impossible. This writes plain
/// text to ~/Library/Logs/GeminiSubtitles.log so we can read it directly.
enum DebugLog {
    private static let queue = DispatchQueue(label: "gemini.debuglog")
    private static let url: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/GeminiSubtitles.log")
    }()

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let h = try? FileHandle(forWritingTo: url) {
                        h.seekToEndOfFile()
                        h.write(data)
                        try? h.close()
                    }
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}
