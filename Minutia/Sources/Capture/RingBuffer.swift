import Foundation
import os

/// Bounded mono Float32 ring buffer. Push from the audio callback, drain from the writer queue.
/// A single `os_unfair_lock` guards the index math and the bounded memcpy; nothing allocates in
/// push/pop beyond the caller-provided buffers.
final class RingBuffer {
    private var storage: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()

    private(set) var droppedFrames: Int64 = 0

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0, "capacityFrames must be positive")
        capacity = capacityFrames
        storage = [Float](repeating: 0, count: capacityFrames)
    }

    var availableFrames: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    /// Appends `count` samples, dropping the oldest frames on overflow and counting them.
    func push(_ samples: UnsafePointer<Float>, count pushCount: Int) {
        guard pushCount > 0 else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        // Only the newest `capacity` samples can survive.
        var srcOffset = 0
        var incoming = pushCount
        if incoming > capacity {
            let skip = incoming - capacity
            srcOffset = skip
            incoming = capacity
            droppedFrames += Int64(skip)
        }

        // Evict oldest frames to make room for the incoming ones.
        let overflow = count + incoming - capacity
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            count -= overflow
            droppedFrames += Int64(overflow)
        }

        var writeIndex = (readIndex + count) % capacity
        storage.withUnsafeMutableBufferPointer { dst in
            var remaining = incoming
            var src = srcOffset
            while remaining > 0 {
                let chunk = min(remaining, capacity - writeIndex)
                memcpy(dst.baseAddress! + writeIndex, samples + src, chunk * MemoryLayout<Float>.stride)
                writeIndex = (writeIndex + chunk) % capacity
                src += chunk
                remaining -= chunk
            }
        }
        count += incoming
    }

    /// Copies up to `popCount` frames into `buffer`, returning the number actually popped.
    func pop(into buffer: inout [Float], count popCount: Int) -> Int {
        guard popCount > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let toPop = min(popCount, count)
        guard toPop > 0 else { return 0 }

        storage.withUnsafeBufferPointer { src in
            buffer.withUnsafeMutableBufferPointer { dst in
                var remaining = toPop
                var read = readIndex
                var dstOffset = 0
                while remaining > 0 {
                    let chunk = min(remaining, capacity - read)
                    memcpy(dst.baseAddress! + dstOffset, src.baseAddress! + read, chunk * MemoryLayout<Float>.stride)
                    read = (read + chunk) % capacity
                    dstOffset += chunk
                    remaining -= chunk
                }
            }
        }
        readIndex = (readIndex + toPop) % capacity
        count -= toPop
        return toPop
    }
}
