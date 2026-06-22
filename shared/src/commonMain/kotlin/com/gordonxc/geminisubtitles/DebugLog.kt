package com.gordonxc.geminisubtitles

/**
 * Debug logger. Platform-specific implementation via expect/actual.
 * Ported from Swift `DebugLog.swift`.
 */
expect object DebugLog {
    fun write(message: String)
}
