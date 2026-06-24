import AppKit

/// Renders subtitle text centered in the OSD window. White text + soft black
/// drop shadow for readability on any background.
///
/// In bilingual mode the original (source-language) transcript is shown on a
/// smaller, light-gray line above the translation.
///
/// OSD length cap (design Q3/Q4/Q9): both fields wrap-and-head-truncate to
/// stay within a visual line budget computed by `SubtitleWindow`. Head-
/// truncation (chop leading characters, prepend "…") keeps the most recent
/// words visible — the part of a long sentence the user is currently reading.
final class SubtitleViewController: NSViewController {

    private let textField = NSTextField(labelWithString: "")
    private let originalField = NSTextField(labelWithString: "")

    /// Default point size. Overridden at runtime via `applyFontSize`.
    static var defaultSize: CGFloat = 20
    /// The original line is rendered at this ratio of the main size.
    private let originalSizeRatio: CGFloat = 0.7

    /// Current font size, tracked so the window can recompute geometry on
    /// screen-parameter changes without a separate store.
    private(set) var currentFontSize: CGFloat = SubtitleViewController.defaultSize

    /// Current line budget. Pushed by `SubtitleWindow.resizeForFontSize`.
    /// Defaults match the resting 4/2 caps; the window tightens them when
    /// the screen is short relative to the font size.
    private var translationLineCap: Int = 4
    private var originalLineCap: Int = 2

    override func loadView() {
        // Sizing is owned by the window; the controller just fills it.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 84))
        container.translatesAutoresizingMaskIntoConstraints = false

        configureField(textField, size: SubtitleViewController.defaultSize, color: .white)
        configureField(originalField,
                       size: SubtitleViewController.defaultSize * originalSizeRatio,
                       color: NSColor.white.withAlphaComponent(0.6))

        container.addSubview(textField)
        container.addSubview(originalField)

        // Layout stack (top → bottom): originalField, textField. Both are
        // horizontally pinned with 12 pt insets. The pair is centered
        // vertically inside the container.
        NSLayoutConstraint.activate([
            originalField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            originalField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            originalField.bottomAnchor.constraint(equalTo: textField.topAnchor, constant: -2),
        ])

        // Original hidden until first non-empty payload (or when its line
        // budget is 0 — translation-wins policy from design Q8).
        originalField.isHidden = true

        self.view = container
    }

    private func configureField(_ field: NSTextField, size: CGFloat, color: NSColor) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.alignment = .center
        field.font = NSFont.systemFont(ofSize: size, weight: .medium)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 2
        field.cell?.truncatesLastVisibleLine = true
        field.cell?.wraps = true

        // Drop shadow so text reads on both light and dark backgrounds.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: 0)
        field.shadow = shadow
    }

    /// Single-line interim replace: each update overwrites the prior text.
    /// `original` is the source-language line (bilingual mode); pass nil to
    /// hide the original line.
    ///
    /// Both fields pass through `headTruncate` so a long payload is chopped
    /// to the field's current line cap before being assigned. The chopping
    /// runs on every update but is cheap (see `lineCount`).
    func update(text: String, original: String?) {
        textField.maximumNumberOfLines = translationLineCap
        textField.stringValue = headTruncate(text, for: textField)

        let canShowOriginal = originalLineCap > 0
        if let original = original, !original.isEmpty, canShowOriginal {
            originalField.maximumNumberOfLines = max(1, originalLineCap)
            originalField.stringValue = headTruncate(original, for: originalField)
            originalField.isHidden = false
        } else {
            originalField.isHidden = true
        }
    }

    /// Apply a new font size to the subtitle text. The original line scales
    /// proportionally.
    func applyFontSize(_ size: CGFloat) {
        currentFontSize = size
        textField.font = NSFont.systemFont(ofSize: size, weight: .medium)
        originalField.font = NSFont.systemFont(ofSize: size * originalSizeRatio, weight: .medium)
    }

    /// Push new line caps from the window. Called whenever the geometry
    /// budget is recomputed (font change, screen-parameter change).
    func applyLineCaps(translation: Int, original: Int) {
        translationLineCap = max(1, translation)
        originalLineCap = max(0, original)
        // Apply immediately so the next render reflects the new caps even
        // if no text update arrives (e.g. user just shrunk the window).
        textField.maximumNumberOfLines = translationLineCap
        originalField.maximumNumberOfLines = max(1, originalLineCap)
        if originalLineCap == 0 {
            originalField.isHidden = true
        }
    }

    // MARK: Head truncation (design Q3/Q4)

    /// If `text` laid out at the field's font and width exceeds the field's
    /// `maximumNumberOfLines`, drop leading characters and prepend "…" until
    /// it fits. Returns the original string unchanged when it already fits.
    private func headTruncate(_ text: String, for field: NSTextField) -> String {
        guard !text.isEmpty,
              let font = field.font,
              field.bounds.width > 0,
              field.maximumNumberOfLines > 0
        else { return text }

        let maxLines = field.maximumNumberOfLines
        if lineCount(text, font: font, width: field.bounds.width) <= maxLines {
            return text
        }

        // Iteratively chop the head. Step size scales with how badly we're
        // over budget so long strings converge in a handful of iterations
        // rather than character-by-character.
        var working = text
        let ellipsis = "…"
        while !working.isEmpty {
            let measured = lineCount(ellipsis + working, font: font, width: field.bounds.width)
            if measured <= maxLines { return ellipsis + working }

            let currentLines = max(1, lineCount(working, font: font, width: field.bounds.width))
            // Over-ratio > 1 — drop proportionally.
            let dropFraction = (Double(currentLines) - Double(maxLines)) / Double(currentLines)
            let dropCount = max(1, Int(Double(working.count) * max(0.05, dropFraction)))
            let endIdx = working.index(working.startIndex,
                                       offsetBy: min(dropCount, working.count))
            working = String(working[endIdx...])
        }
        return ellipsis
    }

    /// Estimates the number of wrapped lines `text` will occupy at `font`
    /// inside `width`. Uses NSString.boundingRect — cheap, no full layout.
    private func lineCount(_ text: String, font: NSFont, width: CGFloat) -> Int {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes)
        let lineHeight = font.boundingRectForFont.height
        guard lineHeight > 0 else { return 1 }
        return max(1, Int(ceil(rect.height / lineHeight)))
    }
}
