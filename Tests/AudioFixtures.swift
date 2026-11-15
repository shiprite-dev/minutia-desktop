import XCTest
import AVFoundation
import CoreMedia

/// Test-side audio oracles, independent of the production writer and readers.
enum AudioFixtures {
    /// Duration of the file's audio as AVFoundation sees it, or nil when it has no audio track or no
    /// positive duration (the shape of an .m4a whose index was never written).
    static func assetDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Copies the file's current bytes, as a process killed at this instant would leave them, and
    /// reads the copy. Polls because fragments reach disk asynchronously after the samples are appended.
    static func durationOfCrashCopy(_ url: URL, atLeast minimum: Double, timeout: TimeInterval = 5) async throws -> Double? {
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent("crash-copy-\(UUID().uuidString)-\(url.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: copy) }
        let deadline = Date().addingTimeInterval(timeout)
        var last: Double?
        repeat {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: url, to: copy)
            last = await assetDuration(copy)
            if let last, last >= minimum { return last }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return last
    }

    /// An .m4a as AVAudioFile leaves it when the process dies mid-write: an ftyp box, then an
    /// open-ended mdat (size 0 = runs to end of file) holding sample bytes, and no moov.
    static func writeUnfinalizedM4A(to url: URL) throws {
        var data = Data()
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x18])
        data.append(contentsOf: Array("ftypM4A ".utf8))
        data.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        data.append(contentsOf: Array("M4A isom".utf8))
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append(contentsOf: Array("mdat".utf8))
        data.append(Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try data.write(to: url)
    }

    /// A fragmented AAC .m4a of `seconds` of 440 Hz sine, finished normally.
    static func writeFragmentedM4A(to url: URL, seconds: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 48_000)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "AudioFixtures", code: 1) }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        let frames = 48_000
        for second in 0..<seconds {
            let samples = (0..<frames).map { Float(0.5 * sin(2 * Double.pi * 440 * Double(second * frames + $0) / 48_000)) }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: frames * 4, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: frames * 4,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            samples.withUnsafeBytes {
                _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 4)
            }
            var buffer: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
                presentationTimeStamp: CMTime(value: CMTimeValue(second * frames), timescale: 48_000),
                packetDescriptions: nil, sampleBufferOut: &buffer)
            while !input.isReadyForMoreMediaData { usleep(1_000) }
            guard input.append(buffer!) else { throw writer.error ?? NSError(domain: "AudioFixtures", code: 2) }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "AudioFixtures", code: 3) }
    }
}
