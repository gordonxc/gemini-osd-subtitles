import AppKit
import Sparkle

/// Owns the lifecycle of the menu bar app: the status item, the dropdown menu
/// controller, the coordinator that wires audio → Gemini → OSD, and the
/// Sparkle updater controller.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menuController: StatusMenuController!
    private let coordinator = AppCoordinator()

    /// Sparkle updater. Held strongly so it survives for the app lifetime —
    /// if this is released, the launch-time update check never fires and the
    /// "Check for Updates…" menu item stops working. Because
    /// SUEnableAutomaticUpdates=false, starting it triggers a single feed
    /// fetch on launch instead of periodic background polling.
    private var updaterController: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusIcon(state: .stopped)

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)

        menuController = StatusMenuController(
            coordinator: coordinator,
            statusItem: statusItem,
            updaterController: updaterController)
        statusItem.menu = menuController.buildMenu()

        coordinator.delegate = self
        coordinator.statusChanged = { [weak self] state, statusText in
            self?.configureStatusIcon(state: state)
            self?.menuController.updateStatusLine(statusText)
        }

        // Per the plan: preflight on launch and trigger the TCC prompt
        // proactively (the legacy CGRequestScreenCaptureAccess is unreliable;
        // SCShareableContent is the reliable trigger on macOS 13+). This way
        // the user sees the prompt before clicking Start.
        coordinator.requestScreenCapturePermissionOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop(reason: .userRequested)
    }

    // MARK: Status icon

    func configureStatusIcon(state: AppCoordinator.RunState) {
        guard let button = statusItem.button else { return }
        let symbolName = "captions.bubble"
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Subtitles")?
            .withSymbolConfiguration(config)

        let tintColor: NSColor
        switch state {
        case .stopped: tintColor = .systemGray
        case .starting: tintColor = .systemYellow
        case .active: tintColor = .systemGreen
        case .receivingAudio: tintColor = .systemBlue
        case .error: tintColor = .systemRed
        }
        button.image = tint(image: base, with: tintColor) ?? base
    }

    /// Manual template tinting: draw the source image with the color set as
    /// the fill, using its alpha as a mask. Works on any macOS version.
    private func tint(image: NSImage?, with color: NSColor) -> NSImage? {
        guard let image else { return nil }
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}

extension AppDelegate: AppCoordinatorDelegate {
    func coordinatorRequestedAPIKeyEntry(_ coordinator: AppCoordinator) {
        // Bring the menu-hosted "Set API Key…" prompt forward.
        menuController.presentAPIKeyAlert()
    }
}
