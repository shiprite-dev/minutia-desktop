import XCTest
import CoreAudio
@testable import Minutia

final class SystemAudioDownmixTests: XCTestCase {
    private func downmix(_ channelsPerBuffer: [Int], _ samples: [[Float]]) -> [Float] {
        let abl = AudioBufferList.allocate(maximumBuffers: samples.count)
        defer { abl.unsafeMutablePointer.deallocate() }
        var storage = samples
        var out = [Float](repeating: -1, count: 64)
        let frames: Int = storage.withUnsafeMutableBufferPointer { rows in
            var pointers: [UnsafeMutablePointer<Float>] = []
            for i in rows.indices {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: rows[i].count)
                p.initialize(from: rows[i], count: rows[i].count)
                pointers.append(p)
                abl[i] = AudioBuffer(
                    mNumberChannels: UInt32(channelsPerBuffer[i]),
                    mDataByteSize: UInt32(rows[i].count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(p))
            }
            defer { pointers.forEach { $0.deallocate() } }
            return out.withUnsafeMutableBufferPointer { SystemAudioTap.downmix(abl, into: $0) }
        }
        return Array(out[0..<frames])
    }

    func test_twoMonoBuffers_keepEveryFrame() {
        XCTAssertEqual(downmix([1, 1], [[1, 2, 3, 4], [3, 2, 1, 0]]), [2, 2, 2, 2])
    }

    func test_oneInterleavedStereoBuffer_averagesPairs() {
        XCTAssertEqual(downmix([2], [[1, 3, 2, 4, 0, 0]]), [2, 3, 0])
    }

    func test_singleMonoBuffer_passesThrough() {
        XCTAssertEqual(downmix([1], [[0.5, -0.5, 0.25]]), [0.5, -0.5, 0.25])
    }

    func test_unequalBuffers_useTheShortest() {
        XCTAssertEqual(downmix([1, 1], [[2, 2, 2], [4, 4]]), [3, 3])
    }

    func test_output_isBoundedByTheScratchSize() {
        let long = [Float](repeating: 1, count: 100)
        XCTAssertEqual(downmix([1], [long]).count, 64)
    }

    func test_outputDeviceRateChange_triggersARebuild() {
        XCTAssertTrue(SystemAudioTap.outputDeviceRebuildSelectors.contains(kAudioDevicePropertyNominalSampleRate))
    }
}
