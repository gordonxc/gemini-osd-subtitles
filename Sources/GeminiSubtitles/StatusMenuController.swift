import AppKit
import Sparkle

/// Builds and updates the menu bar dropdown. Owns language selection state
/// (persisted to UserDefaults) and the API-key entry alert.
final class StatusMenuController: NSObject, NSMenuDelegate {

    private weak var coordinator: AppCoordinator?
    private weak var statusItem: NSStatusItem?

    /// Sparkle updater; "Check for Updates…" invokes `checkForUpdates(_:)`.
    private weak var updaterController: SPUStandardUpdaterController?

    /// Top status line shown in the dropdown ("Stopped", "Running", last error…).
    private let statusLine = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")

    /// MenuItem references used to show the Start/Stop label and the language
    /// selection checkmark.
    private weak var startStopItem: NSMenuItem?
    private weak var osdLockItem: NSMenuItem?
    private var languageItems: [NSMenuItem] = []
    private var fontSizeItems: [NSMenuItem] = []
    private let menu = NSMenu()

    /// Open viewer windows, keyed by session URL path (or "current"). Each
    /// session can be opened in its own window; the dictionary keeps them
    /// alive so they don't close when the user clicks away.
    private var viewerWindows: [String: HistoryViewerWindow] = [:]

    /// User-defaults key for the last chosen target language code.
    private let selectedLanguageKey = "com.gemini-subtitles.selectedLanguage"

    /// User-defaults key for the explicit audio source device UID
    /// (empty string = system default).
    private let selectedAudioSourceKey = "com.gemini-subtitles.selectedAudioSource"

    /// User-defaults key for the explicit microphone device UID
    /// (empty string = system default input).
    private let selectedMicSourceKey = "com.gemini-subtitles.selectedMicSource"

    /// User-defaults key for the audio source kind ("system" or "mic").
    /// Defaults to "system" to preserve prior behavior.
    private let selectedSourceKindKey = "com.gemini-subtitles.audioSourceKind"

    /// User-defaults key for the OSD font size (points).
    private let selectedFontSizeKey = "com.gemini-subtitles.fontSize"

    /// User-defaults key for the auto-stop inactivity timeout (minutes,
    /// 0 = off).
    private let selectedAutoStopKey = "com.gemini-subtitles.autoStopMinutes"

    /// User-defaults key for the bilingual OSD toggle (bool, default false).
    private let bilingualKey = "com.gemini-subtitles.bilingual"

    /// Available OSD font sizes (points). Default is 20.
    static let fontSizes: [Int] = [14, 18, 20, 24, 28, 32, 40, 48, 56, 64, 72]
    static let defaultFontSize: Int = 20

    /// Available auto-stop inactivity timeouts in minutes (0 = off).
    static let autoStopOptions: [Int] = [0, 5, 15, 30, 60]

    init(coordinator: AppCoordinator,
         statusItem: NSStatusItem,
         updaterController: SPUStandardUpdaterController? = nil) {
        self.coordinator = coordinator
        self.statusItem = statusItem
        self.updaterController = updaterController
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

        // --- Audio Source submenu (two-level) ---
        buildAudioSourceSubmenu()

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

        // --- Bilingual toggle (original + translation overlay) ---
        let bilingualOn = bilingualEnabled()
        let bilingual = NSMenuItem(
            title: bilingualOn ? "Bilingual: On" : "Bilingual: Off",
            action: #selector(toggleBilingual),
            keyEquivalent: "")
        bilingual.target = self
        menu.addItem(bilingual)

        menu.addItem(.separator())

        // --- History submenu ---
        buildHistorySubmenu()

        // OSD lock/unlock toggle. Unlocked = draggable; Locked = click-through.
        let osdLock = NSMenuItem(title: "Unlock OSD to Move", action: #selector(toggleOSDLock), keyEquivalent: "")
        osdLock.target = self
        menu.addItem(osdLock)
        osdLockItem = osdLock

        let apiKey = NSMenuItem(title: "Set API Key…", action: #selector(presentAPIKeyAlert), keyEquivalent: "")
        apiKey.target = self
        menu.addItem(apiKey)

        // "Check for Updates…" → Sparkle's standard update window. Disabled
        // when no updater is wired in (defensive; should always be present).
        let checkUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: "")
        checkUpdates.target = self
        checkUpdates.isEnabled = (updaterController != nil)
        menu.addItem(checkUpdates)

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
            coordinator.start(targetLanguage: language, audioSource: currentAudioSource())
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
            coordinator?.start(targetLanguage: code, audioSource: currentAudioSource())
        }
    }

