import AppKit
import ServiceManagement
import SwiftUI

/// App settings: instance connection, account, launch at login, and version.
/// Opens as the standard Settings window (Cmd+,) from the menu footer.
struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var authManager: AuthManager
    @ObservedObject private var updater: UpdaterController

    @State private var instanceText = ""
    @State private var busy = false
    @State private var statusMessage: String?
    @State private var launchAtLogin = SettingsView.loginItemState(SMAppService.mainApp.status) != .disabled
    @State private var loginRequiresApproval = SettingsView.loginItemState(SMAppService.mainApp.status) == .requiresApproval

    init(controller: AppController, updater: UpdaterController) {
        _controller = ObservedObject(wrappedValue: controller)
        _authManager = ObservedObject(wrappedValue: controller.authManager)
        _updater = ObservedObject(wrappedValue: updater)
    }

    var body: some View {
        Form {
            Section("Instance") {
                TextField("https://minutia.example.com", text: $instanceText)
                    .textContentType(.URL)
                HStack(spacing: 6) {
                    Circle()
                        .fill(authManager.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(authManager.isConnected
                         ? "Connected to \(connectedHost)"
                         : "Not connected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Reconnect", action: reconnect)
                    .disabled(busy || InstanceConfig.normalize(instanceText) == nil)
                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Account") {
                if let email = authManager.userEmail {
                    LabeledContent("Signed in as", value: email)
                    Button("Sign out") {
                        Task { await authManager.signOut() }
                    }
                    .disabled(AppController.shouldStopCaptureOnSignOut(phase: controller.phase))
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if loginRequiresApproval {
                    Link("Pending approval in System Settings > General > Login Items",
                         destination: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        .font(.callout)
                }
                if controller.notificationsDenied {
                    Link("Enable notifications for meeting prompts",
                         destination: URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        .font(.callout)
                }
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            activateForEditing()
            refreshLoginItemState()
            controller.refreshPermissionState()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .task {
            if instanceText.isEmpty {
                instanceText = authManager.instance?.absoluteString
                    ?? InstanceConfig.stored?.instance.absoluteString
                    ?? InstanceConfig.defaultInstance.absoluteString
            }
        }
    }

    private var connectedHost: String {
        authManager.instance?.host ?? authManager.instance?.absoluteString ?? ""
    }

    /// Login-item registration state distilled from `SMAppService.Status`. `.requiresApproval`
    /// (the user must approve the item in System Settings) is distinct from a plain OFF, so the
    /// UI can nudge instead of reading as disabled.
    enum LoginItemState: Equatable {
        case enabled
        case disabled
        case requiresApproval
    }

    nonisolated static func loginItemState(_ status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// A menu-bar (LSUIElement) app opens Settings without becoming active, so the window never
    /// takes key and text fields cannot focus. Promote to a regular app while Settings is open
    /// (restored to accessory on close) so the window is key and editable, with a Dock presence.
    private func activateForEditing() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reconnect() {
        guard let url = InstanceConfig.normalize(instanceText) else { return }
        busy = true
        statusMessage = nil
        Task {
            do {
                try await authManager.connect(instance: url)
                statusMessage = "Connected to \(url.host ?? url.absoluteString)."
            } catch {
                statusMessage = "Could not connect: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration failed (e.g. sandbox/test rig): fall through to reflect reality.
        }
        refreshLoginItemState()
    }

    /// Mirror the toggle and the pending-approval note to the real service status. `.requiresApproval`
    /// counts as ON (the user opted in; macOS is waiting on their approval), not OFF.
    private func refreshLoginItemState() {
        let state = SettingsView.loginItemState(SMAppService.mainApp.status)
        launchAtLogin = state != .disabled
        loginRequiresApproval = state == .requiresApproval
    }
}
