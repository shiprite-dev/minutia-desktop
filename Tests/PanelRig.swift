import AVFoundation
import SwiftUI
import XCTest
@testable import Minutia

@MainActor
final class PanelRig {
    let weekly = Series(id: UUID(), name: "Weekly Eng Sync")
    let boardPrep = Series(id: UUID(), name: "Board prep")
    let instance = URL(string: "https://minutia.example.com")!
    let updater = UpdaterController()
    private(set) var opened: [URL] = []
    private(set) var announcements: [String] = []
    private let suite = "PanelRig.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private var controllers: [AppController] = []
    private let mic: (AVAuthorizationStatus, Bool)

    init(mic: (AVAuthorizationStatus, Bool) = (.authorized, true)) {
        self.mic = mic
        defaults = UserDefaults(suiteName: suite)!
    }

    func tearDown() {
        for controller in controllers {
            controller.handleDetection(.none)
            controller.authManager.cancelBrowserSignIn()
        }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
    }

    func controller() -> AppController {
        let controller = AppController(
            defaults: defaults, openURL: { [weak self] in self?.opened.append($0) }, micCheck: { [mic] in mic })
        controller.announce = { [weak self] in self?.announcements.append($0) }
        controllers.append(controller)
        return controller
    }

    func signedIn(series: [Series]? = nil) -> AppController {
        let controller = controller()
        controller.apply(.signedIn)
        controller.seriesLoaded(series ?? [weekly, boardPrep])
        return controller
    }

    func menu(_ controller: AppController) -> MenuContent {
        MenuContent(controller: controller, updater: updater)
    }

    func panel(_ controller: AppController, dark: Bool = false, scale: Int = 3) -> Seen {
        Host.text(menu(controller), dark: dark, scale: scale)
    }

    func sentCue() -> RecapCue { RecapCue(meetingId: UUID(), seriesId: boardPrep.id, instance: instance) }

    func finishCleanly(_ controller: AppController, cue: RecapCue?) {
        controller.apply(.recordStarted)
        controller.apply(.recordStopped)
        controller.apply(.finalized)
        controller.presentRecapCue(cue)
    }
}
