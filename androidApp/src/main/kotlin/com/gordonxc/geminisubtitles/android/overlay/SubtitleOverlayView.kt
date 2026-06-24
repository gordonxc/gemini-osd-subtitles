package com.gordonxc.geminisubtitles.android.overlay

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import com.gordonxc.geminisubtitles.platform.PlatformOverlay

/**
 * Floating subtitle overlay using WindowManager + TYPE_APPLICATION_OVERLAY.
 *
 * Android equivalent of macOS `SubtitleWindow.swift` + `SubtitleViewController.swift`.
 *
 * Features:
 * - Transparent background, semi-transparent text container
 * - Click-through when locked (FLAG_NOT_TOUCHABLE)
 * - Draggable when unlocked
 * - Auto-fade 4s after last update
 * - Dynamic font sizing
 *
 * OSD length cap (design Q3/Q5/Q6): width is fixed to `screen - 2×48dp`
 * capped at 1200pt so text wraps inside the screen; `maxLines` on the
 * OutlinedTextView is recomputed from available height so large fonts on
 * short screens shrink the line budget instead of overflowing. Native
 * `ellipsize = START` head-truncates when the budget is exceeded.
 */
class SubtitleOverlayView(
    private val context: Context,
) : PlatformOverlay {

    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())

    private var overlayView: TextView? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var isShowing = false
    @Volatile private var locked = true
    private var fontSize = 20f

    private val fadeRunnable = Runnable {
        overlayView?.animate()?.alpha(0f)?.setDuration(200)?.start()
    }

    override val isLocked: Boolean get() = locked

    // MARK: Geometry constants (OSD length cap — design Q5/Q6)

    /** Total horizontal margin (both sides). Matches Material Design edge spacing. */
    private val widthMarginDp = 48
    /** Hard ceiling on OSD width — past this, lines are hard to scan. */
    private val widthCeilingPt = 1200
    /** Vertical offset of the OSD's bottom edge above the screen bottom. */
    private val bottomOffsetPx = 100
    /** Top margin — OSD must not kiss the status bar / notch. */
    private val topMarginPx = 80
    /** Hard ceiling on line count. */
    private val absoluteMaxLines = 4

    private val density: Float get() = context.resources.displayMetrics.density
    private val screenWidthPx: Int get() = context.resources.displayMetrics.widthPixels
    private val screenHeightPx: Int get() = context.resources.displayMetrics.heightPixels

    override fun reveal() {
        handler.post {
            if (isShowing) return@post
            val view = OutlinedTextView(context).apply {
                setText("")
                setTextColor(Color.WHITE)
                strokeColor = Color.BLACK
                strokeWidthPx = 8f
                // No background — outline provides readability over any content.
                setPadding(24, 12, 24, 12)
                typeface = Typeface.SANS_SERIF
                gravity = Gravity.CENTER
                alpha = 1f
                // Apply the font size that was set before the view existed.
                setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize)
                // Push the dynamic line budget for the current screen + font.
                maxLines = computeMaxLines(fontSize)
            }
            applyDragHandler(view)

            val params = WindowManager.LayoutParams(
                computeWindowWidth(),
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                // Offset from bottom
                y = bottomOffsetPx
            }

            try {
                windowManager.addView(view, params)
                overlayView = view
                layoutParams = params
                isShowing = true
                setLocked(true)  // Start in click-through mode
                scheduleFade()
            } catch (e: Exception) {
                // TYPE_APPLICATION_OVERLAY not permitted
            }
        }
    }

    override fun hide() {
        handler.post {
            handler.removeCallbacks(fadeRunnable)
            overlayView?.let { v ->
                try { windowManager.removeView(v) } catch (_: Exception) {}
            }
            overlayView = null
            layoutParams = null
            isShowing = false
        }
    }

    override fun updateText(text: String) {
        handler.post {
            overlayView?.let { v ->
                v.text = text
                v.alpha = 1f
                v.visibility = if (text.isBlank()) View.INVISIBLE else View.VISIBLE
                handler.removeCallbacks(fadeRunnable)
                scheduleFade()
            }
        }
    }

    override fun setFontSize(size: Float) {
        fontSize = size
        handler.post {
            overlayView?.let { v ->
                v.setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
                v.maxLines = computeMaxLines(size)
            }
        }
    }

    /**
     * Call from the host (e.g. SubtitleService's `onConfigurationChanged`) when
     * the screen geometry changes (rotation, multi-window resize). Recomputes
     * the window width and per-line budget and reapplies them to the live view
     * so the OSD doesn't keep stale dimensions after rotation.
     */
    fun onConfigurationChanged(newConfig: Configuration) {
        handler.post {
            layoutParams?.let { params ->
                params.width = computeWindowWidth()
                overlayView?.let { v ->
                    v.maxLines = computeMaxLines(fontSize)
                    try { windowManager.updateViewLayout(v, params) } catch (_: Exception) {}
                }
            }
        }
    }

    // MARK: Geometry (design Q5/Q6)

    /**
     * Computes the OSD window width in px: `screenWidth − 2×48dp`, capped at
     * 1200pt (≈ 1200px on mdpi, scaled by density). Design Q5.
     */
    private fun computeWindowWidth(): Int {
        val marginPx = (widthMarginDp * density).toInt()
        val ceilingPx = (widthCeilingPt * density).toInt()
        val fromScreen = screenWidthPx - 2 * marginPx
        return minOf(fromScreen, ceilingPx).coerceAtLeast(0)
    }

    /**
     * Computes the dynamic line budget (design Q6). At most
     * [absoluteMaxLines]; fewer when the screen is short relative to the font
     * size so the OSD never overflows the top of the screen.
     */
    private fun computeMaxLines(fontSizeSp: Float): Int {
        // Estimate line height in px: font (sp → px) × 1.4 line-height factor.
        val lineSpacingFactor = 1.4f
        val fontPx = fontSizeSp * density
        val lineHeightPx = fontPx * lineSpacingFactor
        if (lineHeightPx <= 0f) return 1

        val availableHeightPx = (screenHeightPx - bottomOffsetPx - topMarginPx).coerceAtLeast(0)
        val fromHeight = (availableHeightPx / lineHeightPx).toInt()
        return fromHeight.coerceIn(1, absoluteMaxLines)
    }

    override fun toggleLock(): Boolean {
        setLocked(!locked)
        return locked
    }

    private fun setLocked(value: Boolean) {
        locked = value
        handler.post {
            layoutParams?.let { params ->
                if (locked) {
                    // Click-through: touch events pass to apps underneath
                    params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                } else {
                    // Draggable: receive touch events
                    params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
                }
                overlayView?.let { v ->
                    try { windowManager.updateViewLayout(v, params) } catch (_: Exception) {}
                }
            }
        }
    }

    private fun applyDragHandler(view: TextView) {
        var initialX = 0
        var initialY = 0
        var initialTouchX = 0f
        var initialTouchY = 0f
        var dragging = false

        view.setOnTouchListener { v, event ->
            if (locked) return@setOnTouchListener false
            layoutParams ?: return@setOnTouchListener false

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = layoutParams!!.x
                    initialY = layoutParams!!.y
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    dragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - initialTouchX
                    val dy = event.rawY - initialTouchY
                    if (dx * dx + dy * dy > 25) dragging = true  // 5px threshold
                    layoutParams!!.x = initialX + dx.toInt()
                    layoutParams!!.y = initialY - dy.toInt()  // invert Y (gravity BOTTOM)
                    try { windowManager.updateViewLayout(v, layoutParams) } catch (_: Exception) {}
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val wasDragging = dragging
                    dragging = false
                    wasDragging
                }
                else -> false
            }
        }
    }

    private fun scheduleFade() {
        handler.postDelayed(fadeRunnable, 4000)  // 4s auto-fade
    }
}
