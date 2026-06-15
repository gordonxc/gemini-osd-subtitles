import AppKit

/// Dedicated window-based API key prompt.
///
/// Replaces the previous NSAlert-based prompt, which had two problems when
/// presented from a menu bar app:
///   1. Cmd+V paste often failed because the menu was still mid-modal-session
///      and the alert's window never became a proper key window.
///   2. The secure field hid the entire key behind dots with no way to verify
///      what was pasted, which looked like the key had been truncated.
///
/// Using a real `NSWindow` + `NSApp.activate(ignoringOtherApps:)` gives a
/// proper key window with a working Edit menu, and the "Show" toggle lets the
/// user inspect the pasted value before saving.
final class APIKeyPrompt: NSWindowController {

    /// Set to the entered (trimmed) key on Save, or nil on Cancel.
    private(set) var submittedKey: String?

    private let secureField = NSSecureTextField()
    private let plainField = NSTextField()
    private let showToggle = NSButton(checkboxWithTitle: "Show", target: nil, action: nil)

    init() {
        let rect = NSRect(x: 0, y: 0, width: 460, height: 180)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Gemini API Key"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        setupContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Paste your Gemini API key (stored in Keychain):")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        secureField.translatesAutoresizingMaskIntoConstraints = false
        secureField.placeholderString = "AIza…"
        secureField.font = NSFont.systemFont(ofSize: 12)
        secureField.drawsBackground = true
        secureField.isBezeled = true
        secureField.bezelStyle = .roundedBezel
        secureField.translatesAutoresizingMaskIntoConstraints = false
        if let existing = KeychainStore.getAPIKey() {
            secureField.stringValue = existing
        }

        plainField.translatesAutoresizingMaskIntoConstraints = false
        plainField.placeholderString = "AIza…"
        plainField.font = NSFont.systemFont(ofSize: 12)
        plainField.isHidden = true
        plainField.stringValue = secureField.stringValue
        plainField.drawsBackground = true
        plainField.isBezeled = true
        plainField.bezelStyle = .roundedBezel

        showToggle.translatesAutoresizingMaskIntoConstraints = false
        showToggle.target = self
        showToggle.action = #selector(toggleShow(_:))

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [showToggle, NSView(), cancelButton, saveButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fill
        buttonRow.spacing = 8

        let stack = NSStackView(views: [label, secureField, plainField, buttonRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
            secureField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            plainField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    // MARK: Presentation

    /// Runs the prompt as an application-modal session. Defers to the next
    /// run-loop tick and activates the app first so the menu has finished its
    /// own modal tracking and our window can become key (so Cmd+V works).
    func present() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self.secureField.isHidden ? self.plainField : self.secureField)
        }
    }

    // MARK: Actions

    @objc private func toggleShow(_ sender: NSButton) {
        let show = (sender.state == .on)
        // Keep the two fields in sync.
        plainField.stringValue = secureField.stringValue
        plainField.isHidden = !show
        secureField.isHidden = show
        window?.makeFirstResponder(show ? plainField : secureField)
    }

    @objc private func save(_ sender: NSButton) {
        let raw = secureField.isHidden ? plainField.stringValue : secureField.stringValue
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedKey = trimmed
        if let window { window.sheetParent?.endSheet(window) }
        close()
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancel(_ sender: NSButton) {
        submittedKey = nil
        if let window { window.sheetParent?.endSheet(window) }
        close()
        NSApp.stopModal(withCode: .cancel)
    }
}
