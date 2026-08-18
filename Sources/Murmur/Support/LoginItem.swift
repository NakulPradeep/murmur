import Foundation
import ServiceManagement

/// Registers Murmur to start at login.
///
/// A dictation app is only useful if it is already running when you want to
/// talk, so this matters more here than for most apps. `SMAppService` handles
/// it without a helper bundle or a login-items shim, but it throws when the app
/// is run from a build directory rather than /Applications, so failures are
/// reported rather than swallowed.
enum LoginItem {

    static var isEnabled: Bool {
        guard #available(macOS 13, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static var isSupported: Bool {
        if #available(macOS 13, *) { return true }
        return false
    }

    /// Returns nil on success, or a message explaining why it did not work.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        guard #available(macOS 13, *) else {
            return "Needs macOS 13 or later."
        }
        do {
            if enabled {
                // Re-registering an already-registered app throws; treat that
                // as success rather than surfacing a confusing error.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            Log.log("launch at login: \(enabled ? "enabled" : "disabled")")
            return nil
        } catch {
            Log.log("launch at login FAILED: \(error.localizedDescription)")
            // The usual cause is running from a build folder; macOS will only
            // register an app it considers installed.
            return "Move Murmur to your Applications folder first, then try again."
        }
    }

    /// Brings the stored preference back in line with reality — the user can
    /// remove the login item in System Settings without the app knowing.
    static func reconcilePreference() {
        guard isSupported else { return }
        let actual = isEnabled
        if Prefs.defaults.bool(forKey: PrefKey.launchAtLogin) != actual {
            Prefs.defaults.set(actual, forKey: PrefKey.launchAtLogin)
        }
    }
}
