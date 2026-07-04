import ServiceManagement
import SwiftUI

/// App settings: instance connection, account, launch at login, and version.
/// Opens as the standard Settings window (Cmd+,) from the menu footer.
struct SettingsView: View {
    @ObservedObject var controller: AppController

    @State private var instanceText = ""
    @State private var busy = false
    @State private var statusMessage: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Instance") {
                TextField("https://minutia.example.com", text: $instanceText)
                    .textContentType(.URL)
                Button("Reconnect", action: reconnect)
                    .disabled(busy || InstanceConfig.normalize(instanceText) == nil)
                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Account") {
                if let email = controller.authManager.userEmail {
                    LabeledContent("Signed in as", value: email)
                    Button("Sign out") {
                        Task { await controller.authManager.signOut() }
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
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                Button("Check for Updates") {}
                    .disabled(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            if instanceText.isEmpty {
                instanceText = controller.authManager.instance?.absoluteString
                    ?? InstanceConfig.stored?.instance.absoluteString ?? ""
            }
        }
    }

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func reconnect() {
        guard let url = InstanceConfig.normalize(instanceText) else { return }
        busy = true
        statusMessage = nil
        Task {
            do {
                try await controller.authManager.connect(instance: url)
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
