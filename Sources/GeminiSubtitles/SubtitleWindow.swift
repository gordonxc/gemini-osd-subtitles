import AppKit

/// Floating, borderless, click-through-by-default-except-drag overlay that
/// shows the latest translated subtitle line. Visible across all Spaces,
/// auto-fades 4 s after the last update, draggable anywhere.
final class SubtitleWindow: NSPanel {

    private let fadeDelay: TimeInterval = 4.0
    private var fadeTimer: Timer?

    /// Local monitor for left-mouse-up events; used to detect drag end.
    /// `NSWindow` has `didEndLiveResizeNotification` but no equivalent for
    /// move, and `didMoveNotification` fires per-frame during a drag (which
    /// would fight the cursor if we clamped there). Mouse-up is the only
    /// reliable "drag is over" signal.
    private var mouseUpMonitor: Any?

    /// When true (default), the OSD is click-through so it never blocks the
    /// app underneath. When false, the window captures mouse events so the
    /// user can drag it via `isMovableByWindowBackground`.
    private(set) var locked = true

    // MARK: Geometry constants (OSD length cap — see design Q5/Q6)

    /// Hard ceiling on translation line count. From design Q3.
    private static let absoluteMaxTranslationLines = 4
    /// Hard ceiling on original (bilingual) line count. From design Q8.
    private static let absoluteMaxOriginalLines = 2
    /// Vertical offset of the OSD's bottom edge above the visible-frame
    /// bottom. Matches `reposition()`'s anchor.
    private static let bottomAnchor: CGFloat = 120
    /// Top margin — OSD must not touch the menu bar / notch.
    private static let topMargin: CGFloat = 50
    /// Internal vertical padding inside the OSD (above + below text).
    private static let padding: CGFloat = 16
    /// Width ceiling — past this, lines are hard to scan. From design Q5.
    private static let widthCeiling: CGFloat = 1200
    /// Total horizontal margin (both sides combined). From design Q5.
    private static let widthMargin: CGFloat = 100

    /// Last-computed line caps for the current font + screen. Read by the
    /// view controller when applying font size so each field's
    /// `maximumNumberOfLines` matches the geometry budget. Recomputed in
    /// `resizeForFontSize`.
    private(set) var translationMaxLines: Int = 4
    private(set) var originalMaxLines: Int = 2

