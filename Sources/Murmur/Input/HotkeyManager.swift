import AppKit
import ApplicationServices

/// The user's chosen dictation trigger — any modifier/special key or a spare
/// mouse button (`keyCode` holds the button number when `isMouse`).
struct KeySpec: Codable, Equatable {
    var keyCode: UInt16
    var isModifier: Bool
    var isMouse: Bool
    var display: String

    init(keyCode: UInt16, isModifier: Bool, isMouse: Bool = false, display: String) {
        self.keyCode = keyCode
        self.isModifier = isModifier
        self.isMouse = isMouse
        self.display = display
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        isModifier = try c.decode(Bool.self, forKey: .isModifier)
        isMouse = try c.decodeIfPresent(Bool.self, forKey: .isMouse) ?? false
        display = try c.decode(String.self, forKey: .display)
    }

    static let defaultKey = KeySpec(keyCode: 61, isModifier: true, display: "Right \u{2325}")
}

enum KeyNames {
    /// Modifier keys selectable as triggers (keyCode → display).
    static let modifiers: [UInt16: String] = [
        54: "Right \u{2318}", 55: "Left \u{2318}",
        56: "Left \u{21E7}", 60: "Right \u{21E7}",
        58: "Left \u{2325}", 61: "Right \u{2325}",
        59: "Left \u{2303}", 62: "Right \u{2303}",
        63: "Fn / Globe",
    ]

    /// Non-modifier keys that are safe to claim globally: they never type a
    /// character or edit text, so swallowing them doesn't break typing.
    static let specials: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 114: "Help",
    ]

    static func modifierMask(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    static func nsModifierMask(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }

    static func isShiftKey(_ keyCode: UInt16) -> Bool {
        keyCode == 56 || keyCode == 60
    }

    /// Display name for mouse buttons (button numbers are 0-based; users know
    /// them 1-based: middle = button 3, then Mouse 4, Mouse 5, …).
    static func mouseName(_ buttonNumber: Int) -> String {
        buttonNumber == 2 ? "Middle Click" : "Mouse \(buttonNumber + 1)"
    }
}

