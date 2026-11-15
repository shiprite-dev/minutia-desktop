import XCTest
@testable import Minutia

/// Every file the writer produces must stay readable audio if the process dies mid-recording, and
/// be a complete, readable file once closed.
final class CrashSafeCaptureTests: XCTestCase {
    private var dir: URL!

    /// Upper bound on audio a crash may lose: one fragment interval plus encoder latency.
    private let maxLossSeconds = 2.5

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crashsafe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sine(seconds: Double) -> [Float] {
        let step = 2.0 * Double.pi * 440.0 / 48_000.0
        return (0..<Int(48_000 * seconds)).map { Float(0.5 * sin(step * Double($0))) }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(48_000 * seconds))
    }

    func test_interruptedRecording_recordingAndOpenSegmentFilesStayReadable() async throws {
        let writer = try SegmentWriter(directory: dir)
        let written = 8.0
        for _ in 0..<Int(written * 4) {
            _ = try writer.append(mic: sine(seconds: 0.25), sys: silence(seconds: 0.25))
        }

        for name in ["recording.m4a", "seg-0-me.m4a", "seg-0-them.m4a"] {
            let duration = try await AudioFixtures.durationOfCrashCopy(
                dir.appendingPathComponent(name), atLeast: written - maxLossSeconds)
            let readable = try XCTUnwrap(duration, "\(name) is unreadable after an interruption")
            XCTAssertGreaterThanOrEqual(readable, written - maxLossSeconds, name)
            XCTAssertLessThanOrEqual(readable, written + 0.1, name)
        }
        _ = try writer.finish()
    }

    func test_finishedRecording_recordingAndFinalSegmentDurationsMatchFramesWritten() async throws {
        let writer = try SegmentWriter(directory: dir)
        _ = try writer.append(mic: sine(seconds: 7.5), sys: sine(seconds: 7.5))
        let result = try writer.finish()
        let final = try XCTUnwrap(result.finalSegment)
        XCTAssertEqual(result.recording.frames, 360_000)
        XCTAssertEqual(final.frames, 360_000)

        for url in [result.recording.fileURL, final.micURL, final.sysURL] {
            let duration = await AudioFixtures.assetDuration(url)
            XCTAssertEqual(try XCTUnwrap(duration, url.lastPathComponent), 7.5, accuracy: 0.1, url.lastPathComponent)
        }
    }

    func test_rotation_closedSegmentIsReadableTheMomentItIsReturned() async throws {
        let writer = try SegmentWriter(directory: dir)
        let closed = try writer.append(mic: sine(seconds: 301), sys: silence(seconds: 301))
        let segment = try XCTUnwrap(closed.first)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(segment.seq, 0)

        for url in [segment.micURL, segment.sysURL] {
            let duration = await AudioFixtures.assetDuration(url)
            XCTAssertEqual(try XCTUnwrap(duration, url.lastPathComponent), 300, accuracy: 0.1, url.lastPathComponent)
        }
        XCTAssertEqual(writer.currentSeq, 1)
        XCTAssertEqual(writer.totalFrames, 48_000 * 301)

        let result = try writer.finish()
        let final = try XCTUnwrap(result.finalSegment)
        XCTAssertEqual(final.seq, 1)
        let finalDuration = await AudioFixtures.assetDuration(final.micURL)
        XCTAssertEqual(try XCTUnwrap(finalDuration), 1, accuracy: 0.1)
        let recordingDuration = await AudioFixtures.assetDuration(result.recording.fileURL)
        XCTAssertEqual(try XCTUnwrap(recordingDuration), 301, accuracy: 0.1)
    }
}
