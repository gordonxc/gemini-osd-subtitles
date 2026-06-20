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

    /// User-defaults key for the auto-stop inactivity timeout (minutes,
    /// 0 = off).
    private let selectedAutoStopKey = "com.gemini-subtitles.autoStopMinutes"

    /// Available OSD font sizes (points). Default is 20.
    static let fontSizes: [Int] = [14, 18, 20, 24, 28, 32, 40, 48, 56, 64, 72]
    static let defaultFontSize: Int = 20

    /// Available auto-stop inactivity timeouts in minutes (0 = off).
    static let autoStopOptions: [Int] = [0, 5, 15, 30, 60]

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

        // --- Target Language submenu ---
        let currentLang = selectedLanguageCode()
        let langName = Languages.name(forCode: currentLang)
        let langParent = NSMenuItem(title: "Target Language: \(langName)", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        languageItems = []
        for lang in Languages.all {
            let item = NSMenuItem(title: lang.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = (lang.code == currentLang) ? .on : .off
            langMenu.addItem(item)
            languageItems.append(item)
        }
        langParent.submenu = langMenu
        menu.addItem(langParent)

        // --- Audio Source submenu ---
        let currentSource = selectedAudioSourceUID()
        let sourceLabel = currentSource.isEmpty ? "System Default" : (AudioCapture.enumerateOutputDevices().first { $0.uid == currentSource }?.name ?? "Custom")
        let sourceParent = NSMenuItem(title: "Audio Source: \(sourceLabel)", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu()
        let systemItem = NSMenuItem(title: "System Default", action: #selector(selectAudioSource(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.representedObject = ""   // empty = system default
        systemItem.state = currentSource.isEmpty ? .on : .off
        sourceMenu.addItem(systemItem)
        if !AudioCapture.enumerateOutputDevices().isEmpty {
            sourceMenu.addItem(.separator())
        }
        for device in AudioCapture.enumerateOutputDevices() {
            let item = NSMenuItem(title: device.name, action: #selector(selectAudioSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = (device.uid == currentSource) ? .on : .off
            sourceMenu.addItem(item)
        }
        sourceParent.submenu = sourceMenu
        menu.addItem(sourceParent)

        // --- Font Size submenu ---
        let currentSize = selectedFontSize()
        let fontParent = NSMenuItem(title: "Font Size: \(currentSize) pt", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu()
        fontSizeItems = []
        for size in StatusMenuController.fontSizes {
            let item = NSMenuItem(title: "\(size) pt", action: #selector(selectFontSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = (size == currentSize) ? .on : .off
            fontMenu.addItem(item)
            fontSizeItems.append(item)
        }
        fontParent.submenu = fontMenu
        menu.addItem(fontParent)

        // --- Auto-stop submenu ---
        let currentAutoStop = selectedAutoStopMinutes()
        let autoStopLabel = currentAutoStop == 0 ? "Off" : "\(currentAutoStop) min"
        let autoStopParent = NSMenuItem(title: "Auto-stop: \(autoStopLabel)", action: nil, keyEquivalent: "")
        let autoStopMenu = NSMenu()
        for option in StatusMenuController.autoStopOptions {
            let title = option == 0 ? "Off" : "\(option) min"
            let item = NSMenuItem(title: title, action: #selector(selectAutoStop(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            item.state = (option == currentAutoStop) ? .on : .off
            autoStopMenu.addItem(item)
        }
        autoStopParent.submenu = autoStopMenu
        menu.addItem(autoStopParent)

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
        rebuildMenuInPlace()
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
        rebuildMenuInPlace()
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
        rebuildMenuInPlace()
        coordinator?.setSubtitleFontSize(CGFloat(size))
    }

    @objc private func selectAutoStop(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(minutes, forKey: selectedAutoStopKey)
        rebuildMenuInPlace()
        // AppCoordinator reads the new value on its next poll tick — no
        // need to push it explicitly.
    }

    /// Rebuild the status item's menu so parent titles reflect the new
    /// selection. The old menu is released after the swap.
    private func rebuildMenuInPlace() {
        guard let statusItem else { return }
        let oldMenu = statusItem.menu
        let newMenu = buildMenu()
        statusItem.menu = newMenu
        _ = oldMenu
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

    /// Returns the stored auto-stop inactivity timeout in minutes
    /// (0 = off, which is also the default).
    func selectedAutoStopMinutes() -> Int {
        let stored = UserDefaults.standard.integer(forKey: selectedAutoStopKey)
        guard Self.autoStopOptions.contains(stored) else { return 0 }
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
