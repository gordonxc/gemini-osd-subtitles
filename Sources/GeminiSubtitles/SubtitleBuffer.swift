import Foundation

/// Accumulates transcription fragments into a rolling 2-line display.
///
/// Gemini sends short text fragments as they're spoken. We accumulate them
/// into "lines" and break a line when:
///   - A sentence-ending punctuation mark is seen (CJK or Latin), OR
///   - No new text has arrived for `pauseTimeout` seconds (speech pause)
///
/// At most `maxLines` lines are visible at once. Older lines scroll off as
/// new ones arrive. The output is a newline-joined string passed to
/// `onUpdate`.
///
/// In bilingual mode the source-language (original) transcript is tracked in
/// a parallel buffer with the same splitting rules, so the OSD can show
/// original + translation line-by-line.
final class SubtitleBuffer {

    /// Called on the same thread that called `append(_:)`. Receives the
    /// joined visible translation text (up to `maxLines` lines, separated
    /// by "\n") and, in bilingual mode, the joined original text (same
    /// line breaks). `original` is nil when bilingual mode is off.
    var onUpdate: ((String, String?) -> Void)?

    /// Seconds of silence after which the current line is considered complete.
    private let pauseTimeout: TimeInterval = 1.5

    /// Maximum number of lines shown simultaneously.
    private let maxLines = 2

    /// Characters that terminate a line. Includes CJK + Latin sentence and
    /// clause enders (the user said 標點符號 generally, so we split on all
    /// of them rather than just full stops).
    private let sentenceEnders: Set<Character> = [
        "。", "？", "！", "，", "、", "；", "：", "…",
        ".", "?", "!", ",", ";", ":", "\n"
    ]

    /// Currently visible lines. The last entry is "active" (accepts more
    /// fragments) while `activeLine` is true.
    private var displayed: [String] = []
    /// Parallel to `displayed` — the source-language original per line.
    /// Kept in sync by feeding the same splits into both accumulators.
    private var originals: [String] = []
    private var activeLine = false
    private var pauseTimer: Timer?

    /// Append a new transcription fragment. Splits on any sentence-ender
    /// contained within; the ender stays attached to its line.
    /// `original` is the source-language fragment when bilingual mode is on;
    /// it's appended verbatim to the active original line so the two streams
    /// scroll in lockstep.
    func append(_ fragment: String, original: String? = nil) {
        pauseTimer?.invalidate()

        for ch in fragment {
            if !activeLine {
                displayed.append("")
                originals.append("")
                if displayed.count > maxLines {
                    displayed.removeFirst()
                    originals.removeFirst()
                }
                activeLine = true
            }
            displayed[displayed.count - 1].append(ch)
            if sentenceEnders.contains(ch) {
                activeLine = false
            }
        }

        // Append the source fragment to the active original line. We don't
        // try to mirror the translation's per-character splits into the
        // original — the two languages rarely share punctuation positions,
        // so per-character mirroring produces garbage. Instead the original
        // accumulates on the active line and is shown above the matching
        // translation line.
        if let original = original, !original.isEmpty {
            if originals.isEmpty {
                originals.append("")
            }
            originals[originals.count - 1].append(original)
        }

        emit()
        schedulePauseTimer()
    }

    /// Clear all state (used on stop).
    func reset() {
        pauseTimer?.invalidate()
        displayed.removeAll()
        originals.removeAll()
        activeLine = false
        emit()
    }

    // MARK: Private

    private func emit() {
        let text = displayed.joined(separator: "\n")
        // Only surface originals if at least one line has source text.
        let joinedOriginals = originals.joined(separator: "\n")
        let originalOut: String? = joinedOriginals.isEmpty ? nil : joinedOriginals
        onUpdate?(text, originalOut)
    }

    private func schedulePauseTimer() {
        let timer = Timer(timeInterval: pauseTimeout, repeats: false) { [weak self] _ in
            // Pause detected — current line (if any) is now complete.
            self?.activeLine = false
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }
}
