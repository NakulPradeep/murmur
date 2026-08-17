import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    let dictation = DictationController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var overlay: RecordingOverlay?
    private var shownInsertionHint = false
    private var accessibilityPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Prefs.registerDefaults()
        Log.log("=== launch v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") "
            + "ax=\(TextInserter.hasAccessibility)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        statusItem.menu = buildMenu()

        overlay = RecordingOverlay()

        dictation.onStateChange = { [weak self] in self?.refresh() }
        dictation.start()

        EngineRouter.shared.onStateChange = { [weak self] in self?.refresh() }
        EngineRouter.shared.activatePreferredModel()

        AIRefiner.prewarm()

        if !TextInserter.hasAccessibility {
            TextInserter.promptForAccessibility()
            watchForAccessibilityGrant()
        }
        if EngineRouter.preferredModel() == nil {
            showModelNeededHint()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EngineRouter.shared.shutdown()
    }

    // MARK: - Status item

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let (symbol, description): (String, String)
        switch dictation.state {
        case .idle:
            (symbol, description) = ("mic", "Murmur idle")
        case .recording:
            (symbol, description) = ("record.circle.fill", "Murmur recording")
        case .transcribing:
            (symbol, description) = ("waveform", "Murmur transcribing")
        case .polishing:
            (symbol, description) = ("wand.and.stars", "Murmur polishing")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Murmur \u{2014} hold \(Prefs.triggerKey.display) to dictate"
    }

    func refresh() {
        updateStatusIcon()
        // Rebuilding a menu while it is open closes it under the user's cursor.
        if statusItem.menu?.highlightedItem == nil {
            statusItem.menu = buildMenu()
        }
        if Prefs.defaults.bool(forKey: PrefKey.showOverlay) {
            overlay?.update(state: dictation.state, level: dictation.level)
        } else {
            overlay?.update(state: .idle, level: 0)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let stateTitle: String
        switch dictation.state {
        case .idle:
            stateTitle = EngineRouter.shared.isReady
                ? "Ready \u{2014} hold \(Prefs.triggerKey.display) to dictate"
                : "\(EngineRouter.shared.statusDescription) \u{2014} open Settings"
        case .recording:
            stateTitle = dictation.handsFree
                ? "Recording \u{2014} \(Prefs.triggerKey.display) or Return to finish"
                : "Recording\u{2026} release to insert"
        case .transcribing:
            stateTitle = "Transcribing\u{2026}"
        case .polishing:
            stateTitle = "Polishing\u{2026}"
        }
        addDisabled(stateTitle, to: menu)

        if let model = EngineRouter.shared.loadedModel {
            addDisabled("Model: \(model.title) (\(model.engine.displayName))", to: menu)
        }

        menu.addItem(.separator())

        let toggleTitle = dictation.state == .recording
            ? "Stop && Insert" : "Start Hands-free Dictation"
        let toggle = NSMenuItem(
            title: toggleTitle, action: #selector(toggleDictation), keyEquivalent: "d")
        toggle.target = self
        menu.addItem(toggle)

        if !dictation.history.isEmpty {
            menu.addItem(.separator())
            addDisabled("Recent (click to copy)", to: menu)
            for (index, entry) in dictation.history.prefix(5).enumerated() {
                let title = entry.text.count > 46
                    ? String(entry.text.prefix(46)) + "\u{2026}" : entry.text
                let item = NSMenuItem(
                    title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if !TextInserter.hasAccessibility {
            addAction("\u{26A0}\u{FE0F} Grant Accessibility (needed to type for you)",
                      #selector(openAccessibilitySettings), to: menu)
        } else if !dictation.keyListenerActive {
            addAction("\u{26A0}\u{FE0F} Key listener inactive \u{2014} Relaunch Murmur",
                      #selector(relaunchClicked), to: menu)
        }

        let settings = NSMenuItem(
            title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        return menu
    }

    private func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ selector: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func toggleDictation() { dictation.toggleHandsFree() }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard sender.tag < dictation.history.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(dictation.history[sender.tag].text, forType: .string)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(ModelStore.shared)
                .environmentObject(dictation)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Murmur Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 620, height: 560))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func relaunchClicked() { AppDelegate.relaunch() }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS applies a new Accessibility grant reliably only to a freshly
    /// launched process, so watch for the grant and restart once it lands.
    private func watchForAccessibilityGrant() {
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            guard TextInserter.hasAccessibility else { return }
            timer.invalidate()
            Task { @MainActor in
                AppDelegate.shared?.accessibilityPoll = nil
                Log.log("accessibility granted — relaunching to arm the key listener")
                AppDelegate.relaunch()
            }
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            AppDelegate.shared?.dictation.reloadHotkey()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Hints

    func showInsertionFallbackHint(reason: String) {
        guard !shownInsertionHint else { return }
        shownInsertionHint = true
        let alert = NSAlert()
        alert.messageText = "Your dictation is on the clipboard"
        alert.informativeText = "Murmur could not type it directly because \(reason). "
            + "Press \u{2318}V to paste.\n\n"
            + "If Murmur is already listed under Accessibility but still cannot type, "
            + "remove it with the \u{2212} button and add it back \u{2014} macOS drops the "
            + "permission when the app is rebuilt."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    func showModelNeededHint() {
        openSettings()
    }
}
