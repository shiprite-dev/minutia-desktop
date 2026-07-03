import Foundation
import CoreAudio
import AudioToolbox

/// Global system-audio tap that excludes our own process, feeding 48k mono Float32 into a ring
/// buffer. Uses the C Core Audio HAL tapping API (macOS 14.4+); the typed AudioHardwareTap classes
/// are macOS 15+ and deliberately avoided here.
final class SystemAudioTap {
    enum TapError: Error {
        /// A HAL call returned a non-`noErr` status. Carries the failing call name.
        case osStatus(String, OSStatus)
        /// Could not translate our own pid into an AudioObjectID.
        case noProcessObject
        /// The tap reported an unusable stream format (no channels).
        case invalidTapFormat
    }

    private let buffer: RingBuffer
    private let ioQueue = DispatchQueue(label: "app.minutia.systemtap.io", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// The tap's stream format, read before any consumer is created. Nil until `start()` succeeds.
    private(set) var tapFormat: AudioStreamBasicDescription?

    // Pre-allocated hot-path scratch. Sized for one second at 48k so no callback allocates.
    private static let scratchFrames = 48_000
    private var monoScratch = [Float](repeating: 0, count: scratchFrames)
    private var resampleScratch = [Float](repeating: 0, count: scratchFrames)

    init(into buffer: RingBuffer) {
        self.buffer = buffer
    }

    func start() throws {
        do {
            let ownProcess = try translateOwnProcessObject()

            let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
            desc.uuid = UUID()
            desc.name = "MinutiaTap"
            desc.isPrivate = true
            desc.muteBehavior = .unmuted

            try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")

            let format = try readTapFormat()
            guard format.mChannelsPerFrame > 0 else { throw TapError.invalidTapFormat }
            tapFormat = format

            let outputUID = try defaultOutputDeviceUID()
            try createAggregateDevice(tapUUID: desc.uuid, outputUID: outputUID)
            try createIOProc()

            try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        } catch {
            stop()
            throw error
        }
    }

    /// Teardown in strict reverse order, tolerating a partially initialized state.
    func stop() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapFormat = nil
    }

    // MARK: - Setup steps

    private func translateOwnProcessObject() throws -> AudioObjectID {
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject),
            "AudioObjectGetPropertyData(TranslatePIDToProcessObject)")
        guard processObject != AudioObjectID(kAudioObjectUnknown) else { throw TapError.noProcessObject }
        return processObject
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
            "AudioObjectGetPropertyData(TapFormat)")
        return format
    }

    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &deviceID),
            "AudioObjectGetPropertyData(DefaultOutputDevice)")

        var uid: Unmanaged<CFString>?
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid),
            "AudioObjectGetPropertyData(DefaultOutputDeviceUID)")
        guard let deviceUID = uid?.takeRetainedValue() else {
            throw TapError.osStatus("AudioObjectGetPropertyData(DefaultOutputDeviceUID)", kAudioHardwareBadObjectError)
        }
        return deviceUID as String
    }

    private func createAggregateDevice(tapUUID: UUID, outputUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MinutiaAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "AudioHardwareCreateAggregateDevice")
    }

    private func createIOProc() throws {
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
                [weak self] _, inInputData, _, _, _ in
                self?.render(inInputData)
            },
            "AudioDeviceCreateIOProcIDWithBlock")
        guard ioProcID != nil else {
            throw TapError.osStatus("AudioDeviceCreateIOProcIDWithBlock", kAudioHardwareBadDeviceError)
        }
    }

    // MARK: - Hot path

    private func render(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let format = tapFormat else { return }
        let channels = Int(format.mChannelsPerFrame)
        guard channels > 0 else { return }

        let ablPointer = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData))
        guard ablPointer.count > 0 else { return }

        let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = MemoryLayout<Float>.size

        let monoCount: Int = monoScratch.withUnsafeMutableBufferPointer { mono -> Int in
            let maxFrames = mono.count
            if nonInterleaved {
                // One buffer per channel, each mono.
                let bufferCount = min(ablPointer.count, channels)
                guard let first = ablPointer[0].mData else { return 0 }
                let frames = min(Int(ablPointer[0].mDataByteSize) / bytesPerSample, maxFrames)
                guard frames > 0 else { return 0 }
                let scale = Float(1) / Float(channels)
                let firstPtr = first.assumingMemoryBound(to: Float.self)
                for f in 0..<frames { mono[f] = firstPtr[f] }
                for b in 1..<bufferCount {
                    guard let data = ablPointer[b].mData else { continue }
                    let ptr = data.assumingMemoryBound(to: Float.self)
                    let bf = min(Int(ablPointer[b].mDataByteSize) / bytesPerSample, frames)
                    for f in 0..<bf { mono[f] += ptr[f] }
                }
                for f in 0..<frames { mono[f] *= scale }
                return frames
            } else {
                // Interleaved single buffer of `channels` samples per frame.
                guard let data = ablPointer[0].mData else { return 0 }
                let ptr = data.assumingMemoryBound(to: Float.self)
                let totalSamples = Int(ablPointer[0].mDataByteSize) / bytesPerSample
                let frames = min(totalSamples / channels, maxFrames)
                guard frames > 0 else { return 0 }
                let scale = Float(1) / Float(channels)
                for f in 0..<frames {
                    var sum: Float = 0
                    let base = f * channels
                    for c in 0..<channels { sum += ptr[base + c] }
                    mono[f] = sum * scale
                }
                return frames
            }
        }

        guard monoCount > 0 else { return }
        pushResampled(monoCount: monoCount, sourceRate: format.mSampleRate)
    }

    private func pushResampled(monoCount: Int, sourceRate: Double) {
        let targetRate = MixPlan.sampleRate
        if sourceRate == targetRate || sourceRate <= 0 {
            monoScratch.withUnsafeBufferPointer { mono in
                buffer.push(mono.baseAddress!, count: monoCount)
            }
            return
        }
        // Linear resample into the pre-allocated scratch. Good enough for speech transcription;
        // the tap format is typically already 48k float so this path rarely runs.
        let ratio = targetRate / sourceRate
        let outCount = min(Int(Double(monoCount) * ratio), resampleScratch.count)
        guard outCount > 0 else { return }
        monoScratch.withUnsafeBufferPointer { mono in
            resampleScratch.withUnsafeMutableBufferPointer { out in
                let lastIndex = monoCount - 1
                for j in 0..<outCount {
                    let srcPos = Double(j) / ratio
                    let i0 = Int(srcPos)
                    if i0 >= lastIndex {
                        out[j] = mono[lastIndex]
                    } else {
                        let frac = Float(srcPos - Double(i0))
                        out[j] = mono[i0] * (1 - frac) + mono[i0 + 1] * frac
                    }
                }
                buffer.push(out.baseAddress!, count: outCount)
            }
        }
    }

    private func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw TapError.osStatus(call, status) }
    }
}
