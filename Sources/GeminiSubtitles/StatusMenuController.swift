import AppKit

/// Builds and updates the menu bar dropdown. Owns language selection state
/// (persisted to UserDefaults) and the API-key entry alert.
final class StatusMenuController: NSObject, NSMenuDelegate {

    private weak var coordinator: AppCoordinator?
    private weak var statusItem: NSStatusItem?

    /// Top status line shown in the dropdown ("Stopped", "Running", last error…).
    private let statusLine = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")

    /// MenuItem references used to show the Start/Stop label and the language
    /// selection checkmark.
    private weak var startStopItem: NSMenuItem?
    private weak var osdLockItem: NSMenuItem?
    private var languageItems: [NSMenuItem] = []
    private var fontSizeItems: [NSMenuItem] = []
    private let menu = NSMenu()

    /// User-defaults key for the last chosen target language code.
    private let selectedLanguageKey = "com.gemini-subtitles.selectedLanguage"

    /// User-defaults key for the explicit audio source device UID
    /// (empty string = system default).
    private let selectedAudioSourceKey = "com.gemini-subtitles.selectedAudioSource"

    /// User-defaults key for the OSD font size (points).
    private let selectedFontSizeKey = "com.gemini-subtitles.fontSize"

    /// Available OSD font sizes (points). Default is 20.
    static let fontSizes: [Int] = [14, 18, 20, 24, 28, 32, 40, 48, 56, 64, 72]
    static let defaultFontSize: Int = 20

    init(coordinator: AppCoordinator, statusItem: NSStatusItem) {
        self.coordinator = coordinator
        self.statusItem = statusItem
        super.init()
    }

    // MARK: Menu build

