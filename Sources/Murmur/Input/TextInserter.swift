import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts transcribed text into whatever app is frontmost.
///
/// Three strategies, tried in order of how cleanly they behave:
///
/// 1. **Accessibility** — set the focused element's selected text directly.
///    Nothing touches the clipboard and nothing synthesizes keystrokes, so
///    there is no race and no visible paste. Many apps decline it.
/// 2. **Clipboard + ⌘V** — the universal fallback. The clipboard is restored
///    afterwards, but only if nothing else claimed it in the meantime.
/// 3. **Clipboard only** — when text cannot be delivered (no Accessibility
///    permission, or secure input is active), leave it on the clipboard and
///    tell the user.
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

        if insertViaAccessibility(text) {
            Log.log("inserted via accessibility API")
            return .inserted
        }

        pasteViaClipboard(text)
        Log.log("inserted via clipboard paste")
        return .inserted
    }

    // MARK: - Strategy 1: Accessibility

    /// Replaces the focused element's selection (or inserts at the caret) with
    /// `text`. Returns false when the focused element does not support it,
    /// which is common in Electron apps and terminals.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return false }

        let target = element as! AXUIElement

        // Only text-bearing roles: setting selected text on, say, a button does
        // nothing useful and can confuse the app.
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &roleValue)
        let role = (roleValue as? String) ?? ""
        let textRoles: Set<String> = [
            kAXTextFieldRole as String, kAXTextAreaRole as String,
            kAXComboBoxRole as String, "AXSearchField",
        ]
        guard textRoles.contains(role) else { return false }

        // Refuse web content, even though it advertises itself as writable.
        //
        // Chromium reports kAXSelectedText as settable for ordinary web text
        // fields, but writing it goes around the DOM's input pipeline: the
        // editor's model never sees the change, so React, Slack, Notion,
        // CodeMirror and Monaco either drop the text on the next render or
        // duplicate it. That covers most apps people dictate into, and the
        // failure is silent, so anything under a web area gets pasted instead.
        guard !isInsideWebContent(target) else { return false }

        // Never type into a password field, even if we somehow have focus.
        var subroleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXSubroleAttribute as CFString, &subroleValue)
        if (subroleValue as? String) == (kAXSecureTextFieldSubrole as String) { return false }

        // The element must actually be editable and support selected-text writes.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            target, kAXSelectedTextAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { return false }

        let status = AXUIElementSetAttributeValue(
            target, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return status == .success
    }

    /// Walks up the accessibility tree looking for a web area, which marks the
    /// element as browser-rendered rather than a native AppKit control.
    /// Bounded because some hierarchies are deep and this runs in the hot path.
    private static func isInsideWebContent(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<12 {
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                current, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String,
               role == "AXWebArea" || role == "AXScrollArea" && isWebScrollArea(current) {
                return role == "AXWebArea"
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current, kAXParentAttribute as CFString, &parentValue) == .success,
                let parent = parentValue, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return false }
            current = parent as! AXUIElement
        }
        return false
    }

    private static func isWebScrollArea(_ element: AXUIElement) -> Bool {
        var description: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element, kAXRoleDescriptionAttribute as CFString, &description)
        return (description as? String)?.localizedCaseInsensitiveContains("html") ?? false
    }

    // MARK: - Strategy 2: clipboard + paste

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
