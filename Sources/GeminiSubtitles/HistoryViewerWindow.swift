import AppKit

/// A viewer window that shows the entries for one session file (or the live
/// current session) and exposes an Export… button.
///
/// Designed so multiple viewer windows can coexist (one per opened session).
/// Subscribes to `HistoryStore.onAppend` while viewing the current session
/// so the text view live-updates as new lines land.
final class HistoryViewerWindow: NSWindow {

    private let textView = NSTextView()
    private let store: HistoryStore
    private let isCurrentSession: Bool
    private let sessionURL: URL?
    private var loadedEntries: [HistoryEntry] = []

    /// Initial entry snapshot (file contents or in-memory current-session
    /// cache). For the current session, live updates arrive via `onAppend`.
    init(store: HistoryStore, info: SessionInfo?) {
        self.store = store
        self.sessionURL = info?.url
        // "Current session" if no info supplied OR the URL matches the open
        // session URL.
        self.isCurrentSession = (info == nil) ||
            (store.currentSessionURL == info?.url)

        let rect = NSRect(x: 0, y: 0, width: 640, height: 480)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)

        self.isReleasedWhenClosed = false
        self.title = {
            if isCurrentSession {
                return "Current Session — Gemini Subtitles"
            }
            guard let info else { return "History — Gemini Subtitles" }
            return "\(HistoryStore.menuLabel(for: info)) — Gemini Subtitles"
        }()

        buildUI()
        loadInitial()
        subscribeIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: UI

    private func buildUI() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let exportButton = NSButton(
            title: "Export…", target: self, action: #selector(presentExportDialog))
        exportButton.bezelStyle = .rounded
        exportButton.controlSize = .regular
        exportButton.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(exportButton)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: exportButton.topAnchor, constant: -8),

            exportButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            exportButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        contentView = container
    }

    // MARK: Loading

    private func loadInitial() {
        if isCurrentSession {
            loadedEntries = store.currentEntries
        } else if let url = sessionURL {
            loadedEntries = store.loadEntries(from: url)
        }
        rebuildText()
    }

    private func rebuildText() {
        let lines = loadedEntries.map { entry in
            "[\(HistoryStore.entryTime(entry.ts))] \(entry.text)"
        }
        let rich = NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        textView.textStorage?.setAttributedString(rich)
        // Scroll to bottom so the latest line is visible.
        scrollToEnd()
    }

    private func scrollToEnd() {
        let range = NSRange(location: textView.string.count, length: 0)
        textView.scrollRangeToVisible(range)
    }

    // MARK: Live updates

    private func subscribeIfNeeded() {
        guard isCurrentSession else { return }
        // Weak self to avoid retain cycles through the closure.
        store.onAppend = { [weak self] entry in
            guard let self else { return }
            self.loadedEntries.append(entry)
            self.appendLine(entry)
        }
    }

    /// Append a single entry without reflowing the whole text view.
    private func appendLine(_ entry: HistoryEntry) {
        let line = "[\(HistoryStore.entryTime(entry.ts))] \(entry.text)\n"
        let attr = NSAttributedString(
            string: line,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        let storage = textView.textStorage
        let startIdx = (storage?.length ?? 0)
        storage?.append(attr)
        // Need at least one char in storage for the empty case — guard above.
        _ = startIdx
        scrollToEnd()
    }

    // MARK: Export

    @objc private func presentExportDialog() {
        let panel = NSSavePanel()
        panel.title = "Export Session"
        panel.canCreateDirectories = true

        // Format dropdown.
        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for fmt in HistoryExporter.Format.allCases {
            formatPopup.addItem(withTitle: fmt.displayName)
        }
        formatPopup.selectItem(at: 0)
        panel.accessoryView = formatPopup

        // Default filename: session timestamp + format.
        let baseName: String = {
            if isCurrentSession, let start = store.currentSessionStart {
                return "GeminiSubtitles-\(HistoryStore.label(forStartDate: start))"
            }
            if let url = sessionURL {
                return url.deletingPathExtension().lastPathComponent
            }
            return "GeminiSubtitles-history"
        }()
        // Sanitise — the label may contain commas/spaces.
        let safeBase = baseName.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        panel.nameFieldStringValue = safeBase

        // Update extension when format changes.
        let onFormatChange = { [weak panel, weak formatPopup] in
            guard let panel, let popup = formatPopup else { return }
            let idx = popup.indexOfSelectedItem
            let fmt = HistoryExporter.Format.allCases[safe: idx] ?? .txt
            let allowed: [String] = [fmt.fileExtension]
            panel.allowedContentTypes = []  // fall back to extension filter
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString)
                .deletingPathExtension + "." + fmt.fileExtension
            _ = allowed
        }
        formatPopup.target = Wrapper(block: onFormatChange)
        formatPopup.action = #selector(Wrapper.fire(_:))
        // Trigger once to set initial extension.
        onFormatChange()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fmt = HistoryExporter.Format.allCases[
            safe: formatPopup.indexOfSelectedItem] ?? .txt
        let data = HistoryExporter.render(loadedEntries, format: fmt)
        do {
            try data.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// Tiny bridging object so an NSPopUpButton action can call a closure.
private final class Wrapper: NSObject {
    let block: () -> Void
    init(block: @escaping () -> Void) { self.block = block }
    @objc func fire(_ sender: Any?) { block() }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
