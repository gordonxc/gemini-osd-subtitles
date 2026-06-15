package com.gordonxc.geminisubtitles.platform

/** Platform-agnostic notification manager for critical errors. */
interface PlatformNotifier {
    fun notify(title: String, body: String)
}
