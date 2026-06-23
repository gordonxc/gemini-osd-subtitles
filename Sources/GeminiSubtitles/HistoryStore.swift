import Foundation

/// One finalised subtitle line plus its wall-clock timestamp.
struct HistoryEntry: Codable {
    let ts: Date
    let text: String
}

/// Lightweight metadata about a session file, derived from disk without
/// parsing the full JSONL (used to populate the History submenu).
struct SessionInfo {
    let url: URL
    let startedAt: Date
    /// ts of the last entry, or `startedAt` if the file has no entries yet.
    let lastEntryAt: Date
    let languageCode: String
    let entryCount: Int

    /// Wall-clock duration from the first entry to the last (or 0 if empty).
    var durationSeconds: TimeInterval {
        max(0, lastEntryAt.timeIntervalSince(startedAt))
    }
}

/// Owns the per-session JSONL history files.
///
/// One file per Start→Stop session, written to
/// `~/Library/Application Support/GeminiSubtitles/history/`. Each line is a
/// compact JSON object `{"ts":"…","text":"…"}` so the file is robust to
/// interrupted writes (one truncated line at most).
///
/// Sessions are never auto-deleted; the user clears them from the menu.
final class HistoryStore {

    /// Root directory for session files.
    static let directory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport
            .appendingPathComponent("GeminiSubtitles", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ISO 8601 with timezone offset, used for the `ts` field.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f
    }()

    /// Filename-friendly timestamp, e.g. `2026-06-23_143021`.
    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    /// Friendly label timestamp, e.g. `Jun 23, 14:30`.
    private static let labelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    /// Friendly HH:mm:ss for per-entry display in the viewer.
    private static let entryTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var currentFileHandle: FileHandle?
    private(set) var currentSessionURL: URL?
    private(set) var currentSessionStart: Date?
    private(set) var currentLanguageCode: String?
    private(set) var currentEntries: [HistoryEntry] = []

    /// Fires on the main thread whenever a new entry is appended to the
    /// current session. The viewer window subscribes to live-update.
    var onAppend: ((HistoryEntry) -> Void)?

    // MARK: Current session

    /// Open a new session file. Called from `AppCoordinator.start`.
    func beginSession(languageCode: String) {
        endSession()  // close any orphaned handle

        let now = Date()
        let filename = "\(Self.filenameFormatter.string(from: now))_\(languageCode).jsonl"
        let url = Self.directory.appendingPathComponent(filename)

        // Create the file (empty) so it exists on disk even if no entries
        // arrive before Stop.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        currentFileHandle = try? FileHandle(forWritingTo: url)
        currentSessionURL = url
        currentSessionStart = now
        currentLanguageCode = languageCode
        currentEntries = []
    }

    /// Append a finalised subtitle line. No-op if no session is open.
    /// Called from `AppCoordinator.scheduleTranscriptionUpdate`.
    func append(text: String) {
        guard let handle = currentFileHandle else { return }
        let entry = HistoryEntry(ts: Date(), text: text)
        currentEntries.append(entry)

        let payload: [String: Any] = [
            "ts": Self.isoFormatter.string(from: entry.ts),
            "text": entry.text,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           data.count > 0 {
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data([0x0A]))  // '\n'
        }

        if Thread.isMainThread {
            onAppend?(entry)
        } else {
            let cb = onAppend
            DispatchQueue.main.async { cb?(entry) }
        }
    }

    /// Close the current session file. Called from `AppCoordinator.stop`.
    func endSession() {
        try? currentFileHandle?.close()
        currentFileHandle = nil
        currentSessionURL = nil
        currentSessionStart = nil
        currentLanguageCode = nil
        currentEntries = []
    }

    // MARK: Listing / loading

    /// Returns the most recent `limit` session files, newest first.
    /// Includes the current session if one is open.
    func listRecentSessions(limit: Int = 10) -> [SessionInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let sorted = urls
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate) ?? .distantPast
                return l > r
            }
        return sorted.prefix(limit).map { info(for: $0) }
    }

    /// Parse a session file into entries. Skips malformed lines.
    func loadEntries(from url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var entries: [HistoryEntry] = []
        for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData)
                    as? [String: Any],
                  let tsStr = obj["ts"] as? String,
                  let ts = Self.isoFormatter.date(from: tsStr),
                  let text = obj["text"] as? String
            else { continue }
            entries.append(HistoryEntry(ts: ts, text: text))
        }
        return entries
    }

    /// Delete every session file. No confirmation here — caller prompts.
    func clearAll() {
        endSession()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        for url in urls where url.pathExtension.lowercased() == "jsonl" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Formatting helpers (used by viewer and menu)

    /// `"Jun 23, 14:30"` for the given session start date.
    static func label(forStartDate date: Date) -> String {
        labelFormatter.string(from: date)
    }

    /// `"14:30:21"` for the given entry timestamp.
    static func entryTime(_ date: Date) -> String {
        entryTimeFormatter.string(from: date)
    }

    /// `"5 min"` / `"45 s"` / `"0 s"` for a duration in seconds.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return "\(m / 60) hr \(m % 60) min"
    }

    /// `"Jun 23, 14:30 · 5 min · Cantonese"` used by the History submenu.
    static func menuLabel(for info: SessionInfo) -> String {
        let lang = Languages.name(forCode: info.languageCode)
        return "\(label(forStartDate: info.startedAt)) · \(formatDuration(info.durationSeconds)) · \(lang)"
    }

    // MARK: Private

    /// Derive `SessionInfo` from a session file by parsing it once.
    /// Filename convention: `2026-06-23_143021_<code>.jsonl`.
    private func info(for url: URL) -> SessionInfo {
        let entries = loadEntries(from: url)
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: true)
        // parts: ["2026-06-23", "143021", "<code>"] — but the date portion
        // itself contains dashes, not underscores, so split on the last
        // underscore only to extract the language code.
        let langCode: String = {
            if let underline = name.lastIndex(of: "_") {
                return String(name[name.index(after: underline)...])
            }
            return ""
        }()
        let startDate: Date = {
            // Reconstruct from the first two underscore-separated parts.
            let prefix = String(name.prefix(upTo: name.lastIndex(of: "_") ?? name.startIndex))
            // prefix looks like "2026-06-23_143021"
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.dateFormat = "yyyy-MM-dd_HHmmss"
            return df.date(from: prefix) ?? Date()
        }()
        let lastAt = entries.last?.ts ?? startDate
        _ = parts  // silence unused warning if extraction failed
        return SessionInfo(
            url: url,
            startedAt: startDate,
            lastEntryAt: lastAt,
            languageCode: langCode,
            entryCount: entries.count
        )
    }
}
