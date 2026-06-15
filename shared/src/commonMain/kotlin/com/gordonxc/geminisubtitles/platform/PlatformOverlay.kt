package com.gordonxc.geminisubtitles.platform

/**
 * Platform-agnostic overlay display for subtitles.
 *
 * On Android: implemented via WindowManager + TYPE_APPLICATION_OVERLAY.
 * On macOS: implemented via NSWindow (future iOS would use a separate approach).
 */
interface PlatformOverlay {
    /** Show the overlay window. */
    fun reveal()
    /** Hide the overlay window. */
    fun hide()
    /** Update the displayed subtitle text. */
    fun updateText(text: String)
    /** Set the font size in points. */
    fun setFontSize(size: Float)
    /** Toggle between click-through (locked) and draggable (unlocked). Returns new locked state. */
    fun toggleLock(): Boolean
    /** Whether the overlay is currently locked (click-through). */
    val isLocked: Boolean
}
