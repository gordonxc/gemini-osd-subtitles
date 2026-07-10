package com.gordonxc.geminisubtitles

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Accumulates transcription fragments into a rolling 2-line display.
 *
 * Ported from Swift `SubtitleBuffer.swift`.
 *
 * Gemini sends short text fragments as they're spoken. We accumulate them
 * into "lines" and break a line when:
 *   - A sentence-ending punctuation mark is seen (CJK or Latin), OR
 *   - No new text has arrived for `pauseTimeout` seconds (speech pause)
 *
 * At most `maxLines` lines are visible at once. Older lines scroll off as
 * new ones arrive.
 */
class SubtitleBuffer {

    /** Called with the joined visible text (up to `maxLines` lines, "\n" separated). */
    var onUpdate: ((String) -> Unit)? = null

    /** Milliseconds of silence after which the current line is considered complete. */
    private val pauseTimeoutMs = 1500L  // 1.5 s

    /** Maximum number of lines shown simultaneously. */
    private val maxLines = 2

    private val sentenceEnders = charArrayOf(
        '。', '？', '！', '，', '、', '；', '：', '…',
        '.', '?', '!', ',', ';', ':', '\n'
    )

    private val displayed = mutableListOf<String>()
    @Volatile private var activeLine = false
    private var pauseJob: Job? = null

    /// Guards `displayed`, `activeLine`, and `pauseJob`. `append`/`reset` run
    /// on GeminiClient's receive dispatcher while the pause timer runs on
    /// `Dispatchers.Default`; without this lock the two can interleave and
    /// throw ConcurrentModificationException (or produce torn line state).
    private val lock = Any()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Append a new transcription fragment. Splits on any sentence-ender. */
    fun append(fragment: String) {
        synchronized(lock) {
            pauseJob?.cancel()

            for (ch in fragment) {
                if (!activeLine) {
                    displayed.add("")
                    if (displayed.size > maxLines) displayed.removeAt(0)
                    activeLine = true
                }
                displayed[displayed.lastIndex] = displayed[displayed.lastIndex] + ch
                if (ch in sentenceEnders) {
                    activeLine = false
                }
            }

            emit()
            schedulePauseTimer()
        }
    }

    /** Clear all state (used on stop). */
    fun reset() {
        synchronized(lock) {
            pauseJob?.cancel()
            displayed.clear()
            activeLine = false
            emit()
        }
    }

    fun destroy() {
        scope.cancel()
    }

    // MARK: Private

    private fun emit() {
        val text = displayed.joinToString("\n")
        onUpdate?.invoke(text)
    }

    private fun schedulePauseTimer() {
        pauseJob = scope.launch {
            delay(pauseTimeoutMs)
            // Pause detected — current line (if any) is now complete.
            synchronized(lock) { activeLine = false }
        }
    }
}