    init() {
        // `.nonactivatingPanel` keeps the panel from stealing focus from the
        // app the user is in; combined with `.borderless` it draws no chrome.
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        // Default frame is recomputed in `reposition()`. Tall enough for 2 lines.
        let rect = NSRect(x: 0, y: 0, width: 720, height: 84)
        super.init(contentRect: rect,
                   styleMask: styleMask,
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Locked by default: click-through so the OSD never blocks the app
        // underneath. Unlocked via the menu toggle to allow dragging.
        ignoresMouseEvents = true

        let viewController = SubtitleViewController()
        contentViewController = viewController

        reposition()
        alphaValue = 0.0  // hidden until first update
        orderOut(nil)

        // Drag clamp (design Q7): when the user finishes dragging, snap the
        // frame back inside the visible frame if any edge is off-screen.
        // NSWindow has didEndLiveResizeNotification but no equivalent for
        // move; didMoveNotification fires per-frame during the drag and would
        // fight the cursor if we clamped there. A local mouse-up monitor is
        // the only reliable "drag is over" signal.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            // Only clamp when the event is destined for this window — the
            // monitor fires for every left-mouse-up in the app.
            if event.window === self {
                self?.clampFrameToScreen(animated: true)
            }
            return event
        }
        // Recompute geometry if the display layout changes (external display
        // attach/detach, resolution change, menu bar height change).
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    var subtitleView: SubtitleViewController? {
        contentViewController as? SubtitleViewController
    }

    /// Show/update the current line. Resets the auto-fade timer.
    /// `original` carries the source-language line when bilingual mode is on;
    /// pass nil to hide the original line.
    func update(text: String, isFinal: Bool, original: String? = nil) {
        guard let subtitleView else { return }
        subtitleView.update(text: text, original: original)

        if alphaValue < 1.0 {
            // Fade in.
            animator().alphaValue = 1.0
        }

        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: fadeDelay, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    func reveal() {
        if !isVisible {
            orderFrontRegardless()
        }
        alphaValue = 1.0
    }

    func hide() {
        fadeTimer?.invalidate()
        orderOut(nil)
        alphaValue = 0.0
        subtitleView?.update(text: "", original: nil)
    }

    /// Allow dragging the OSD. Cancels any pending fade so the user can see
    /// what they're grabbing; auto-fade resumes on next subtitle update.
    func unlock() {
        locked = false
        ignoresMouseEvents = false
        fadeTimer?.invalidate()
        if isVisible {
            animator().alphaValue = 1.0
        } else {
            orderFrontRegardless()
            alphaValue = 1.0
        }
    }

    /// Resume click-through behavior. Position is preserved.
    func lock() {
        locked = true
        ignoresMouseEvents = true
    }

    /// Resize the OSD for a new font size, recomputing the dynamic line
    /// budget (design Q6) and applying the 1200pt width ceiling (design Q5).
    ///
    /// Per design Q10 (fixed allocation), the window always sizes for the
    /// *maximum* line budget at the current font — empty space is transparent
    /// so a short subtitle doesn't visually shrink the OSD.
    ///
    /// Per design Q8 (translation wins), the translation field gets up to 4
    /// lines first; the original field gets only the leftover height (capped
    /// at 2), and hides entirely if there's no room.
    func resizeForFontSize(_ size: CGFloat) {
        let translationLineHeight = size * 1.4
        let originalLineHeight = size * 0.7 * 1.4

        // Available vertical space from the bottom anchor to a top margin.
        let availableHeight: CGFloat = {
            guard let screen = NSScreen.main else { return 600 }
            return screen.visibleFrame.height
                - SubtitleWindow.bottomAnchor
                - SubtitleWindow.topMargin
        }()

        // Translation wins: up to 4 lines, capped by available height.
        let translationFromHeight = Int(floor(
            max(0, availableHeight - SubtitleWindow.padding) / translationLineHeight))
        translationMaxLines = max(1, min(
            SubtitleWindow.absoluteMaxTranslationLines, translationFromHeight))

        // Original gets the leftover, up to 2 lines. 0 = hide entirely.
        let leftover = max(0,
            availableHeight - SubtitleWindow.padding
            - CGFloat(translationMaxLines) * translationLineHeight)
        let originalFromLeftover = Int(floor(leftover / originalLineHeight))
        originalMaxLines = max(0, min(
            SubtitleWindow.absoluteMaxOriginalLines, originalFromLeftover))

        // Window height: always allocate for the max-case (fixed-allocation
        // policy, Q10) so text updates don't trigger layout passes.
        let translationHeight = CGFloat(translationMaxLines) * translationLineHeight
        let originalHeight = CGFloat(originalMaxLines) * originalLineHeight
        let newHeight = max(84,
            Int(translationHeight + originalHeight + SubtitleWindow.padding))

        // Width: screen-relative with margin, capped at 1200pt (Q5).
        let preferredWidth = Int(size * 36)
        let maxWidth: Int = {
            guard let screen = NSScreen.main else { return 1600 }
            let screenMax = Int(screen.visibleFrame.width) - Int(SubtitleWindow.widthMargin)
            return min(screenMax, Int(SubtitleWindow.widthCeiling))
        }()
        let newWidth = max(720, min(preferredWidth, maxWidth))

        var frame = self.frame
        // Preserve horizontal center; keep vertical position.
        let oldCenterX = frame.midX
        frame.size = NSSize(width: newWidth, height: newHeight)
        frame.origin.x = oldCenterX - CGFloat(newWidth) / 2.0
        setFrame(frame, display: true, animate: false)

        // Update the content view's size to match so layout re-flows.
        contentViewController?.view.frame = NSRect(origin: .zero, size: frame.size)

        // Push the new line caps to the fields so wrapping + head-truncation
        // use the same budget as the window geometry.
        subtitleView?.applyLineCaps(
            translation: translationMaxLines, original: originalMaxLines)

        // Clamp in case the new (taller) frame extends past the top of the
        // visible frame — e.g. when the user previously dragged the OSD up
        // and then cranked the font size. Matches screenParametersChanged.
        clampFrameToScreen(animated: false)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 0.0
        }
    }

    /// Center horizontally on the main screen, anchored ~120 px above the
    /// bottom of the visible frame.
    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = self.frame.size
        let x = visible.minX + (visible.width - size.width) / 2.0
        let y = visible.minY + 120
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Drag clamp (design Q7)

    @objc private func screenParametersChanged(_ note: Notification) {
        // Display layout changed — recompute the line budget for the current
        // font size and re-clamp the position to the new visible frame.
        let size = subtitleView?.currentFontSize ?? SubtitleViewController.defaultSize
        resizeForFontSize(size)
        clampFrameToScreen(animated: false)
    }

    /// Snap the frame back inside the visible frame if any edge is off-screen.
    /// If the window's center has been dragged entirely off-screen (rare but
    /// possible via multi-display layouts), reset to the default anchor.
    private func clampFrameToScreen(animated: Bool) {
        guard let screen = screenContainingCenter ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = self.frame

        // Center fully off-screen → reset to default position.
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if !visible.contains(center) {
            frame.origin.x = visible.minX + (visible.width - frame.width) / 2.0
            frame.origin.y = visible.minY + SubtitleWindow.bottomAnchor
            setFrame(frame, display: true, animate: animated)
            return
        }

        var moved = false
        if frame.maxX > visible.maxX {
            frame.origin.x = visible.maxX - frame.width; moved = true
        }
        if frame.minX < visible.minX {
            frame.origin.x = visible.minX; moved = true
        }
        if frame.maxY > visible.maxY {
            frame.origin.y = visible.maxY - frame.height; moved = true
        }
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY; moved = true
        }
        if moved {
            setFrame(frame, display: true, animate: animated)
        }
    }

    /// Returns the screen whose frame contains this window's center, if any.
    private var screenContainingCenter: NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }
}
