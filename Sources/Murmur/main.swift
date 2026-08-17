import AppKit

SelfTest.runIfRequested()

// Top-level code is nonisolated, but it does run on the main thread, so the
// main-actor app objects can be constructed here safely.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