/// Watches the configured trigger key globally via an active CGEventTap:
/// - hold = push-to-talk; quick tap or Shift+key = hands-free lock
/// - Return finishes a hands-free recording; Esc cancels any recording
/// - non-modifier trigger keys (and the consumed Return/Esc) are swallowed
///   so they don't reach the focused app
final class HotkeyManager {
    var trigger: KeySpec = .defaultKey
    var onPress: ((_ shiftHeld: Bool) -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    /// Return true to consume the keypress.
    var onEnter: (() -> Bool)?
    var onEscape: (() -> Bool)?

    private var pressedAt: Date?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitors: [Any] = []

    var usingEventTap: Bool { eventTap != nil }

    func start() {
        stop()
        let ax = AXIsProcessTrusted()
        let desc = "trigger=\(trigger.display) code=\(trigger.keyCode) modifier=\(trigger.isModifier) mouse=\(trigger.isMouse) ax=\(ax)"
        if startEventTap() {
            Log.log("hotkey armed: event tap ACTIVE, \(desc)")
        } else {
            startFallbackMonitors()
            Log.log("hotkey DEGRADED: event tap unavailable, using fallback monitors, \(desc)")
        }
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        pressedAt = nil
    }

    // MARK: - Event tap (primary path, needs Accessibility)

    private func startEventTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Runs on the main run loop. Keep it fast: decide synchronously whether to
    /// swallow, do the actual work async.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables the tap if a callback runs long or on certain user
            // input. If that happened while the trigger was held, the key-up
            // never arrives, `pressedAt` stays set, and every later press is
            // ignored because the down-edge check sees a press already in
            // progress — dictation silently stops working until relaunch.
            // Clearing the press state here is what makes recovery complete.
            if pressedAt != nil {
                pressedAt = nil
                Log.log("event tap was disabled mid-press — clearing stuck trigger state")
                DispatchQueue.main.async { self.onRelease?(0) }
            }
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.log("event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")

        case .flagsChanged:
            guard trigger.isModifier,
                  UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == trigger.keyCode,
                  let mask = KeyNames.modifierMask(for: trigger.keyCode)
            else { break }
            let down = event.flags.contains(mask)
            let shift = event.flags.contains(.maskShift) && !KeyNames.isShiftKey(trigger.keyCode)
            if down, pressedAt == nil {
                pressedAt = Date()
                Log.log("trigger DOWN (modifier, shift=\(shift))")
                DispatchQueue.main.async { self.onPress?(shift) }
            } else if !down, let t = pressedAt {
                pressedAt = nil
                let duration = Date().timeIntervalSince(t)
                Log.log("trigger UP after \(String(format: "%.2f", duration))s")
                DispatchQueue.main.async { self.onRelease?(duration) }
            }

        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if !trigger.isModifier, !trigger.isMouse, keyCode == trigger.keyCode {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                let shift = event.flags.contains(.maskShift)
                if pressedAt == nil {
                    pressedAt = Date()
                    Log.log("trigger DOWN (key, shift=\(shift))")
                    DispatchQueue.main.async { self.onPress?(shift) }
                }
                return nil
            }
            if keyCode == 36 || keyCode == 76, onEnter?() == true { return nil }
            if keyCode == 53, onEscape?() == true { return nil }

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if !trigger.isModifier, !trigger.isMouse, keyCode == trigger.keyCode {
                if let t = pressedAt {
                    pressedAt = nil
                    let duration = Date().timeIntervalSince(t)
                    DispatchQueue.main.async { self.onRelease?(duration) }
                }
                return nil
            }

        case .otherMouseDown:
            guard trigger.isMouse,
                  event.getIntegerValueField(.mouseEventButtonNumber) == Int64(trigger.keyCode)
            else { break }
            let shift = event.flags.contains(.maskShift)
            if pressedAt == nil {
                pressedAt = Date()
                Log.log("trigger DOWN (mouse, shift=\(shift))")
                DispatchQueue.main.async { self.onPress?(shift) }
            }
            return nil

        case .otherMouseUp:
            guard trigger.isMouse,
                  event.getIntegerValueField(.mouseEventButtonNumber) == Int64(trigger.keyCode)
            else { break }
            if let t = pressedAt {
                pressedAt = nil
                let duration = Date().timeIntervalSince(t)
                DispatchQueue.main.async { self.onRelease?(duration) }
            }
            return nil

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - NSEvent fallback (no Accessibility yet; modifier triggers only)

    private func startFallbackMonitors() {
        let flagsHandler: (NSEvent) -> Void = { [weak self] e in
            guard let self, trigger.isModifier, e.keyCode == trigger.keyCode,
                  let mask = KeyNames.nsModifierMask(for: trigger.keyCode) else { return }
            let down = e.modifierFlags.contains(mask)
            let shift = e.modifierFlags.contains(.shift) && !KeyNames.isShiftKey(trigger.keyCode)
            if down, pressedAt == nil {
                pressedAt = Date()
                onPress?(shift)
            } else if !down, let t = pressedAt {
                pressedAt = nil
                onRelease?(Date().timeIntervalSince(t))
            }
        }
        let keyHandler: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            if e.keyCode == 36 || e.keyCode == 76 { _ = onEnter?() }
            if e.keyCode == 53 { _ = onEscape?() }
        }
        let mouseHandler: (NSEvent) -> Void = { [weak self] e in
            guard let self, trigger.isMouse, e.buttonNumber == Int(trigger.keyCode) else { return }
            if e.type == .otherMouseDown, pressedAt == nil {
                pressedAt = Date()
                onPress?(e.modifierFlags.contains(.shift))
            } else if e.type == .otherMouseUp, let t = pressedAt {
                pressedAt = nil
                onRelease?(Date().timeIntervalSince(t))
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseUp], handler: mouseHandler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            flagsHandler(e)
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            keyHandler(e)
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { e in
            mouseHandler(e)
            return e
        } as Any)
    }
}
