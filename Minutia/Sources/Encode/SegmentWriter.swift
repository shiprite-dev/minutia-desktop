import Foundation
import AVFoundation

/// Writes mixed mono 48k PCM to the rotating segment file AND the continuous full recording file.
/// Every file is AAC in an .m4a container; PCM is handed over via an `AVAudioPCMBuffer` in the
/// file's `processingFormat`.
final class SegmentWriter {
    static let segmentFrames: Int64 = 48_000 * 300   // 5 minutes

    struct ClosedSegment: Equatable {
        let seq: Int
        let fileURL: URL
        let frames: Int64
    }

    private static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 48_000,
    ]

    private static let chunkFrames = 48_000   // bounds per-write buffer allocation to ~1s

    private let directory: URL
    private let format: AVAudioFormat
    private let recordingURL: URL
    private var recordingFile: AVAudioFile?
    private var segmentFile: AVAudioFile?
    private var segmentFrameCount: Int64 = 0

    private(set) var currentSeq: Int = 0
    private(set) var totalFrames: Int64 = 0

    init(directory: URL) throws {
        self.directory = directory
        recordingURL = directory.appendingPathComponent("recording.m4a")
        let recording = try AVAudioFile(forWriting: recordingURL, settings: SegmentWriter.fileSettings)
        recordingFile = recording
        format = recording.processingFormat
        segmentFile = try openSegment(seq: 0)
    }

    private func segmentURL(_ seq: Int) -> URL {
        directory.appendingPathComponent("seg-\(seq).m4a")
    }

    private func openSegment(seq: Int) throws -> AVAudioFile {
        try AVAudioFile(forWriting: segmentURL(seq), settings: SegmentWriter.fileSettings)
    }

    private func write(_ samples: [Float], from start: Int, count: Int, to file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw NSError(domain: "SegmentWriter", code: 1)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { src in
            memcpy(buffer.floatChannelData![0], src.baseAddress! + start, count * MemoryLayout<Float>.stride)
        }
        try file.write(from: buffer)
    }

    /// Appends samples to both files, rotating the segment file when it fills. Returns the closed
    /// segment when a rotation happened this call (tick sizing guarantees at most one boundary).
    func append(_ samples: [Float]) throws -> ClosedSegment? {
        guard !samples.isEmpty, segmentFile != nil, let recording = recordingFile else {
            return nil
        }
        var idx = 0
        var closed: ClosedSegment? = nil
        var active = segmentFile!
        while idx < samples.count {
            let remainInSegment = Int(SegmentWriter.segmentFrames - segmentFrameCount)
            let chunk = min(samples.count - idx, remainInSegment, SegmentWriter.chunkFrames)
            try write(samples, from: idx, count: chunk, to: active)
            try write(samples, from: idx, count: chunk, to: recording)
            segmentFrameCount += Int64(chunk)
            totalFrames += Int64(chunk)
            idx += chunk

            if segmentFrameCount == SegmentWriter.segmentFrames {
                closed = ClosedSegment(seq: currentSeq, fileURL: segmentURL(currentSeq), frames: segmentFrameCount)
                currentSeq += 1
                segmentFrameCount = 0
                active = try openSegment(seq: currentSeq)
                segmentFile = active
            }
        }
        return closed
    }

    /// Closes both files. Returns the trailing partial segment (nil when it holds no frames) and the
    /// full recording.
    func finish() throws -> (finalSegment: ClosedSegment?, recording: ClosedSegment) {
        let partialFrames = segmentFrameCount
        let seq = currentSeq
        let recordingFrames = totalFrames
        segmentFile = nil
        recordingFile = nil

        let finalSegment = partialFrames > 0
            ? ClosedSegment(seq: seq, fileURL: segmentURL(seq), frames: partialFrames)
            : nil
        let recording = ClosedSegment(seq: -1, fileURL: recordingURL, frames: recordingFrames)
        return (finalSegment, recording)
    }
}
