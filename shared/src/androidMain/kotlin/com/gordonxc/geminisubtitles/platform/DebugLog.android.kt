package com.gordonxc.geminisubtitles

import android.util.Log

/**
 * Android implementation of DebugLog.
 * Uses logcat (tag: GeminiSubtitles) — the standard Android logging path.
 */
actual object DebugLog {
    private const val TAG = "GeminiSubtitles"

    actual fun write(message: String) {
        Log.d(TAG, message)
    }
}
