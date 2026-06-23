import Foundation

/// Renders an array of `HistoryEntry` to one of three export formats.
enum HistoryExporter {

    enum Format: String, CaseIterable {
        case txt
        case srt
        case json

        var displayName: String {
            switch self {
            case .txt:  return "Plain Text (.txt)"
            case .srt:  return "SubRip (.srt)"
            case .json: return "JSON (.json)"
            }
        }

        /// Suggested filename extension for `NSSavePanel`.
        var fileExtension: String { rawValue }
    }

    /// Produce the export data for the given format.
    static func render(_ entries: [HistoryEntry], format: Format) -> Data {
        switch format {
        case .txt:  return renderTxt(entries)
        case .srt:  return renderSrt(entries)
        case .json: return renderJson(entries)
        }
    }

    // MARK: txt — `[HH:mm:ss] text` per line

    private static func renderTxt(_ entries: [HistoryEntry]) -> Data {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "HH:mm:ss"
        let body = entries
            .map { "[\(df.string(from: $0.ts))] \($0.text)" }
            .joined(separator: "\n")
        return (body + "\n").data(using: .utf8) ?? Data()
    }

    // MARK: srt — standard SubRip; duration = current → next entry ts
    // (+3 s tail for the last line)

    private static func renderSrt(_ entries: [HistoryEntry]) -> Data {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "HH:mm:ss,SSS"

        var out = ""
        for (idx, entry) in entries.enumerated() {
            let start = entry.ts
            let end: Date = {
                if let next = entries[safe: idx + 1] {
                    return next.ts
                }
                return entry.ts.addingTimeInterval(3.0)
            }()
            out += "\(idx + 1)\n"
            out += "\(df.string(from: start)) --> \(df.string(from: end))\n"
            out += "\(entry.text)\n\n"
        }
        return out.data(using: .utf8) ?? Data()
    }

    // MARK: json — array of {ts, text} with ISO timestamps

    private static func renderJson(_ entries: [HistoryEntry]) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let payload: [[String: String]] = entries.map {
            ["ts": iso.string(from: $0.ts), "text": $0.text]
        }
        return (try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
