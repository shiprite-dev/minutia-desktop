import XCTest
@testable import Minutia

/// When the recovery sweep runs. `RecoverySlot` is the pure bookkeeping AppController delegates to: a
/// request while a sweep runs or while a recording is starting is remembered, never lost; a start that
/// fails runs the remembered (or cancelled) sweep again; each remembered request reruns once, never in a
/// loop. A `true` from `runDidFinish` or `captureDidEnd` tells AppController to request a run now.
final class RecoverySlotTests: XCTestCase {
    private enum Event {
        case request(starts: Bool)
        case captureWillStart
        case captureDidEnd(recording: Bool, runs: Bool)
        case runDidFinish(reruns: Bool)
    }

    private let rows: [(label: String, events: [Event])] = [
        ("an idle request starts a sweep, and its end reruns nothing",
         [.request(starts: true), .runDidFinish(reruns: false)]),
        ("a request while a sweep runs is remembered and rerun once",
         [.request(starts: true), .request(starts: false), .runDidFinish(reruns: true),
          .request(starts: true), .runDidFinish(reruns: false)]),
        ("several requests while a sweep runs coalesce into one rerun",
         [.request(starts: true), .request(starts: false), .request(starts: false), .runDidFinish(reruns: true),
          .request(starts: true), .runDidFinish(reruns: false)]),
        ("a request during the rerun is remembered once more",
         [.request(starts: true), .request(starts: false), .runDidFinish(reruns: true),
          .request(starts: true), .request(starts: false), .runDidFinish(reruns: true),
          .request(starts: true), .runDidFinish(reruns: false)]),
        ("a request while a recording starts is remembered, and a failed start runs it",
         [.captureWillStart, .request(starts: false), .captureDidEnd(recording: false, runs: true),
          .request(starts: true), .runDidFinish(reruns: false)]),
        ("a request while a recording starts is dropped once it records, since its stop sweeps again",
         [.captureWillStart, .request(starts: false), .captureDidEnd(recording: true, runs: false),
          .request(starts: true), .runDidFinish(reruns: false)]),
        ("a sweep cancelled by a start that then fails runs again, the cancelled sweep ending first",
         [.request(starts: true), .captureWillStart, .runDidFinish(reruns: false),
          .captureDidEnd(recording: false, runs: true), .request(starts: true), .runDidFinish(reruns: false)]),
        ("a sweep cancelled by a start that fails before the cancelled sweep ends runs again when it ends",
         [.request(starts: true), .captureWillStart, .captureDidEnd(recording: false, runs: false),
          .runDidFinish(reruns: true), .request(starts: true), .runDidFinish(reruns: false)]),
        ("a sweep cancelled by a recording that starts is not rerun",
         [.request(starts: true), .captureWillStart, .runDidFinish(reruns: false),
          .captureDidEnd(recording: true, runs: false), .request(starts: true), .runDidFinish(reruns: false)]),
        ("a sweep cancelled by a recording that starts before the sweep ends is not rerun",
         [.request(starts: true), .captureWillStart, .captureDidEnd(recording: true, runs: false),
          .runDidFinish(reruns: false), .request(starts: true), .runDidFinish(reruns: false)]),
        ("a failed start with nothing remembered runs nothing",
         [.captureWillStart, .captureDidEnd(recording: false, runs: false), .request(starts: true), .runDidFinish(reruns: false)]),
        ("a request while a sweep runs and a recording starts reruns once, when the start fails",
         [.request(starts: true), .request(starts: false), .captureWillStart, .runDidFinish(reruns: false),
          .captureDidEnd(recording: false, runs: true), .request(starts: true), .runDidFinish(reruns: false)]),
    ]

    func test_recoverySlot_remembersEveryRequest_rerunsOncePerRequest_andClearsOnEveryPath() {
        for row in rows {
            var slot = RecoverySlot()
            for (index, event) in row.events.enumerated() {
                let step = "\(row.label), step \(index + 1)"
                switch event {
                case .request(let starts):
                    XCTAssertEqual(slot.requestRun(), starts, "\(step): requestRun")
                case .captureWillStart:
                    slot.captureWillStart()
                case .captureDidEnd(let recording, let runs):
                    XCTAssertEqual(slot.captureDidEnd(recording: recording), runs, "\(step): captureDidEnd(recording: \(recording))")
                case .runDidFinish(let reruns):
                    XCTAssertEqual(slot.runDidFinish(), reruns, "\(step): runDidFinish")
                }
            }
            XCTAssertFalse(slot.runDidFinish(), "\(row.label): nothing is left remembered")
            XCTAssertTrue(slot.requestRun(), "\(row.label): the slot is free again")
        }
    }

    /// The model-status changes that wake a deferred recovery: the model became ready, or it became
    /// unusable for good (failed, an Intel Mac, an unsupported macOS), so the deferred meetings stop
    /// waiting and finish in the cloud or are kept on this Mac with a notice.
    func test_shouldRunRecovery_wakesOnReady_andOnAModelThatWillNeverBeUsable() {
        let lowDisk = ModelBlockReason.lowDisk(requiredBytes: 2_000_000_000, freeBytes: 1_000_000_000)
        let rows: [(label: String, status: ModelStatus, runs: Bool)] = [
            ("ready", .ready(revision: "r1"), true),
            ("failed", .failed("verification failed"), true),
            ("an Intel Mac", .blocked(.intelMac), true),
            ("an unsupported macOS", .blocked(.unsupportedOS), true),
            ("idle", .idle, false),
            ("downloading", .downloading(received: 1, total: 2), false),
            ("warming", .warming, false),
            ("blocked by a recording", .blocked(.recording), false),
            ("warming after a recording", .blocked(.warmingAfterRecording), false),
            ("waiting for a non-metered network", .blocked(.expensiveNetwork), false),
            ("waiting for disk space", .blocked(lowDisk), false),
            ("no entry for the language", .blocked(.noEntryForLanguage), false),
        ]
        for row in rows {
            XCTAssertEqual(AppController.shouldRunRecovery(on: row.status), row.runs, row.label)
        }
    }
}
