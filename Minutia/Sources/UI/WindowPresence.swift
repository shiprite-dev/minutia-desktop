import AppKit

/// Owns the Dock icon for the menu-bar app. A menu-bar app opens windows without becoming active,
/// so they never take key and text fields cannot focus; while any window (Settings, notes, the recap) is
/// open the app is a regular app with a Dock icon and in Cmd-Tab, and it goes back to menu-bar only
/// after the last one closes, so closing one never drops the icon while another is still open.
@MainActor
final class WindowPresence {
    static let shared = WindowPresence(
        setPolicy: { NSApp.setActivationPolicy($0) }, activate: { NSApp.activate(ignoringOtherApps: true) })

    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private let activate: () -> Void
    private var open: Set<String> = []

    init(setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void, activate: @escaping () -> Void) {
        self.setPolicy = setPolicy
        self.activate = activate
    }

    /// `activate: false` keeps a window that must not steal focus (the notes panel during a call)
    /// from pulling the app in front.
    func opened(_ id: String, activate: Bool = true) {
        if open.isEmpty { setPolicy(.regular) }
        open.insert(id)
        if activate { self.activate() }
    }

    func closed(_ id: String) {
        guard open.remove(id) != nil, open.isEmpty else { return }
        setPolicy(.accessory)
    }
}
