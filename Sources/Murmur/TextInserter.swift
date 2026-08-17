import AppKit
import ApplicationServices

/// Inserts text into the frontmost app by pasting, then restores the
/// user's previous clipboard contents.
enum TextInserter {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptForAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Returns true if the text was pasted; false means it was only copied
    /// to the clipboard (no accessibility permission yet).
    @discardableResult
    static func insert(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var entry = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        guard hasAccessibility else { return false }

        // Small delay so the released hotkey modifier isn't OR'd into the paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postCmdV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                restore(saved)
            }
        }
        return true
    }

    private static func postCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        guard !saved.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }
}
