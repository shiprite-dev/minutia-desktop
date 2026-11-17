import ServiceManagement
import XCTest
@testable import Minutia

/// A menu-bar-only app shows nothing when opened, so the very first launch points at the menu bar
/// once, and the first sign-in turns Launch at Login on once, never overriding the user's own choice.
final class FirstRunTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "FirstRunTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private final class Registrations {
        var count = 0
    }

    func test_aFreshInstall_isWelcomedOnTheFirstLaunchOnly() {
        XCTAssertTrue(FirstRun.isFirstLaunch(defaults))
        XCTAssertFalse(FirstRun.isFirstLaunch(defaults), "the menu bar hint never repeats")
    }

    /// Someone updating from an earlier build already knows where the app lives and may have turned
    /// Launch at Login off before: no welcome, and their login item choice is left alone.
    func test_anExistingInstall_isNotWelcomed_andItsLoginItemChoiceIsKept() {
        defaults.set(UUID().uuidString.lowercased(), forKey: DeviceIdentity.defaultsKey)
        XCTAssertFalse(FirstRun.isFirstLaunch(defaults))

        let registrations = Registrations()
        FirstRun.defaultLaunchAtLogin(defaults, status: .notRegistered) { registrations.count += 1 }
        XCTAssertEqual(registrations.count, 0)
    }

    func test_theFirstSignIn_turnsLaunchAtLoginOn() {
        _ = FirstRun.isFirstLaunch(defaults)
        let registrations = Registrations()
        FirstRun.defaultLaunchAtLogin(defaults, status: .notRegistered) { registrations.count += 1 }
        XCTAssertEqual(registrations.count, 1)
    }

    /// The default applies once: a later sign-in after the user turned it off never re-enables it.
    func test_laterSignIns_neverReenableLaunchAtLogin() {
        _ = FirstRun.isFirstLaunch(defaults)
        let registrations = Registrations()
        FirstRun.defaultLaunchAtLogin(defaults, status: .notRegistered) { registrations.count += 1 }
        FirstRun.defaultLaunchAtLogin(defaults, status: .notRegistered) { registrations.count += 1 }
        XCTAssertEqual(registrations.count, 1)
    }

    /// Toggling it in Settings before the first sign-in is the user's choice and wins.
    func test_aChoiceMadeInSettings_beforeTheFirstSignIn_isRespected() {
        _ = FirstRun.isFirstLaunch(defaults)
        FirstRun.recordLaunchAtLoginChoice(defaults)
        let registrations = Registrations()
        FirstRun.defaultLaunchAtLogin(defaults, status: .notRegistered) { registrations.count += 1 }
        XCTAssertEqual(registrations.count, 0)
    }

    func test_anAlreadyRegisteredLoginItem_isNotRegisteredAgain() {
        _ = FirstRun.isFirstLaunch(defaults)
        let registrations = Registrations()
        for status in [SMAppService.Status.enabled, .requiresApproval] {
            FirstRun.defaultLaunchAtLogin(defaults, status: status) { registrations.count += 1 }
        }
        XCTAssertEqual(registrations.count, 0)
    }

    func test_theMenuBarHint_pointsAtTheMenuBar() {
        XCTAssertEqual(FirstRun.menuBarHint, "Minutia is in your menu bar, top right")
    }
}
