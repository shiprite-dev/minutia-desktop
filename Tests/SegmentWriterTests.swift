import XCTest
import AVFoundation
@testable import Minutia

final class SegmentWriterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("segwriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A block of `seconds` worth of 440Hz sine at 48k mono.
    private func sine(seconds: Double) -> [Float] {
        let count = Int(48_000 * seconds)
        var out = [Float](repeating: 0, count: count)
        let step = 2.0 * Double.pi * 440.0 / 48_000.0
        for i in 0..<count {
            out[i] = Float(0.5 * sin(step * Double(i)))
        }
        return out
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(48_000 * seconds))
    }

    /// Mic talks, system audio is silent: the common case the channel tests key on.
    @discardableResult
    private func appendMicOnly(_ writer: SegmentWriter, seconds: Double) throws -> [SegmentWriter.ClosedSegment] {
        try writer.append(mic: sine(seconds: seconds), sys: silence(seconds: seconds))
    }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func peak(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return 0
        }
        try file.read(into: buffer)
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][i])) }
        return peak
    }

    func test_shortAppend_noRotation() throws {
        let writer = try SegmentWriter(directory: dir)
        let closed = try appendMicOnly(writer, seconds: 10)
        XCTAssertTrue(closed.isEmpty)
        XCTAssertEqual(writer.totalFrames, 480_000)
        XCTAssertEqual(writer.currentSeq, 0)
    }

    func test_append301s_rotatesOnce_closingBothChannelFiles() throws {
        let writer = try SegmentWriter(directory: dir)
        let closed = try appendMicOnly(writer, seconds: 301)
        XCTAssertEqual(closed.count, 1)
        let seg = closed[0]
        XCTAssertEqual(seg.seq, 0)
        XCTAssertEqual(seg.frames, SegmentWriter.segmentFrames)
        for url in [seg.micURL, seg.sysURL] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try duration(of: url), 300, accuracy: 1.0)
            XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
        }
        XCTAssertEqual(writer.currentSeq, 1)
    }

    func test_append601s_inOneCall_surfacesBothRotations() throws {
        let writer = try SegmentWriter(directory: dir)
        let closed = try appendMicOnly(writer, seconds: 601)
        XCTAssertEqual(closed.map(\.seq), [0, 1])
        XCTAssertEqual(writer.totalFrames, 48_000 * 601)
    }

    func test_channelFiles_keepSourcesSeparate_recordingKeepsTheMix() throws {
        let writer = try SegmentWriter(directory: dir)
        try writer.append(mic: sine(seconds: 2), sys: silence(seconds: 2))
        try writer.append(mic: silence(seconds: 2), sys: sine(seconds: 2))
        let result = try writer.finish()
        let final = try XCTUnwrap(result.finalSegment)
        XCTAssertGreaterThan(try peak(of: final.micURL), 0.3, "mic file carries the mic signal")
        XCTAssertGreaterThan(try peak(of: final.sysURL), 0.3, "system file carries the system signal")
        XCTAssertGreaterThan(try peak(of: result.recording.fileURL), 0.3)
        XCTAssertEqual(try duration(of: final.micURL), 4, accuracy: 0.5)
        XCTAssertEqual(try duration(of: final.sysURL), 4, accuracy: 0.5)
        XCTAssertEqual(try duration(of: result.recording.fileURL), 4, accuracy: 0.5)
    }

    func test_silentSystemSource_yieldsSilentSystemFile() throws {
        let writer = try SegmentWriter(directory: dir)
        try appendMicOnly(writer, seconds: 2)
        let final = try XCTUnwrap(try writer.finish().finalSegment)
        XCTAssertLessThan(try peak(of: final.sysURL), 0.01)
    }

    func test_offsetSeconds_isSeqTimesSegmentLength() throws {
        XCTAssertEqual(SegmentWriter.segmentSeconds, 300)
        let writer = try SegmentWriter(directory: dir)
        let closed = try appendMicOnly(writer, seconds: 601)
        XCTAssertEqual(closed.map(\.offsetSeconds), [0, 300])
        let final = try XCTUnwrap(try writer.finish().finalSegment)
        XCTAssertEqual(final.offsetSeconds, 600)
    }

    func test_finish_after320s_returnsPartialSegmentAndRecording() throws {
        let writer = try SegmentWriter(directory: dir)
        try appendMicOnly(writer, seconds: 320)
        let result = try writer.finish()
        let final = try XCTUnwrap(result.finalSegment)
        XCTAssertEqual(final.seq, 1)
        XCTAssertEqual(try duration(of: final.micURL), 20, accuracy: 1.0)
        XCTAssertEqual(try duration(of: final.sysURL), 20, accuracy: 1.0)
        XCTAssertEqual(try duration(of: result.recording.fileURL), 320, accuracy: 1.0)
        XCTAssertEqual(result.recording.frames, 320 * 48_000)
    }

    func test_finish_exactlyOnBoundary_deletesBothEmptyChannelFiles() throws {
        let writer = try SegmentWriter(directory: dir)
        try appendMicOnly(writer, seconds: 300)
        let result = try writer.finish()
        XCTAssertNil(result.finalSegment)
        for name in ["seg-1-me.m4a", "seg-1-them.m4a"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), name)
        }
    }

    func test_finishImmediately_returnsNilFinalAndEmptyRecording() throws {
        let writer = try SegmentWriter(directory: dir)
        let result = try writer.finish()
        XCTAssertNil(result.finalSegment)
        XCTAssertEqual(result.recording.frames, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.recording.fileURL.path))
        XCTAssertEqual(try duration(of: result.recording.fileURL), 0, accuracy: 1.0)
    }

    func test_filesLandUnderDirectory_withChannelNames() throws {
        let writer = try SegmentWriter(directory: dir)
        try appendMicOnly(writer, seconds: 1)
        let result = try writer.finish()
        XCTAssertEqual(result.recording.fileURL.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(result.recording.fileURL.lastPathComponent, "recording.m4a")
        let final = try XCTUnwrap(result.finalSegment)
        XCTAssertEqual(final.micURL.lastPathComponent, "seg-0-me.m4a")
        XCTAssertEqual(final.sysURL.lastPathComponent, "seg-0-them.m4a")
    }
}
