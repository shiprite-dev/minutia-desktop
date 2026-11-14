import XCTest
import CoreAudio
@testable import Minutia

/// A buffer the HAL delivers without data must cost only that buffer, never the whole callback.
final class SystemAudioDownmixNilBufferTests: XCTestCase {
    private func downmix(_ buffers: [(channels: Int, samples: [Float]?)]) -> [Float] {
        let abl = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { abl.unsafeMutablePointer.deallocate() }
        var pointers: [UnsafeMutablePointer<Float>] = []
        defer { pointers.forEach { $0.deallocate() } }
        for (i, buffer) in buffers.enumerated() {
            if let samples = buffer.samples {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
                p.initialize(from: samples, count: samples.count)
                pointers.append(p)
                abl[i] = AudioBuffer(
                    mNumberChannels: UInt32(buffer.channels),
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(p))
            } else {
                abl[i] = AudioBuffer(mNumberChannels: UInt32(buffer.channels), mDataByteSize: 0, mData: nil)
            }
        }
        var out = [Float](repeating: -1, count: 64)
        let frames = out.withUnsafeMutableBufferPointer { SystemAudioTap.downmix(abl, into: $0) }
        return Array(out[0..<frames])
    }

    func test_nilSecondBuffer_keepsTheFirst() {
        XCTAssertEqual(downmix([(1, [1, 2, 3, 4]), (1, nil)]), [1, 2, 3, 4])
    }

    func test_nilFirstBuffer_keepsTheSecond() {
        XCTAssertEqual(downmix([(1, nil), (2, [1, 3, 5, 7])]), [2, 6])
    }

    func test_nilBufferBetweenTwo_averagesOnlyTheDelivered() {
        XCTAssertEqual(downmix([(1, [2, 2]), (1, nil), (1, [4, 4])]), [3, 3])
    }

    func test_everyBufferNil_yieldsNothing() {
        XCTAssertEqual(downmix([(1, nil), (2, nil)]), [])
    }
}
