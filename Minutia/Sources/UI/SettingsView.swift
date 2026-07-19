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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
        .onAppear(perform: activateForEditing)
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
            // Registration failed (e.g. sandbox/test rig): reflect reality, not the toggle.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
