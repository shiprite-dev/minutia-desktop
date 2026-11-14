import Foundation
import AVFoundation

/// Writes each rotating segment as two mono files (microphone, system audio) AND the continuous mixed
/// full recording. Every file is AAC in an .m4a container; PCM is handed over via an
/// `AVAudioPCMBuffer` in the file's `processingFormat`.
final class SegmentWriter {
    static let segmentSeconds: Double = 300
    static let segmentFrames: Int64 = 48_000 * Int64(segmentSeconds)

    struct ClosedSegment: Equatable {
        let seq: Int
        let micURL: URL
        let sysURL: URL
        let frames: Int64
        var offsetSeconds: Double { Double(seq) * SegmentWriter.segmentSeconds }
    }

    struct Recording {
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
    private var micFile: AVAudioFile?
    private var sysFile: AVAudioFile?
    private var segmentFrameCount: Int64 = 0

    private(set) var currentSeq: Int = 0
    private(set) var totalFrames: Int64 = 0

    init(directory: URL) throws {
        self.directory = directory
        recordingURL = directory.appendingPathComponent("recording.m4a")
        let recording = try AVAudioFile(forWriting: recordingURL, settings: SegmentWriter.fileSettings)
        recordingFile = recording
        format = recording.processingFormat
        (micFile, sysFile) = try openSegment(seq: 0)
    }

    private func segmentURL(_ seq: Int, _ channel: String) -> URL {
        directory.appendingPathComponent("seg-\(seq)-\(channel).m4a")
    }

    private func openSegment(seq: Int) throws -> (AVAudioFile, AVAudioFile) {
        (try AVAudioFile(forWriting: segmentURL(seq, "me"), settings: SegmentWriter.fileSettings),
         try AVAudioFile(forWriting: segmentURL(seq, "them"), settings: SegmentWriter.fileSettings))
    }

    private func closedSegment(seq: Int, frames: Int64) -> ClosedSegment {
        ClosedSegment(seq: seq, micURL: segmentURL(seq, "me"), sysURL: segmentURL(seq, "them"), frames: frames)
    }

    private func write(_ samples: [Float], from start: Int, count: Int, to file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw NSError(domain: "SegmentWriter", code: 1)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { src in
            _ = memcpy(buffer.floatChannelData![0], src.baseAddress! + start, count * MemoryLayout<Float>.stride)
        }
        try file.write(from: buffer)
    }

    /// Appends equal-length mic and system samples: each goes to its own segment file and the mix to
    /// the recording, rotating whenever the segment fills. Loops until every sample is consumed so a
    /// single call spanning multiple rotation boundaries surfaces every closed segment (empty array =
    /// no rotation this call).
    func append(mic: [Float], sys: [Float]) throws -> [ClosedSegment] {
        precondition(mic.count == sys.count)
        guard !mic.isEmpty, var micActive = micFile, var sysActive = sysFile, let recording = recordingFile else {
            return []
        }
        let mixed = MixPlan.mix(mic: mic, sys: sys, count: mic.count)
        var idx = 0
        var closed: [ClosedSegment] = []
        while idx < mic.count {
            let remainInSegment = Int(SegmentWriter.segmentFrames - segmentFrameCount)
            let chunk = min(mic.count - idx, remainInSegment, SegmentWriter.chunkFrames)

            try write(mixed, from: idx, count: chunk, to: recording)
            try write(mic, from: idx, count: chunk, to: micActive)
            try write(sys, from: idx, count: chunk, to: sysActive)
            segmentFrameCount += Int64(chunk)
            totalFrames += Int64(chunk)
            idx += chunk

            if segmentFrameCount == SegmentWriter.segmentFrames {
                let nextSeq = currentSeq + 1
                (micActive, sysActive) = try openSegment(seq: nextSeq)
                closed.append(closedSegment(seq: currentSeq, frames: segmentFrameCount))
                currentSeq = nextSeq
                segmentFrameCount = 0
                micFile = micActive
                sysFile = sysActive
            }
        }
        return closed
    }

    /// Closes all files. Returns the trailing partial segment (nil when it holds no frames) and the
    /// full recording. Empty trailing channel files (rotation landed exactly on the boundary) are
    /// deleted from disk rather than left as orphans.
    func finish() throws -> (finalSegment: ClosedSegment?, recording: Recording) {
        let partialFrames = segmentFrameCount
        let seq = currentSeq
        let recordingFrames = totalFrames
        micFile = nil
        sysFile = nil
        recordingFile = nil

        let finalSegment: ClosedSegment?
        if partialFrames > 0 {
            finalSegment = closedSegment(seq: seq, frames: partialFrames)
        } else {
            finalSegment = nil
            for channel in ["me", "them"] { try? FileManager.default.removeItem(at: segmentURL(seq, channel)) }
        }
        return (finalSegment, Recording(fileURL: recordingURL, frames: recordingFrames))
    }
}
