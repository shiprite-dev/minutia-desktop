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
    @State private var loginItemError: String?
    @AppStorage(TranscriptionSetting.defaultsKey) private var transcriptionSetting: TranscriptionSetting = .automatic
    @AppStorage(WebStartPolicy.defaultsKey) private var webStartPolicy = WebStartPolicy.ask.rawValue

    init(controller: AppController, updater: UpdaterController) {
        _controller = ObservedObject(wrappedValue: controller)
        _authManager = ObservedObject(wrappedValue: controller.authManager)
        _updater = ObservedObject(wrappedValue: updater)
    }

    var body: some View {
        Form {
            Section("Instance") {
                TextField(InstanceConfig.defaultInstance.absoluteString, text: $instanceText)
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
                    .disabled(busy || InstanceConfig.normalize(instanceText) == nil || captureInFlight)
                if captureInFlight {
                    Text("Finish the recording before switching servers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
                    .disabled(captureInFlight)
                    if captureInFlight {
                        Text("Stop the recording to sign out.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
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
                Toggle("Start recording automatically when I start a meeting on the web", isOn: Binding(
                    get: { webStartPolicy == WebStartPolicy.always.rawValue },
                    set: { webStartPolicy = ($0 ? WebStartPolicy.always : .ask).rawValue }))
                if loginRequiresApproval {
                    Link("Pending approval in System Settings > General > Login Items",
                         destination: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        .font(.callout)
                }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if controller.notificationsDenied {
                    Link("Enable notifications for meeting prompts",
                         destination: URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        .font(.callout)
                }
            }

            Section("Transcription") {
                if TranscriptionRouter.isDeviceRoutingEnabled(.standard) {
                    Picker("Transcription", selection: $transcriptionSetting) {
                        ForEach(TranscriptionSetting.allCases, id: \.self) { Text($0.title) }
                    }
                    TranscriptionReasonText(controller: controller)
                }
                ModelStatusText(store: controller.modelStore)
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                if updater.updateAvailable {
                    Button("Update available: install now") { updater.checkForUpdates() }
                }
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Text(Self.speechAttribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        // Login-item and permission state can change out from under an open Settings window (the user
        // toggles the item or grants a permission in System Settings, then returns). Re-read both when
        // the window regains key, so the toggle and nudges reflect reality instead of a stale snapshot.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshLoginItemState()
            controller.refreshPermissionState()
        }
        .task {
            if instanceText.isEmpty {
                instanceText = authManager.instance?.absoluteString
                    ?? InstanceConfig.stored?.instance.absoluteString
                    ?? InstanceConfig.defaultInstance.absoluteString
            }
        }
        // Re-verify the live connection whenever Settings appears, so the dot reflects reality
        // (e.g. the instance went down since launch) instead of a stale one-time snapshot.
        .task { await authManager.verifyConnection() }
    }

    private var connectedHost: String {
        authManager.instance?.host ?? authManager.instance?.absoluteString ?? ""
    }

    /// True while a recording is live or finalizing. Reused to block both Reconnect and Sign out:
    /// switching servers or dropping the session mid-capture would strand the in-flight upload.
    private var captureInFlight: Bool {
        AppController.shouldStopCaptureOnSignOut(phase: controller.phase)
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

    static let speechAttribution =
        "On-device speech recognition: Parakeet Ultra by moondream (CC BY 4.0), a post-training of NVIDIA Parakeet TDT 0.6B v3 (CC BY 4.0); Core ML conversion by FluidInference (CC BY 4.0); FluidAudio (Apache 2.0)."

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
                statusMessage = AuthManager.connectFailureMessage(for: error, host: url.host)
            }
            busy = false
        }
    }

    /// Inline copy for a failed login-item registration change, so the toggle snapping back is
    /// explained instead of silent.
    nonisolated static func loginItemErrorMessage(for error: Error) -> String {
        "Couldn't update Login Item: \(error.localizedDescription)"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            // Surface the failure inline: without it the toggle silently snaps back to the real
            // service state (via refreshLoginItemState) with no explanation.
            loginItemError = Self.loginItemErrorMessage(for: error)
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

private struct TranscriptionReasonText: View {
    let controller: AppController
    @ObservedObject private var store: ModelStore

    init(controller: AppController) {
        self.controller = controller
        _store = ObservedObject(wrappedValue: controller.modelStore)
    }

    var body: some View {
        Text(controller.transcriptionDecision().summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ModelStatusText: View {
    @ObservedObject var store: ModelStore

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        switch store.status {
        case .idle: "The on-device model has not been set up yet."
        case .blocked(let reason): reason.settingsText
        case .downloading: store.status.menuLabel ?? "Downloading the on-device model."
        case .warming: "Preparing the on-device model."
        case .ready: "The on-device model is ready."
        case .failed(let message): message
        }
    }
}
