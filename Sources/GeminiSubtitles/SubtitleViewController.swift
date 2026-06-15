import AppKit

/// Renders a single line of subtitle text centered in the OSD window.
/// White text + soft black drop shadow for readability on any background.
final class SubtitleViewController: NSViewController {

    private let textField = NSTextField(labelWithString: "")

    /// Default point size. Overridden at runtime via `applyFontSize`.
    static var defaultSize: CGFloat = 20

    override func loadView() {
        // Sizing is owned by the window; the controller just fills it.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 84))
        container.translatesAutoresizingMaskIntoConstraints = false

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.alignment = .center
        textField.font = NSFont.systemFont(ofSize: SubtitleViewController.defaultSize, weight: .medium)
        textField.textColor = .white
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 2
        textField.cell?.truncatesLastVisibleLine = true
        textField.cell?.wraps = true

        // Drop shadow so text reads on both light and dark backgrounds.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: 0)
        textField.shadow = shadow

        container.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            textField.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        self.view = container
    }

    /// Single-line interim replace: each update overwrites the prior text.
    func update(text: String) {
        textField.stringValue = text
    }

    /// Apply a new font size to the subtitle text.
    func applyFontSize(_ size: CGFloat) {
        textField.font = NSFont.systemFont(ofSize: size, weight: .medium)
    }
}