    @objc private func selectAudioSource(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: selectedAudioSourceKey)
        UserDefaults.standard.set("system", forKey: selectedSourceKindKey)
        rebuildMenuInPlace()
        restartPipelineIfRunning()
    }

    @objc private func selectMicSource(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: selectedMicSourceKey)
        UserDefaults.standard.set("mic", forKey: selectedSourceKindKey)
        rebuildMenuInPlace()
        restartPipelineIfRunning()
    }

    /// Restart the pipeline using the currently-selected source kind + UID.
    /// No-op when stopped.
    private func restartPipelineIfRunning() {
        guard coordinator?.runState == .active
            || coordinator?.runState == .starting
            || coordinator?.runState == .receivingAudio else { return }
        let lang = selectedLanguageCode()
        coordinator?.stop(reason: .languageChanged)
        coordinator?.start(targetLanguage: lang, audioSource: currentAudioSource())
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

    @objc private func toggleBilingual() {
        let newValue = !bilingualEnabled()
        UserDefaults.standard.set(newValue, forKey: bilingualKey)
        rebuildMenuInPlace()
        // Bilingual requires a fresh Gemini setup (different setup message),
        // so restart the pipeline if currently running.
        restartPipelineIfRunning()
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

    /// Manual update check — opens Sparkle's standard update window if a
    /// newer version is found on the appcast feed.
    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    // MARK: Audio Source submenu

    /// Builds the two-level Audio Source ▸ submenu:
    ///   System Audio ▸ (System Default + output devices)
    ///   Microphone ▸ (System Default + input devices)
    /// Current selection is marked with a checkmark at the leaf level.
    private func buildAudioSourceSubmenu() {
        let parent: NSMenuItem
        let submenu = NSMenu()

        // --- System Audio sub-submenu ---
        let currentSysUID = selectedAudioSourceUID()
        let isSysKind = selectedSourceKind() == "system"
        let systemParent = NSMenuItem(
            title: "System Audio", action: nil, keyEquivalent: "")
        let systemMenu = NSMenu()

        let sysDefault = NSMenuItem(
            title: "System Default",
            action: #selector(selectAudioSource(_:)),
            keyEquivalent: "")
        sysDefault.target = self
        sysDefault.representedObject = ""
        sysDefault.state = (isSysKind && currentSysUID.isEmpty) ? .on : .off
        systemMenu.addItem(sysDefault)

        let outputs = AudioCapture.enumerateOutputDevices()
        if !outputs.isEmpty {
            systemMenu.addItem(.separator())
        }
        for device in outputs {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectAudioSource(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = (isSysKind && device.uid == currentSysUID) ? .on : .off
            systemMenu.addItem(item)
        }
        systemParent.submenu = systemMenu
        submenu.addItem(systemParent)

        // --- Microphone sub-submenu ---
        let currentMicUID = selectedMicSourceUID()
        let isMicKind = !isSysKind
        let micParent = NSMenuItem(
            title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()

        let micDefault = NSMenuItem(
            title: "System Default",
            action: #selector(selectMicSource(_:)),
            keyEquivalent: "")
        micDefault.target = self
        micDefault.representedObject = ""
        micDefault.state = (isMicKind && currentMicUID.isEmpty) ? .on : .off
        micMenu.addItem(micDefault)

        let inputs = MicrophoneCapture.enumerateInputDevices()
        if !inputs.isEmpty {
            micMenu.addItem(.separator())
        }
        for device in inputs {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectMicSource(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = (isMicKind && device.uid == currentMicUID) ? .on : .off
            micMenu.addItem(item)
        }
        micParent.submenu = micMenu
        submenu.addItem(micParent)

        // Label the top-level item with the current kind + selected device.
        let topLabel: String = {
            if isMicKind {
                let micLabel = currentMicUID.isEmpty
                    ? "System Default"
                    : (inputs.first { $0.uid == currentMicUID }?.name ?? "Custom")
                return "Audio Source: Microphone (\(micLabel))"
            }
            let sysLabel = currentSysUID.isEmpty
                ? "System Default"
                : (outputs.first { $0.uid == currentSysUID }?.name ?? "Custom")
            return "Audio Source: System Audio (\(sysLabel))"
        }()
        parent = NSMenuItem(title: topLabel, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }

    // MARK: History submenu

    /// Builds the History ▸ submenu fresh each time the menu opens, listing
    /// the current session (if any) plus the 10 most recent closed sessions.
    private func buildHistorySubmenu() {
        let parent = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let history = coordinator?.history ?? HistoryStore()

        // Current session (always present; disabled when stopped).
        let current = NSMenuItem(
            title: "Current Session",
            action: #selector(openCurrentSession),
            keyEquivalent: "")
        current.target = self
        let isRunning = coordinator?.runState == .active
            || coordinator?.runState == .starting
            || coordinator?.runState == .receivingAudio
        current.isEnabled = isRunning
        submenu.addItem(current)

        let recents = history.listRecentSessions(limit: 10)
        if !recents.isEmpty {
            submenu.addItem(.separator())
            for info in recents {
                let item = NSMenuItem(
                    title: HistoryStore.menuLabel(for: info),
                    action: #selector(openPastSession(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = info.url.path
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        let reveal = NSMenuItem(
            title: "Show All in Finder…",
            action: #selector(revealHistoryInFinder),
            keyEquivalent: "")
        reveal.target = self
        submenu.addItem(reveal)

        let clear = NSMenuItem(
            title: "Clear All History…",
            action: #selector(clearAllHistory),
            keyEquivalent: "")
        clear.target = self
        submenu.addItem(clear)

        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func openCurrentSession() {
        let key = "current"
        if let existing = viewerWindows[key] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let history = coordinator?.history ?? HistoryStore()
        let window = HistoryViewerWindow(store: history, info: nil)
        window.makeKeyAndOrderFront(nil)
        viewerWindows[key] = window
    }

    @objc private func openPastSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        if let existing = viewerWindows[path] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let history = coordinator?.history ?? HistoryStore()
        let info: SessionInfo? = history.listRecentSessions(limit: 200)
            .first(where: { $0.url == url })
        let window = HistoryViewerWindow(store: history, info: info)
        window.makeKeyAndOrderFront(nil)
        viewerWindows[path] = window
    }

    @objc private func revealHistoryInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.directory])
    }

    @objc private func clearAllHistory() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all history?"
        alert.informativeText =
            "All saved session files will be deleted. This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator?.history.clearAll()
        rebuildMenuInPlace()
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

    /// Returns the stored microphone device UID (empty = system default).
    func selectedMicSourceUID() -> String {
        UserDefaults.standard.string(forKey: selectedMicSourceKey) ?? ""
    }

    /// Returns the currently-selected source kind ("system" / "mic").
    /// Defaults to "system".
    func selectedSourceKind() -> String {
        let stored = UserDefaults.standard.string(forKey: selectedSourceKindKey)
            ?? "system"
        return stored == "mic" ? "mic" : "system"
    }

    /// Builds the `AppCoordinator.AudioSource` value for the current
    /// persisted selection.
    func currentAudioSource() -> AppCoordinator.AudioSource {
        switch selectedSourceKind() {
        case "mic":
            let uid = selectedMicSourceUID()
            return .microphone(deviceUID: uid.isEmpty ? nil : uid)
        default:
            let uid = selectedAudioSourceUID()
            return .system(audioSourceUID: uid.isEmpty ? nil : uid)
        }
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

    /// Returns whether bilingual OSD overlay is enabled.
    func bilingualEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: bilingualKey)
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
