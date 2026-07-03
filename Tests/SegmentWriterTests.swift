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

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func test_shortAppend_noRotation() throws {
        let writer = try SegmentWriter(directory: dir)
        let closed = try writer.append(sine(seconds: 10))
        XCTAssertTrue(closed.isEmpty)
        XCTAssertEqual(writer.totalFrames, 480_000)
        XCTAssertEqual(writer.currentSeq, 0)
    }

    func test_append301s_rotatesOnce() throws {
        let writer = try SegmentWriter(directory: dir)
        let closed = try writer.append(sine(seconds: 301))
        XCTAssertEqual(closed.count, 1)
        let seg = closed[0]
        XCTAssertEqual(seg.seq, 0)
        XCTAssertEqual(seg.frames, SegmentWriter.segmentFrames)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seg.fileURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: seg.fileURL.path)
        XCTAssertGreaterThan((attrs[.size] as? Int) ?? 0, 0)
        XCTAssertEqual(try duration(of: seg.fileURL), 300, accuracy: 1.0)
        XCTAssertEqual(writer.currentSeq, 1)
        XCTAssertEqual(seg.fileURL.deletingLastPathComponent().path, dir.path)
    }

    func test_append601s_inOneCall_surfacesBothRotations() throws {
        let writer = try SegmentWriter(directory: dir)
        let closed = try writer.append(sine(seconds: 601))
        XCTAssertEqual(closed.map(\.seq), [0, 1])
        XCTAssertEqual(writer.totalFrames, 48_000 * 601)
    }

    func test_finish_after320s_returnsPartialSegmentAndRecording() throws {
        let writer = try SegmentWriter(directory: dir)
        _ = try writer.append(sine(seconds: 320))
        let result = try writer.finish()
        let final = try XCTUnwrap(result.finalSegment)
        XCTAssertEqual(final.seq, 1)
        XCTAssertEqual(try duration(of: final.fileURL), 20, accuracy: 1.0)
        XCTAssertEqual(try duration(of: result.recording.fileURL), 320, accuracy: 1.0)
        XCTAssertEqual(result.recording.frames, 320 * 48_000)
    }

    func test_finish_exactlyOnBoundary_deletesEmptySegmentFile() throws {
        let writer = try SegmentWriter(directory: dir)
        _ = try writer.append(sine(seconds: 300))
        let result = try writer.finish()
        XCTAssertNil(result.finalSegment)
        let orphan = dir.appendingPathComponent("seg-1.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func test_finishImmediately_returnsNilFinalAndEmptyRecording() throws {
        let writer = try SegmentWriter(directory: dir)
        let result = try writer.finish()
        XCTAssertNil(result.finalSegment)
        XCTAssertEqual(result.recording.frames, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.recording.fileURL.path))
        XCTAssertEqual(try duration(of: result.recording.fileURL), 0, accuracy: 1.0)
    }

    func test_filesLandUnderDirectory() throws {
        let writer = try SegmentWriter(directory: dir)
        _ = try writer.append(sine(seconds: 1))
        let result = try writer.finish()
        XCTAssertEqual(result.recording.fileURL.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(result.recording.fileURL.lastPathComponent, "recording.m4a")
        let final = try XCTUnwrap(result.finalSegment)
        XCTAssertEqual(final.fileURL.lastPathComponent, "seg-0.m4a")
    }
}
