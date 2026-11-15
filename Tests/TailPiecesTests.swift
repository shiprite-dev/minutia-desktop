import XCTest
import AVFoundation
@testable import Minutia

final class TailPiecesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailpieces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func speech(_ seconds: Double) -> [Float] {
        let step = 2.0 * Double.pi * 440.0 / 48_000.0
        return (0..<Int(48_000 * seconds)).map { Float(0.5 * sin(step * Double($0))) }
    }

    private func pause(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(48_000 * seconds))
    }

    private func append(_ writer: SegmentWriter, _ mic: [Float], tick: Double? = nil) throws {
        guard let tick else {
            _ = try writer.append(mic: mic, sys: [Float](repeating: 0, count: mic.count))
            return
        }
        let size = Int(48_000 * tick)
        var start = 0
        while start < mic.count {
            let slice = Array(mic[start..<min(start + size, mic.count)])
            _ = try writer.append(mic: slice, sys: [Float](repeating: 0, count: slice.count))
            start += size
        }
    }

    private func seconds(_ frames: Int64) -> Double { Double(frames) / 48_000 }

    private func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func assertReadablePieces(_ pieces: [SegmentWriter.ClosedSegment], file: StaticString = #filePath, line: UInt = #line) throws {
        for piece in pieces {
            for url in [piece.micURL, piece.sysURL] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
                XCTAssertFalse(url.lastPathComponent.hasPrefix("seg-"), "recovery must never mistake a piece for a window", file: file, line: line)
                XCTAssertEqual(try duration(of: url), seconds(piece.frames), accuracy: 0.3, file: file, line: line)
            }
        }
    }

    func test_aStopMidWindow_splitsTheTailAtTheFirstPauseAfterTwentySeconds() throws {
        let writer = try SegmentWriter(directory: dir)
        try append(writer, speech(25) + pause(0.5) + speech(29.5) + pause(0.5) + speech(39.5))

        let result = try writer.finish()

        let pieces = result.tailPieces
        XCTAssertEqual(pieces.map(\.seq), [0, 1, 2])
        XCTAssertEqual(seconds(pieces[0].frames), 25.2, accuracy: 0.2)
        XCTAssertEqual(pieces[1].offsetSeconds, seconds(pieces[0].frames), accuracy: 0.001)
        XCTAssertEqual(pieces[2].offsetSeconds, 55.2, accuracy: 0.2)
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.frames }, try XCTUnwrap(result.finalSegment).frames)
        try assertReadablePieces(pieces)
    }

    func test_aTailWithoutAPause_isCutEveryFortySeconds() throws {
        let writer = try SegmentWriter(directory: dir)
        try append(writer, speech(95))

        let pieces = try writer.finish().tailPieces

        XCTAssertEqual(pieces.map { seconds($0.frames) }, [40, 40, 15])
        XCTAssertEqual(pieces.map(\.offsetSeconds), [0, 40, 80])
        try assertReadablePieces(pieces)
    }

    func test_audioArrivingInSmallTicks_isCutTheSameWay() throws {
        let writer = try SegmentWriter(directory: dir)
        try append(writer, speech(95), tick: 0.1)

        let pieces = try writer.finish().tailPieces

        XCTAssertEqual(pieces.map { seconds($0.frames) }, [40, 40, 15])
    }

    func test_aShortTail_staysOneWindow() throws {
        let writer = try SegmentWriter(directory: dir)
        try append(writer, speech(15))

        let result = try writer.finish()

        XCTAssertTrue(result.tailPieces.isEmpty)
        XCTAssertEqual(seconds(try XCTUnwrap(result.finalSegment).frames), 15)
    }

    func test_tailPieces_continueTheWindowNumberingAndClock_andEarlierPiecesAreGone() throws {
        let writer = try SegmentWriter(directory: dir)
        try append(writer, speech(350))

        let pieces = try writer.finish().tailPieces

        XCTAssertEqual(pieces.map(\.seq), [1, 2])
        XCTAssertEqual(pieces.map(\.offsetSeconds), [300, 340])
        XCTAssertEqual(pieces.map { seconds($0.frames) }, [40, 10])
        let returned = Set(pieces.flatMap { [$0.micURL.lastPathComponent, $0.sysURL.lastPathComponent] })
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !$0.hasPrefix("seg-") && $0 != "recording.m4a" }
        XCTAssertEqual(Set(onDisk), returned, "pieces of a rotated window must be deleted")
    }

    func test_aWindowSegment_keepsItsFixedOffset() throws {
        let writer = try SegmentWriter(directory: dir)
        try append(writer, speech(10))
        let final = try XCTUnwrap(try writer.finish().finalSegment)
        XCTAssertEqual(final.offsetSeconds, 0)
        XCTAssertEqual(SegmentWriter.ClosedSegment(seq: 3, micURL: dir, sysURL: dir, frames: 1).offsetSeconds, 900)
    }
}
