import AppKit

/// Renders subtitle text centered in the OSD window. White text + soft black
/// drop shadow for readability on any background.
///
/// In bilingual mode the original (source-language) transcript is shown on a
/// smaller, light-gray line above the translation.
final class SubtitleViewController: NSViewController {

    private let textField = NSTextField(labelWithString: "")
    private let originalField = NSTextField(labelWithString: "")

    /// Default point size. Overridden at runtime via `applyFontSize`.
    static var defaultSize: CGFloat = 20
    /// The original line is rendered at this ratio of the main size.
    private let originalSizeRatio: CGFloat = 0.7

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

        // Original hidden until first non-empty payload.
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
    func update(text: String, original: String?) {
        textField.stringValue = text
        if let original = original, !original.isEmpty {
            originalField.stringValue = original
            originalField.isHidden = false
        } else {
            originalField.isHidden = true
        }
    }

    /// Apply a new font size to the subtitle text. The original line scales
    /// proportionally.
    func applyFontSize(_ size: CGFloat) {
        textField.font = NSFont.systemFont(ofSize: size, weight: .medium)
        originalField.font = NSFont.systemFont(ofSize: size * originalSizeRatio, weight: .medium)
    }
}
