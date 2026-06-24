package com.gordonxc.geminisubtitles.android.overlay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.text.TextUtils
import android.util.TypedValue
import android.widget.TextView

/**
 * TextView subclass that draws text with a crisp outline (stroke) before the
 * fill, so the subtitle is readable over arbitrary backgrounds without needing
 * a semi-transparent container.
 *
 * Used by [SubtitleOverlayView] in place of a plain TextView.
 *
 * OSD length cap (design Q3): `maxLines` and `ellipsize = START` give us
 * native head-truncation. Unlike AppKit's NSTextField, Android's TextView
 * correctly handles `maxLines + ellipsize = START` for multi-line wrapped
 * text (verified on API 29+), so no manual measure-then-chop pass is needed
 * here — the platform does it for us.
 */
class OutlinedTextView(context: Context) : TextView(context) {

    var strokeColor: Int = Color.BLACK
    var strokeWidthPx: Float = 8f

    init {
        // Design Q3: cap at the dynamic line budget and head-truncate when
        // exceeded. The actual maxLines value is pushed from
        // SubtitleOverlayView whenever the screen geometry changes; this
        // default just sets a sane initial value.
        maxLines = DEFAULT_MAX_LINES
        ellipsize = TextUtils.TruncateAt.START
    }

    override fun onDraw(canvas: Canvas) {
        val originalColor = currentTextColor
        // Pass 1: stroke. setTextColor() (not paint.color=) because TextView
        // resets mTextPaint.color from mTextColor inside onDraw.
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = strokeWidthPx
        setTextColor(strokeColor)
        super.onDraw(canvas)
        // Pass 2: fill with the real text color.
        paint.style = Paint.Style.FILL
        setTextColor(originalColor)
        super.onDraw(canvas)
    }

    companion object {
        private const val DEFAULT_MAX_LINES = 4
    }
}
