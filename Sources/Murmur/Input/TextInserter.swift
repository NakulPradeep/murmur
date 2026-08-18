import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts transcribed text into whatever app is frontmost.
///
/// Delivery is clipboard + synthetic ⌘V, with the previous clipboard restored
/// afterwards unless something else claimed it meanwhile. When text cannot be
/// delivered at all — no Accessibility permission, or secure input is active —
/// it is left on the clipboard and the user is told why.
///
/// Writing the focused element's text directly through the accessibility API
/// was tried and removed: it reported success while inserting nothing, and that
/// failure is invisible to both the app and the user.
enum TextInserter {

    enum Outcome {
        case inserted
        case clipboardOnly(reason: String)
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptForAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// True when some app has secure input enabled (a password field, or an app
    /// that left it on). Synthesized keystrokes are silently dropped while it
    /// is active, so pasting cannot work and we must not pretend it did.
    static var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    // MARK: - Insertion

    @discardableResult
    static func insert(_ text: String) -> Outcome {
        guard !text.isEmpty else { return .inserted }

        guard hasAccessibility else {
            copyToClipboard(text)
            return .clipboardOnly(reason: "Murmur does not have Accessibility permission yet")
        }

        if isSecureInputEnabled {
            copyToClipboard(text)
            return .clipboardOnly(
                reason: "another app has secure input active, so text cannot be typed")
        }

        // Paste, always.
        //
        // The accessibility path looks strictly better on paper — no clipboard
        // involvement, no synthetic keystroke — but it cannot be trusted to
        // tell the truth. AXUIElementSetAttributeValue returned .success while
        // inserting nothing at all in real use, and there is no reliable way to
        // detect that from the return value: a read-back can be equally stale.
        // A silent no-op is the worst possible failure for this app, so the
        // universally supported path wins even though it is less elegant.
        pasteViaClipboard(text)
        Log.log("pasted \(text.count) chars into \(frontmostAppName())")
        return .inserted
    }

    /// Replaces the last `count` characters typed with `text`, by extending the
    /// selection backwards and pasting over it.
    ///
    /// Only safe immediately after an insertion, while the caret is still where
    /// we left it — which is why it is bound to an action the user takes right
    /// after seeing the result.
    static func replaceJustTyped(count: Int, with text: String) {
        guard hasAccessibility, !isSecureInputEnabled, count > 0 else {
            copyToClipboard(text)
            return
        }
        selectBackwards(count: count)
        // Give the target app a moment to register the selection before the
        // paste lands on top of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            pasteViaClipboard(text)
        }
    }

    /// Shift+Left `count` times. Crude, but it is the only mechanism that works
    /// across native, web and terminal targets alike.
    private static func selectBackwards(count: Int) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let left = CGKeyCode(kVK_LeftArrow)
        // Cap it: a very long dictation is not worth thousands of events, and
        // the clipboard still holds the alternative.
        for _ in 0..<min(count, 2000) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: left, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: left, keyDown: false)
            else { return }
            down.flags = .maskShift
            up.flags = .maskShift
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private static func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown app"
    }

    // MARK: - Paste

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // The trigger key may still be physically held. Posting ⌘V while
        // Right-Option is down produces ⌥⌘V, which most apps ignore — so wait
        // for the modifiers to clear before synthesizing, and tell the event
        // source to ignore the local keyboard state as a second guard.
        waitForModifiersToClear {
            postCommandV()
            // Give the target app time to service the paste before putting the
            // old clipboard back. Restoring too early pastes the wrong thing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                restore(saved, ifUnchangedFrom: ourChangeCount)
            }
        }
    }

    private static func waitForModifiersToClear(
        attempt: Int = 0, then body: @escaping () -> Void
    ) {
        let blocking: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let held = NSEvent.modifierFlags.intersection(blocking)
        // Give up after ~0.4s: the user may simply be resting on a modifier,
        // and never pasting is worse than pasting with one held.
        if held.isEmpty || attempt >= 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: body)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                waitForModifiersToClear(attempt: attempt + 1, then: body)
            }
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        // Stop the user's currently-held physical modifiers from being merged
        // into the events we post.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Clipboard handling

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                // Reading a promised/lazy type here would force the owning app
                // to produce it; skipping them is better than stalling.
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    /// Puts the old clipboard back, but only if ours is still the most recent
    /// thing on it. If the user copied something while the paste was in flight,
    /// their copy wins.
    private static func restore(_ saved: PasteboardSnapshot, ifUnchangedFrom expected: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expected else {
            Log.log("clipboard changed during paste — leaving the user's copy alone")
            return
        }
        guard !saved.isEmpty else { return }

        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
