import Foundation
import AVFoundation
import CoreMedia

/// Writes each rotating segment as two mono files (microphone, system audio) AND the continuous mixed
/// full recording. Every file is fragmented AAC in an .m4a container, so audio written before a crash
/// stays readable.
final class SegmentWriter {
    static let segmentSeconds: Double = 300
    static let segmentFrames: Int64 = 48_000 * Int64(segmentSeconds)

    struct ClosedSegment: Equatable {
        let seq: Int
        let micURL: URL
        let sysURL: URL
        let frames: Int64
        var startSeconds: Double? = nil
        var offsetSeconds: Double { startSeconds ?? Double(seq) * SegmentWriter.segmentSeconds }
    }

    struct Recording {
        let fileURL: URL
        let frames: Int64
    }

    private final class Track {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        var frames: Int64 = 0

        init(url: URL) throws {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 48_000)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? SegmentWriter.failure(1) }
            writer.startSession(atSourceTime: .zero)
        }

        func write(_ samples: [Float], from start: Int, count: Int, deadline: Date) throws {
            guard writer.status == .writing else { throw writer.error ?? SegmentWriter.failure(6) }
            let bytes = count * MemoryLayout<Float>.stride
            var block: CMBlockBuffer?
            var buffer: CMSampleBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block,
                  samples.withUnsafeBufferPointer({
                      CMBlockBufferReplaceDataBytes(
                          with: $0.baseAddress! + start, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
                  }) == noErr,
                  CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                      allocator: nil, dataBuffer: block, formatDescription: SegmentWriter.pcmFormat, sampleCount: count,
                      presentationTimeStamp: CMTime(value: frames, timescale: 48_000),
                      packetDescriptions: nil, sampleBufferOut: &buffer) == noErr, let buffer else {
                throw SegmentWriter.failure(2)
            }
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? SegmentWriter.failure(3) }
                usleep(1_000)
            }
            guard input.append(buffer) else { throw writer.error ?? SegmentWriter.failure(4) }
            frames += Int64(count)
        }

        func close(timeout: TimeInterval) throws {
            guard writer.status == .writing else { throw writer.error ?? SegmentWriter.failure(5) }
            input.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            guard done.wait(timeout: .now() + timeout) == .success else { throw SegmentWriter.failure(7) }
            guard writer.status == .completed else { throw writer.error ?? SegmentWriter.failure(5) }
        }
    }

    private static func failure(_ code: Int) -> NSError { NSError(domain: "SegmentWriter", code: code) }

    private static let pcmFormat: CMAudioFormatDescription = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return format!
    }()

    private static let chunkFrames = 48_000   // bounds per-write buffer allocation to ~1s

    static let readyTimeout: TimeInterval = 3
    static let pieceMinSeconds: Double = 20
    static let pieceMaxSeconds: Double = 40
    private static let blockFrames: Int64 = 4_800
    private static let quietPeak: Float = 0.02

    private let directory: URL
    private let closeTimeout: TimeInterval
    private let recordingURL: URL
    private var recordingTrack: Track?
    private var micTrack: Track?
    private var sysTrack: Track?
    private var segmentFrameCount: Int64 = 0

    private var pieceMic: Track?
    private var pieceSys: Track?
    private var pieceFrames: Int64 = 0
    private var pieceStartFrame: Int64 = 0
    private var pieceIndex = 0
    private var blockFrameCount: Int64 = 0
    private var blockPeak: Float = 0
    private var quietBlocks = 0
    private var closedPieces: [ClosedSegment] = []
    private var piecesFailed = false

    private(set) var currentSeq: Int = 0
    private(set) var totalFrames: Int64 = 0
    private(set) var segmentsDropped = false

    init(directory: URL, closeTimeout: TimeInterval = 10) throws {
        self.directory = directory
        self.closeTimeout = closeTimeout
        recordingURL = directory.appendingPathComponent("recording.m4a")
        recordingTrack = try Track(url: recordingURL)
        (micTrack, sysTrack) = try openSegment(seq: 0)
    }

    private func segmentURL(_ seq: Int, _ channel: String) -> URL {
        directory.appendingPathComponent("seg-\(seq)-\(channel).m4a")
    }

    private func openSegment(seq: Int) throws -> (Track, Track) {
        (try Track(url: segmentURL(seq, "me")), try Track(url: segmentURL(seq, "them")))
    }

    private func pieceURL(_ seq: Int, _ channel: String) -> URL {
        directory.appendingPathComponent("tail-\(seq)-\(channel).m4a")
    }

    private func writePiece(mic: [Float], sys: [Float], mixed: [Float], from idx: Int, count: Int, deadline: Date) {
        guard !piecesFailed else { return }
        do {
            if pieceMic == nil || pieceSys == nil {
                let seq = currentSeq + pieceIndex
                pieceMic = try Track(url: pieceURL(seq, "me"))
                pieceSys = try Track(url: pieceURL(seq, "them"))
            }
            try pieceMic?.write(mic, from: idx, count: count, deadline: deadline)
            try pieceSys?.write(sys, from: idx, count: count, deadline: deadline)
            pieceFrames += Int64(count)
            blockFrameCount += Int64(count)
            for i in idx..<idx + count { blockPeak = max(blockPeak, abs(mixed[i])) }
            guard blockFrameCount == SegmentWriter.blockFrames else { return }
            quietBlocks = blockPeak < SegmentWriter.quietPeak ? quietBlocks + 1 : 0
            blockFrameCount = 0
            blockPeak = 0
            let held = Double(pieceFrames) / MixPlan.sampleRate
            if held >= SegmentWriter.pieceMaxSeconds || (held >= SegmentWriter.pieceMinSeconds && quietBlocks >= 2) {
                try closePiece()
            }
        } catch {
            discardPieces()
            piecesFailed = true
        }
    }

    private func closePiece() throws {
        guard let micPiece = pieceMic, let sysPiece = pieceSys else { return }
        pieceMic = nil
        pieceSys = nil
        let seq = currentSeq + pieceIndex
        let frames = pieceFrames
        let start = pieceStartFrame
        try micPiece.close(timeout: closeTimeout)
        try sysPiece.close(timeout: closeTimeout)
        closedPieces.append(ClosedSegment(
            seq: seq, micURL: pieceURL(seq, "me"), sysURL: pieceURL(seq, "them"), frames: frames,
            startSeconds: Double(currentSeq) * SegmentWriter.segmentSeconds + Double(start) / MixPlan.sampleRate))
        pieceIndex += 1
        pieceStartFrame += frames
        pieceFrames = 0
        blockFrameCount = 0
        blockPeak = 0
        quietBlocks = 0
    }

    private func discardPieces() {
        for track in [pieceMic, pieceSys].compactMap({ $0 }) { try? track.close(timeout: closeTimeout) }
        let seq = currentSeq + pieceIndex
        let urls = closedPieces.flatMap { [$0.micURL, $0.sysURL] } + [pieceURL(seq, "me"), pieceURL(seq, "them")]
        for url in urls { try? FileManager.default.removeItem(at: url) }
        pieceMic = nil
        pieceSys = nil
        closedPieces = []
        pieceFrames = 0
        pieceStartFrame = 0
        pieceIndex = 0
        blockFrameCount = 0
        blockPeak = 0
        quietBlocks = 0
    }

    private func closedSegment(seq: Int, frames: Int64) -> ClosedSegment {
        ClosedSegment(seq: seq, micURL: segmentURL(seq, "me"), sysURL: segmentURL(seq, "them"), frames: frames)
    }

    /// Appends equal-length mic and system samples: each goes to its own segment file and the mix to
    /// the recording, rotating whenever the segment fills. Loops until every sample is consumed so a
    /// single call spanning multiple rotation boundaries surfaces every closed segment (empty array =
    /// no rotation this call). Each returned segment's files are finished before it is returned.
    func append(mic: [Float], sys: [Float]) throws -> [ClosedSegment] {
        precondition(mic.count == sys.count)
        guard !mic.isEmpty, let recording = recordingTrack else { return [] }
        let mixed = MixPlan.mix(mic: mic, sys: sys, count: mic.count)
        var idx = 0
        var closed: [ClosedSegment] = []
        while idx < mic.count {
            let deadline = Date().addingTimeInterval(SegmentWriter.readyTimeout)
            let remainInSegment = Int(SegmentWriter.segmentFrames - segmentFrameCount)
            var chunk = min(mic.count - idx, remainInSegment, SegmentWriter.chunkFrames)
            if !piecesFailed {
                let pieceCap = Int64(SegmentWriter.pieceMaxSeconds * MixPlan.sampleRate) - pieceFrames
                chunk = min(chunk, Int(SegmentWriter.blockFrames - blockFrameCount), Int(pieceCap))
            }

            try recording.write(mixed, from: idx, count: chunk, deadline: deadline)
            if let micActive = micTrack, let sysActive = sysTrack {
                do {
                    try micActive.write(mic, from: idx, count: chunk, deadline: deadline)
                    try sysActive.write(sys, from: idx, count: chunk, deadline: deadline)
                } catch {
                    micTrack = nil
                    sysTrack = nil
                    segmentsDropped = true
                }
            }
            writePiece(mic: mic, sys: sys, mixed: mixed, from: idx, count: chunk, deadline: deadline)
            segmentFrameCount += Int64(chunk)
            totalFrames += Int64(chunk)
            idx += chunk

            if segmentFrameCount == SegmentWriter.segmentFrames {
                segmentFrameCount = 0
                discardPieces()
                piecesFailed = false
                if let micActive = micTrack, let sysActive = sysTrack {
                    micTrack = nil
                    sysTrack = nil
                    do {
                        try micActive.close(timeout: closeTimeout)
                        try sysActive.close(timeout: closeTimeout)
                        closed.append(closedSegment(seq: currentSeq, frames: SegmentWriter.segmentFrames))
                        (micTrack, sysTrack) = try openSegment(seq: currentSeq + 1)
                        currentSeq += 1
                    } catch {
                        segmentsDropped = true
                    }
                }
            }
        }
        return closed
    }

    /// Closes all files. Returns the trailing partial segment (nil when it holds no frames), the
    /// full recording, and the tail window's local pieces (only when it split into two or more).
    /// Empty trailing channel files (rotation landed exactly on the boundary) are deleted from disk
    /// rather than left as orphans.
    func finish() throws -> (finalSegment: ClosedSegment?, recording: Recording, tailPieces: [ClosedSegment]) {
        let partialFrames = segmentFrameCount
        let seq = currentSeq
        let recording = recordingTrack
        let segmentTracks = [micTrack, sysTrack].compactMap { $0 }
        recordingTrack = nil
        micTrack = nil
        sysTrack = nil
        var pieces: [ClosedSegment] = []
        if !piecesFailed, pieceFrames > 0 {
            do { try closePiece() } catch { piecesFailed = true }
        }
        pieces = closedPieces
        if piecesFailed { pieces = [] }
        var recordingError: Error?
        do { try recording?.close(timeout: closeTimeout) } catch { recordingError = error }
        for track in segmentTracks {
            do { try track.close(timeout: closeTimeout) } catch { segmentsDropped = true }
        }
        let keepPieces = recordingError == nil && !segmentsDropped && !segmentTracks.isEmpty
            && pieces.count >= 2 && pieces.reduce(0, { $0 + $1.frames }) == partialFrames
        if !keepPieces {
            pieces = []
            discardPieces()
        }
        if let recordingError { throw recordingError }
        let result = Recording(fileURL: recordingURL, frames: totalFrames)
        if segmentsDropped || segmentTracks.isEmpty { return (nil, result, pieces) }
        if partialFrames > 0 { return (closedSegment(seq: seq, frames: partialFrames), result, pieces) }
        for channel in ["me", "them"] { try? FileManager.default.removeItem(at: segmentURL(seq, channel)) }
        return (nil, result, pieces)
    }
}
