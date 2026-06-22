package com.gordonxc.geminisubtitles.android.overlay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.widget.TextView

/**
 * TextView subclass that draws text with a crisp outline (stroke) before the
 * fill, so the subtitle is readable over arbitrary backgrounds without needing
 * a semi-transparent container.
 *
 * Used by [SubtitleOverlayView] in place of a plain TextView.
 */
class OutlinedTextView(context: Context) : TextView(context) {

    var strokeColor: Int = Color.BLACK
    var strokeWidthPx: Float = 8f

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
}
