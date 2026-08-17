import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    let dictation = DictationController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var shownAccessibilityHint = false
    private var axPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Prefs.registerDefaults()
        Log.log("=== launch: v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") "
            + "ax=\(TextInserter.hasAccessibility) bundle=\(Bundle.main.bundlePath)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        statusItem.menu = buildMenu()

        dictation.onStateChange = { [weak self] in
            self?.updateStatusIcon()
            self?.statusItem.menu = self?.buildMenu()
        }
        dictation.start()

        WhisperEngine.shared.onModelStateChange = { [weak self] in
            self?.statusItem.menu = self?.buildMenu()
        }
        ModelManager.shared.loadSelectedModel()

        // Surface the system Accessibility prompt on first launch, then watch
        // for the grant so the key tap arms without an app restart.
        if !TextInserter.hasAccessibility {
            TextInserter.promptForAccessibility()
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard TextInserter.hasAccessibility else { return }
                timer.invalidate()
                self?.axPollTimer = nil
                // A grant often doesn't fully apply to a running process —
                // restart so the event tap arms reliably.
                Log.log("accessibility granted while running — relaunching to apply it")
                AppDelegate.relaunch()
            }
        }
        if ModelManager.shared.resolveSelectedModel() == nil {
            showNoModelHint()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WhisperEngine.shared.shutdown()
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
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Murmur \u{2014} hold \(Prefs.triggerKey.display) to dictate"
    }

    func refreshMenu() {
        updateStatusIcon()
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let stateTitle: String
        switch dictation.state {
        case .idle:
            stateTitle = WhisperEngine.shared.isReady
                ? "Ready \u{2014} hold \(Prefs.triggerKey.display) to dictate"
                : (ModelManager.shared.resolveSelectedModel() == nil
                    ? "No model installed \u{2014} open Settings"
                    : "Loading model\u{2026}")
        case .recording:
            stateTitle = dictation.handsFree
                ? "Recording (hands-free) \u{2014} \(Prefs.triggerKey.display) or Return to finish"
                : "Recording\u{2026} release to insert"
        case .transcribing:
            stateTitle = "Transcribing\u{2026}"
        }
        let stateItem = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        if let model = ModelManager.shared.activeModelFile {
            let m = NSMenuItem(title: "Model: \(model)", action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
        }

        menu.addItem(.separator())

        let toggleTitle = dictation.state == .recording ? "Stop && Insert" : "Start Hands-free Dictation"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleDictation), keyEquivalent: "d")
        toggle.target = self
        menu.addItem(toggle)

        if !dictation.history.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (idx, entry) in dictation.history.prefix(5).enumerated() {
                let title = entry.count > 46 ? String(entry.prefix(46)) + "\u{2026}" : entry
                let item = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = idx
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if !TextInserter.hasAccessibility {
            let ax = NSMenuItem(
                title: "\u{26A0}\u{FE0F} Grant Accessibility (needed to type for you)",
                action: #selector(openAccessibilitySettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        } else if !dictation.keyListenerActive {
            let warn = NSMenuItem(
                title: "\u{26A0}\u{FE0F} Key listener inactive \u{2014} Relaunch Murmur",
                action: #selector(relaunchClicked), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        dictation.toggleHandsFree()
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard sender.tag < dictation.history.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(dictation.history[sender.tag], forType: .string)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(ModelManager.shared)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Murmur Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 480))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func relaunchClicked() {
        Log.log("manual relaunch from menu")
        AppDelegate.relaunch()
    }

    /// Quits and reopens the app (used after permission changes; macOS applies
    /// Accessibility grants reliably only to a freshly launched process).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            AppDelegate.shared?.dictation.reloadHotkey()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Hints

    func showAccessibilityHint() {
        guard !shownAccessibilityHint else { return }
        shownAccessibilityHint = true
        let alert = NSAlert()
        alert.messageText = "Your dictation is on the clipboard"
        alert.informativeText = "Murmur can paste directly into any app once you grant "
            + "Accessibility permission in System Settings \u{2192} Privacy & Security \u{2192} "
            + "Accessibility. Until then, press \u{2318}V to paste.\n\n"
            + "If Murmur is already listed there but not working, remove it with the \u{2212} "
            + "button and add it back \u{2014} macOS drops the permission when the app is rebuilt."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    func showNoModelHint() {
        openSettings()
    }
}