    func buildMenu() -> NSMenu {
        menu.removeAllItems()
        menu.delegate = self

        // Click the status line to copy its text to the clipboard — handy for
        // pasting error messages into a bug report.
        statusLine.target = self
        statusLine.action = #selector(copyStatusLine)
        statusLine.toolTip = "Click to copy"
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let startStop = NSMenuItem(title: "Start", action: #selector(toggleStartStop), keyEquivalent: "")
        startStop.target = self
        startStop.isEnabled = true
        menu.addItem(startStop)
        startStopItem = startStop
        refreshStartStopTitle()

        let languageHeader = NSMenuItem(title: "Target Language", action: nil, keyEquivalent: "")
        languageHeader.isEnabled = false
        menu.addItem(languageHeader)

        let current = selectedLanguageCode()
        for lang in Languages.all {
            let item = NSMenuItem(title: lang.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = (lang.code == current) ? .on : .off
            menu.addItem(item)
            languageItems.append(item)
        }

        menu.addItem(.separator())

        // Audio source picker
        let sourceHeader = NSMenuItem(title: "Audio Source", action: nil, keyEquivalent: "")
        sourceHeader.isEnabled = false
        menu.addItem(sourceHeader)

        let currentSource = selectedAudioSourceUID()
        let systemItem = NSMenuItem(title: "System Default", action: #selector(selectAudioSource(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.representedObject = ""   // empty = system default
        systemItem.state = currentSource.isEmpty ? .on : .off
        menu.addItem(systemItem)

        for device in AudioCapture.enumerateOutputDevices() {
            let item = NSMenuItem(title: device.name, action: #selector(selectAudioSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = (device.uid == currentSource) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Font size picker
        let fontHeader = NSMenuItem(title: "Font Size", action: nil, keyEquivalent: "")
        fontHeader.isEnabled = false
        menu.addItem(fontHeader)

        let currentSize = selectedFontSize()
        for size in StatusMenuController.fontSizes {
            let item = NSMenuItem(title: "\(size) pt", action: #selector(selectFontSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = (size == currentSize) ? .on : .off
            menu.addItem(item)
            fontSizeItems.append(item)
        }

        menu.addItem(.separator())

        // OSD lock/unlock toggle. Unlocked = draggable; Locked = click-through.
        let osdLock = NSMenuItem(title: "Unlock OSD to Move", action: #selector(toggleOSDLock), keyEquivalent: "")
        osdLock.target = self
        menu.addItem(osdLock)
        osdLockItem = osdLock

        let apiKey = NSMenuItem(title: "Set API Key…", action: #selector(presentAPIKeyAlert), keyEquivalent: "")
        apiKey.target = self
        menu.addItem(apiKey)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: Public updates

    /// Called by AppDelegate when coordinator state changes.
    func updateStatusLine(_ text: String) {
        let lower = text.lowercased()
        let isError = ["error", "audio:", "no api key", "system audio", "permission"].contains {
            lower.hasPrefix($0)
        }
        // Prefix with a clipboard glyph on errors so the user knows the line
        // is clickable to copy.
        statusLine.title = isError ? "⧉  \(text)" : text
    }

    @objc private func copyStatusLine() {
        let title = statusLine.title
        // Strip the "⧉  " prefix if present so only the real message is copied.
        let toCopy = title.hasPrefix("⧉  ") ? String(title.dropFirst(3)) : title
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(toCopy, forType: .string)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Refresh dynamic labels (Start/Stop title) every time the menu opens.
        refreshStartStopTitle()
    }

    // MARK: Actions

    @objc private func toggleStartStop() {
        guard let coordinator else { return }
        switch coordinator.runState {
        case .stopped, .error:
            let language = selectedLanguageCode()
            let source = selectedAudioSourceUID()
            coordinator.start(targetLanguage: language, audioSourceUID: source.isEmpty ? nil : source)
        default:
            coordinator.stop(reason: .userRequested)
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: selectedLanguageKey)
        for item in languageItems {
            item.state = (item === sender) ? .on : .off
        }
        // If we're mid-run, swap the language live by restarting the bridge.
        if coordinator?.runState == .active
            || coordinator?.runState == .starting
            || coordinator?.runState == .receivingAudio {
            coordinator?.stop(reason: .languageChanged)
            coordinator?.start(targetLanguage: code)
        }
    }

    @objc private func selectAudioSource(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: selectedAudioSourceKey)
        // Rebuild the menu to refresh checkmarks.
        if let menu = statusItem?.menu {
            let newMenu = buildMenu()
            statusItem?.menu = newMenu
            _ = menu  // keep reference; Swift will deallocate after swap
        }
        // If we're mid-run, restart capture with the new source.
        if coordinator?.runState == .active
            || coordinator?.runState == .starting
            || coordinator?.runState == .receivingAudio {
            let lang = selectedLanguageCode()
            coordinator?.stop(reason: .languageChanged)
            coordinator?.start(targetLanguage: lang, audioSourceUID: uid)
        }
    }

    @objc private func selectFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(size, forKey: selectedFontSizeKey)
        for item in fontSizeItems {
            item.state = (item === sender) ? .on : .off
        }
        coordinator?.setSubtitleFontSize(CGFloat(size))
    }

    @objc private func toggleOSDLock() {
        let locked = coordinator?.toggleOSDLock() ?? true
        // When locked → click-through; show "Unlock" label.
        // When unlocked → draggable; show "Lock" label.
        osdLockItem?.title = locked ? "Unlock OSD to Move" : "Lock OSD"
    }

    @objc private func quit() {
        coordinator?.stop(reason: .userRequested)
        NSApp.terminate(nil)
    }

    // MARK: API key prompt

    @objc func presentAPIKeyAlert() {
        // Use a dedicated window rather than NSAlert so the field becomes a
        // proper key window (NSAlert from a menu bar app breaks Cmd+V paste
        // because the menu is still mid-modal-session).
        let prompt = APIKeyPrompt()
        prompt.present()
        let response = NSApp.runModal(for: prompt.window!)
        prompt.close()

        guard response == .OK, let key = prompt.submittedKey, !key.isEmpty else { return }
        do {
            try KeychainStore.setAPIKey(key)
        } catch {
            // Fall back to a plain alert for error reporting (no text entry).
            let errAlert = NSAlert()
            errAlert.alertStyle = .critical
            errAlert.messageText = "Could not save API key"
            errAlert.informativeText = error.localizedDescription
            errAlert.runModal()
        }
    }

    // MARK: Helpers

    private func selectedLanguageCode() -> String {
        let stored = UserDefaults.standard.string(forKey: selectedLanguageKey) ?? Languages.defaultCode
        // Validate against current list. Old versions stored BCP-47 codes
        // (e.g. "yue-HK") that the API rejects — fall back to default.
        guard Languages.all.contains(where: { $0.code == stored }) else {
            return Languages.defaultCode
        }
        return stored
    }

    /// Returns the stored audio source device UID (empty = system default).
    func selectedAudioSourceUID() -> String {
        UserDefaults.standard.string(forKey: selectedAudioSourceKey) ?? ""
    }

    /// Returns the stored OSD font size in points (default 20).
    func selectedFontSize() -> Int {
        let stored = UserDefaults.standard.integer(forKey: selectedFontSizeKey)
        guard stored > 0, Self.fontSizes.contains(stored) else {
            return Self.defaultFontSize
        }
        return stored
    }

    private func refreshStartStopTitle() {
        switch coordinator?.runState {
        case .active, .starting, .receivingAudio:
            startStopItem?.title = "Stop"
        case .error:
            startStopItem?.title = "Restart"
        default:
            startStopItem?.title = "Start"
        }
    }
}

extension StatusMenuController {
    /// Exposed so AppDelegate can refresh the Start/Stop label whenever the
    /// coordinator state changes (the menu is rebuilt lazily on open).
    func refresh() {
        refreshStartStopTitle()
    }
}
