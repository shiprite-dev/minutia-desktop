import XCTest
import Darwin
@testable import Minutia

/// A failing or stalled file must never freeze capture or hand a broken file to upload. Only the full
/// recording is essential: when a segment file fails, the recording continues without fast-lane
/// segments and the server transcribes the whole recording instead.
final class CaptureWriteFailureTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("writefail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func sine(seconds: Double) -> [Float] {
        let step = 2.0 * Double.pi * 440.0 / 48_000.0
        return (0..<Int(48_000 * seconds)).map { Float(0.5 * sin(step * Double($0))) }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(48_000 * seconds))
    }

    private func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Runs `body` while this process may not grow any file past `bytes`, the way a full disk refuses
    /// writes. SIGXFSZ is ignored so the refused write fails with EFBIG instead of killing the process.
    private func withFileSizeLimit(_ bytes: Int, _ body: () throws -> Void) rethrows {
        let previousHandler = signal(SIGXFSZ, SIG_IGN)
        var original = rlimit()
        getrlimit(RLIMIT_FSIZE, &original)
        var limited = original
        limited.rlim_cur = rlim_t(bytes)
        setrlimit(RLIMIT_FSIZE, &limited)
        defer {
            setrlimit(RLIMIT_FSIZE, &original)
            signal(SIGXFSZ, previousHandler)
        }
        try body()
    }

    private struct Box { let type: String; let offset: Int; let size: Int }

    private func topLevelBoxes(_ data: Data) -> [Box] {
        let bytes = [UInt8](data)
        func be(_ at: Int, _ count: Int) -> Int { (at..<at + count).reduce(0) { $0 << 8 | Int(bytes[$1]) } }
        var boxes: [Box] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            var size = be(offset, 4)
            if size == 1, offset + 16 <= bytes.count { size = be(offset + 8, 8) }
            if size == 0 { size = bytes.count - offset }
            guard size >= 8 else { break }
            boxes.append(Box(type: String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self), offset: offset, size: size))
            offset += size
        }
        return boxes
    }

    func test_aSlowWriterNeverStallsATickLongerThanTheRingKeepsAudio_soNoMeetingAudioIsLost() {
        XCTAssertGreaterThan(SegmentWriter.readyTimeout, 0)
        XCTAssertLessThan(SegmentWriter.readyTimeout, Double(CaptureSession.ringHeadroomSeconds))
    }

    func test_segmentCloseStallsAtRotation_recordingContinuesAndNoSegmentIsHandedOut() async throws {
        let writer = try SegmentWriter(directory: dir, closeTimeout: 0)

        var closed: [SegmentWriter.ClosedSegment] = []
        XCTAssertNoThrow(closed = try writer.append(mic: silence(seconds: 301), sys: silence(seconds: 301)))
        XCTAssertTrue(closed.isEmpty, "a segment whose close did not complete must never reach upload")
        XCTAssertTrue(writer.segmentsDropped)
        XCTAssertEqual(writer.totalFrames, 48_000 * 301)

        XCTAssertEqual(try writer.append(mic: sine(seconds: 4), sys: silence(seconds: 4)), [])
        XCTAssertEqual(writer.totalFrames, 48_000 * 305)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("seg-1-me.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("seg-1-them.m4a").path))

        let readable = try await AudioFixtures.durationOfCrashCopy(url("recording.m4a"), atLeast: 302.5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(readable, "recording stays readable"), 302.5)
        _ = try? writer.finish()
    }

    func test_finishWhoseCloseStalls_throwsInsteadOfReportingSuccess() throws {
        let writer = try SegmentWriter(directory: dir, closeTimeout: 0)
        _ = try writer.append(mic: sine(seconds: 2), sys: sine(seconds: 2))
        XCTAssertThrowsError(try writer.finish())
    }

    func test_segmentFilesCannotBeCreatedAtRotation_recordingContinuesWithoutSegments() async throws {
        let writer = try SegmentWriter(directory: dir)
        _ = try writer.append(mic: silence(seconds: 299), sys: silence(seconds: 299))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        var closed: [SegmentWriter.ClosedSegment] = []
        XCTAssertNoThrow(closed = try writer.append(mic: sine(seconds: 2), sys: silence(seconds: 2)))
        XCTAssertEqual(closed.map(\.seq), [0], "the completed segment is still handed out")
        XCTAssertTrue(writer.segmentsDropped)
        let segmentDuration = await AudioFixtures.assetDuration(try XCTUnwrap(closed.first).micURL)
        XCTAssertEqual(try XCTUnwrap(segmentDuration), 300, accuracy: 0.1)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try writer.append(mic: sine(seconds: 2), sys: silence(seconds: 2)), [])
        let result = try writer.finish()
        XCTAssertNil(result.finalSegment, "no trailing segment once segments stopped")
        XCTAssertEqual(result.recording.frames, 48_000 * 303)
        let recordingDuration = await AudioFixtures.assetDuration(result.recording.fileURL)
        XCTAssertEqual(try XCTUnwrap(recordingDuration), 303, accuracy: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("seg-1-me.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("seg-1-them.m4a").path))
    }

    func test_recordingWriteFailure_endsCaptureFast_andFinishThrows() async throws {
        let writer = try SegmentWriter(directory: dir)
        _ = try writer.append(mic: silence(seconds: 301), sys: silence(seconds: 301))
        let recordingURL = url("recording.m4a")

        var failure: Error?
        var failingCallSeconds = 0.0
        withFileSizeLimit(try fileSize(recordingURL) + 4_096) {
            for _ in 0..<80 {
                let start = Date()
                do { _ = try writer.append(mic: sine(seconds: 0.25), sys: silence(seconds: 0.25)) } catch {
                    failure = error
                    failingCallSeconds = Date().timeIntervalSince(start)
                    break
                }
                usleep(10_000)
            }
        }
        XCTAssertNotNil(failure, "a recording that cannot be written must end the capture")
        XCTAssertLessThan(failingCallSeconds, 1)

        let start = Date()
        XCTAssertThrowsError(try writer.append(mic: sine(seconds: 0.25), sys: silence(seconds: 0.25)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "a failed writer refuses work immediately")

        XCTAssertThrowsError(try writer.finish(), "a failed recording must never read as finished")
        let segmentDuration = await AudioFixtures.assetDuration(url("seg-1-me.m4a"))
        XCTAssertNotNil(segmentDuration, "finish still closes the other files")
        let recordingDuration = await AudioFixtures.assetDuration(recordingURL)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(recordingDuration, "audio before the failure stays readable"), 298)
    }

    func test_writerReleasedWithoutFinishing_leavesReadableFiles() async throws {
        var writer: SegmentWriter? = try SegmentWriter(directory: dir)
        for _ in 0..<32 {
            _ = try writer?.append(mic: sine(seconds: 0.25), sys: sine(seconds: 0.25))
        }
        writer = nil
        XCTAssertNil(writer)

        for name in ["recording.m4a", "seg-0-me.m4a", "seg-0-them.m4a"] {
            let duration = try await AudioFixtures.durationOfCrashCopy(url(name), atLeast: 5.5)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(duration, "\(name) unreadable"), 5.5, name)
        }
    }

    func test_crashCopyCutMidFragment_staysReadableWithinOneFragment() async throws {
        let writer = try SegmentWriter(directory: dir)
        for _ in 0..<40 {
            _ = try writer.append(mic: sine(seconds: 0.25), sys: silence(seconds: 0.25))
        }
        _ = try await AudioFixtures.durationOfCrashCopy(url("recording.m4a"), atLeast: 7.5)
        let bytes = try Data(contentsOf: url("recording.m4a"))
        try bytes.write(to: url("snapshot.m4a"))
        let snapshotDuration = await CaptureRecovery.readableAudioDuration(of: url("snapshot.m4a"))
        let whole = try XCTUnwrap(snapshotDuration)

        let boxes = topLevelBoxes(bytes)
        let lastFragment = try XCTUnwrap(boxes.lastIndex { $0.type == "moof" })
        XCTAssertGreaterThan(lastFragment, 0)
        for box in [boxes[lastFragment], boxes[lastFragment - 1]] {
            let cut = box.offset + box.size / 2
            try bytes.prefix(cut).write(to: url("cut.m4a"))
            let duration = await CaptureRecovery.readableAudioDuration(of: url("cut.m4a"))
            let readable = try XCTUnwrap(duration, "cut inside \(box.type) at \(cut) is unreadable")
            XCTAssertGreaterThanOrEqual(readable, whole - 2.5, "cut inside \(box.type)")
            XCTAssertLessThanOrEqual(readable, whole + 0.01, "cut inside \(box.type)")
        }
        _ = try writer.finish()
    }

    func test_expectedSegments_segmentsDroppedMidRecording_isNil() {
        XCTAssertNil(CaptureSession.expectedSegments(enqueued: 2, registered: 2, segmentsDropped: true))
        XCTAssertEqual(CaptureSession.expectedSegments(enqueued: 2, registered: 2, segmentsDropped: false), 2)
    }
}
