package com.gordonxc.geminisubtitles.android.overlay

import android.content.Context
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

    override fun reveal() {
        handler.post {
            if (isShowing) return@post
            val view = TextView(context).apply {
                setText("") 
                setTextColor(Color.WHITE)
                setBackgroundColor(0xAA000000.toInt())
                setPadding(24, 12, 24, 12)
                typeface = Typeface.SANS_SERIF
                gravity = Gravity.CENTER
                alpha = 1f
                // Add shadow for readability
                setShadowLayer(4f, 1f, 1f, Color.BLACK)
            }
            applyDragHandler(view)

            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                // Offset from bottom
                y = 100
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
            overlayView?.setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        }
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
