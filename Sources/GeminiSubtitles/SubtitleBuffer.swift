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
final class SubtitleBuffer {

    /// Called on the same thread that called `append(_:)`. Receives the
    /// joined visible text (up to `maxLines` lines, separated by "\n").
    var onUpdate: ((String) -> Void)?

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
    private var activeLine = false
    private var pauseTimer: Timer?

    /// Append a new transcription fragment. Splits on any sentence-ender
    /// contained within; the ender stays attached to its line.
    func append(_ fragment: String) {
        pauseTimer?.invalidate()

        for ch in fragment {
            if !activeLine {
                displayed.append("")
                if displayed.count > maxLines { displayed.removeFirst() }
                activeLine = true
            }
            displayed[displayed.count - 1].append(ch)
            if sentenceEnders.contains(ch) {
                activeLine = false
            }
        }

        emit()
        schedulePauseTimer()
    }

    /// Clear all state (used on stop).
    func reset() {
        pauseTimer?.invalidate()
        displayed.removeAll()
        activeLine = false
        emit()
    }

    // MARK: Private

    private func emit() {
        let text = displayed.joined(separator: "\n")
        onUpdate?(text)
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
