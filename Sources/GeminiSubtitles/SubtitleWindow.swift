import AppKit

/// Floating, borderless, click-through-by-default-except-drag overlay that
/// shows the latest translated subtitle line. Visible across all Spaces,
/// auto-fades 4 s after the last update, draggable anywhere.
final class SubtitleWindow: NSPanel {

    private let fadeDelay: TimeInterval = 4.0
    private var fadeTimer: Timer?

    /// When true (default), the OSD is click-through so it never blocks the
    /// app underneath. When false, the window captures mouse events so the
    /// user can drag it via `isMovableByWindowBackground`.
    private(set) var locked = true

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

    /// Resize the OSD to fit a new font size, preserving the horizontal
    /// center. Height accommodates 2 wrapped translation lines plus an
    /// optional smaller original line above (bilingual mode); width scales
    /// with the font and is capped to leave margin on the screen.
    func resizeForFontSize(_ size: CGFloat) {
        let lineHeight = size * 1.4
        // 2 translation lines + 1 original line (~0.7×) + padding.
        let originalContribution = Int(size * 0.7 * 1.4)
        let newHeight = max(84, Int(lineHeight * 2 + 16) + originalContribution)
        let preferredWidth = Int(size * 36)   // ~ comfortable for a subtitle line
        let maxWidth: Int = {
            guard let screen = NSScreen.main else { return 1600 }
            return Int(screen.visibleFrame.width) - 100
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
}
