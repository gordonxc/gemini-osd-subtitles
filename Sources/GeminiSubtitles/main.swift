import AppKit

// Entry point for a menu bar app. We bootstrap NSApplication manually so we
// control the activation policy and delegate wiring without a MainMenu nib.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon (mirrors LSUIElement)
app.run()
