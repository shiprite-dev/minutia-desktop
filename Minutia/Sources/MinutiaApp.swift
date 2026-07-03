import SwiftUI

@main
struct MinutiaApp: App {
    var body: some Scene {
        MenuBarExtra("Minutia", systemImage: "waveform") {
            Text("Minutia")
        }
        .menuBarExtraStyle(.window)
    }
}
