import XCTest
@testable import Minutia

final class RingBufferTests: XCTestCase {
    private func push(_ ring: RingBuffer, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { ring.push($0.baseAddress!, count: $0.count) }
    }

    func test_pushPop_roundTripSampleExact() {
        let ring = RingBuffer(capacityFrames: 8)
        push(ring, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(ring.availableFrames, 4)

        var out = [Float](repeating: 0, count: 4)
        let popped = ring.pop(into: &out, count: 4)
        XCTAssertEqual(popped, 4)
        XCTAssertEqual(out, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(ring.availableFrames, 0)
    }

    func test_wraparound_atCapacity() {
        let ring = RingBuffer(capacityFrames: 8)
        push(ring, [1, 2, 3, 4, 5, 6])
        var first = [Float](repeating: 0, count: 4)
        XCTAssertEqual(ring.pop(into: &first, count: 4), 4)
        XCTAssertEqual(first, [1, 2, 3, 4])

        // Writing past the physical end forces the write index to wrap.
        push(ring, [7, 8, 9, 10])
        XCTAssertEqual(ring.availableFrames, 6)
        var out = [Float](repeating: 0, count: 6)
        XCTAssertEqual(ring.pop(into: &out, count: 6), 6)
        XCTAssertEqual(out, [5, 6, 7, 8, 9, 10])
        XCTAssertEqual(ring.droppedFrames, 0)
    }

    func test_overflow_dropsOldest_andCounts() {
        let ring = RingBuffer(capacityFrames: 4)
        push(ring, [1, 2, 3, 4])
        push(ring, [5, 6])   // drops 1, 2
        XCTAssertEqual(ring.droppedFrames, 2)
        XCTAssertEqual(ring.availableFrames, 4)

        var out = [Float](repeating: 0, count: 4)
        XCTAssertEqual(ring.pop(into: &out, count: 4), 4)
        XCTAssertEqual(out, [3, 4, 5, 6])
    }

    func test_overflow_pushLargerThanCapacity_keepsNewest() {
        let ring = RingBuffer(capacityFrames: 4)
        push(ring, [1, 2, 3, 4, 5, 6])   // only newest 4 survive
        XCTAssertEqual(ring.droppedFrames, 2)
        XCTAssertEqual(ring.availableFrames, 4)
        var out = [Float](repeating: 0, count: 4)
        XCTAssertEqual(ring.pop(into: &out, count: 4), 4)
        XCTAssertEqual(out, [3, 4, 5, 6])
    }

    func test_popBeyondAvailable_returnsShortCount() {
        let ring = RingBuffer(capacityFrames: 8)
        push(ring, [1, 2, 3])
        var out = [Float](repeating: -1, count: 5)
        let popped = ring.pop(into: &out, count: 5)
        XCTAssertEqual(popped, 3)
        XCTAssertEqual(Array(out.prefix(3)), [1, 2, 3])
        XCTAssertEqual(ring.availableFrames, 0)
    }
}
