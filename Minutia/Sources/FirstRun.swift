import Foundation
import ServiceManagement

/// A menu-bar-only app shows nothing when opened, and SwiftUI has no API to open a MenuBarExtra's
/// window, so the first launch points at the menu bar instead.
enum FirstRun {
    static let welcomedKey = "app.minutia.firstRunWelcomed"
    static let launchAtLoginDecidedKey = "app.minutia.launchAtLoginDecided"
    static let menuBarHint = "Minutia is in your menu bar, top right"

    /// True on the first launch of a fresh install only. An install with any earlier state predates
    /// this check: it is not welcomed and its login item choice is never overridden.
    static func isFirstLaunch(_ defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: welcomedKey) else { return false }
        defaults.set(true, forKey: welcomedKey)
        let earlierState = [DeviceIdentity.defaultsKey, InstanceConfig.storageKey, AppController.lastSeriesKey]
        guard earlierState.allSatisfy({ defaults.object(forKey: $0) == nil }) else {
            recordLaunchAtLoginChoice(defaults)
            return false
        }
        return true
    }

    /// A fresh install opens browser sign-in by itself once its instance connection is ready.
    static func opensSignIn(firstLaunch: Bool, signedIn: Bool) -> Bool {
        firstLaunch && !signedIn
    }

    /// Turns Launch at Login on at the first sign-in, once ever, unless the user already chose.
    static func defaultLaunchAtLogin(_ defaults: UserDefaults, status: SMAppService.Status, register: () throws -> Void) {
        guard !defaults.bool(forKey: launchAtLoginDecidedKey), status != .notFound else { return }
        if status == .notRegistered {
            guard (try? register()) != nil else { return }
        }
        recordLaunchAtLoginChoice(defaults)
    }

    static func recordLaunchAtLoginChoice(_ defaults: UserDefaults) {
        defaults.set(true, forKey: launchAtLoginDecidedKey)
    }
}
