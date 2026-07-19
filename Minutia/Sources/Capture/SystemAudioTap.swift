import Foundation
import CoreAudio
import AudioToolbox
import os

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

    /// Invoked if an automatic rebuild after a device change fails to restart capture. Never
    /// crashes; the caller decides how to surface the failure.
    var onFailure: ((Error) -> Void)?

    private let buffer: RingBuffer
    private let ioQueue = DispatchQueue(label: "app.minutia.systemtap.io", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "app.minutia.systemtap.control")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// The default-output device id captured at start, used both as the aggregate's main sub-device
    /// and as the object the liveness listener watches.
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var isRebuilding = false
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

    /// True between a successful public `start()` and `stop()`. Drives whether a device-change
    /// rebuild (and its retries) should run; independent of `ioProcID`, which is briefly nil during a
    /// rebuild and after a failed start attempt.
    private var wantRunning = false
    private var rebuildRetries = 0
    /// Bumped by `stop()` so a retry timer scheduled before the stop cannot fire a rebuild against a
    /// later run of the same instance.
    private var rebuildEpoch = 0
    private static let rebuildBackoffs: [TimeInterval] = [0.3, 0.6, 1.2]

    private static let logger = Logger(subsystem: "app.minutia.desktop", category: "SystemAudioTap")

    /// The tap's stream format, read before any consumer is created. Nil until `start()` succeeds.
    private(set) var tapFormat: AudioStreamBasicDescription?

    /// The aggregate device's actual input stream format. The IOProc delivers audio clocked by the
    /// aggregate (which follows the default output device), not by the standalone tap format, so
    /// downmix and resample must use this. Falls back to the tap format if the read fails.
    private var sourceFormat: AudioStreamBasicDescription?

    // Pre-allocated hot-path scratch. Sized for one second so no callback allocates: the mono
    // scratch at the source rate, the resample scratch at the 48k target rate.
    private static let scratchFrames = 48_000
    private var monoScratch = [Float](repeating: 0, count: scratchFrames)
    private var resampleScratch = [Float](repeating: 0, count: scratchFrames)

    /// Continuous resampler for the non-equal-rate path, reconfigured per source rate in `_start`.
    private var resampler = LinearResampler(sourceRate: MixPlan.sampleRate, targetRate: MixPlan.sampleRate)

    init(into buffer: RingBuffer) {
        self.buffer = buffer
    }

    /// Serializes with `stop()` and the device-change rebuild on `controlQueue` so a concurrent
    /// teardown and rebuild can never double-destroy the aggregate or tap.
    func start() throws {
        try controlQueue.sync {
            try _start()
            wantRunning = true
        }
    }

    func stop() {
        controlQueue.sync {
            wantRunning = false
            rebuildRetries = 0
            isRebuilding = false
            rebuildEpoch += 1
            _stop()
        }
    }

    private func _start() throws {
        guard ioProcID == nil && tapID == AudioObjectID(kAudioObjectUnknown) else { return }
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

            let source = readAggregateInputFormat() ?? format
            sourceFormat = source
            resizeScratch(sourceRate: source.mSampleRate)
            resampler = LinearResampler(sourceRate: source.mSampleRate, targetRate: MixPlan.sampleRate)

            try createIOProc()

            try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
            installDeviceListeners()
        } catch {
            _stop()
            throw error
        }
    }

    /// Teardown in strict reverse order, tolerating a partially initialized state.
    private func _stop() {
        removeDeviceListeners()
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
        sourceFormat = nil
        outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

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

    /// Reads the aggregate device's actual input stream format. Returns nil on any failure so the
    /// caller falls back to the tap format.
    private func readAggregateInputFormat() -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &format)
        guard status == noErr, format.mChannelsPerFrame > 0 else { return nil }
        return format
    }

    /// Re-sizes the hot-path scratch: one second of mono at the source rate, and the resample
    /// output at the 48k target rate. No-op when already correctly sized.
    private func resizeScratch(sourceRate: Double) {
        let sourceFrames = sourceRate > 0 ? Int(sourceRate.rounded()) : Self.scratchFrames
        if monoScratch.count != sourceFrames {
            monoScratch = [Float](repeating: 0, count: sourceFrames)
        }
        let targetFrames = Int(MixPlan.sampleRate)
        if resampleScratch.count != targetFrames {
            resampleScratch = [Float](repeating: 0, count: targetFrames)
        }
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
        outputDeviceID = deviceID
        return deviceUID as String
    }

    private func createAggregateDevice(tapUUID: UUID, outputUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MinutiaAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
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

    // MARK: - Device-change resilience

    /// Watches the captured output device's liveness and the system default-output selection so a
    /// mid-meeting device change (headphones or AirPods disconnect) rebuilds the aggregate against
    /// the new default output. Listeners fire on `controlQueue`.
    private func installDeviceListeners() {
        installAliveListener()
        installDefaultOutputListener()
    }

    /// A listener block that defers the rebuild off its own callback so teardown never removes a
    /// listener from inside its own invocation.
    private func makeRebuildListener() -> AudioObjectPropertyListenerBlock {
        { [weak self] _, _ in
            self?.controlQueue.async { self?.rebuildForDeviceChange() }
        }
    }

    private func installAliveListener() {
        guard deviceListener == nil, outputDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        let rebuild = makeRebuildListener()
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(outputDeviceID, &aliveAddress, controlQueue, rebuild) == noErr {
            deviceListener = rebuild
        }
    }

    /// Installs the system default-output listener. Kept separately installable so a rebuild that
    /// exhausted its retry budget can re-arm just this listener and still recover on a later settle.
    private func installDefaultOutputListener() {
        guard defaultOutputListener == nil else { return }
        let rebuild = makeRebuildListener()
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, controlQueue, rebuild) == noErr {
            defaultOutputListener = rebuild
        }
    }

    private func removeDeviceListeners() {
        if let block = deviceListener, outputDeviceID != AudioObjectID(kAudioObjectUnknown) {
            var aliveAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(outputDeviceID, &aliveAddress, controlQueue, block)
            deviceListener = nil
        }
        if let block = defaultOutputListener {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultAddress, controlQueue, block)
            defaultOutputListener = nil
        }
    }

    /// Tears down and re-creates the aggregate against the current default output. Runs on
    /// `controlQueue`; re-entrancy is blocked by `isRebuilding`. Uses the internal `_stop`/`_start`
    /// to avoid a re-entrant `controlQueue.sync` deadlock.
    private func rebuildForDeviceChange() {
        guard wantRunning, !isRebuilding else { return }
        isRebuilding = true
        rebuildRetries = 0
        attemptRebuild()
    }

    /// One rebuild attempt on `controlQueue`. A transient failure (the new default output is briefly
    /// unavailable during an AirPods handoff) is retried with backoff; once the budget is exhausted
    /// the default-output listener is re-armed so a later device settle can still recover.
    private func attemptRebuild() {
        _stop()
        do {
            try _start()
            rebuildRetries = 0
            isRebuilding = false
        } catch {
            if rebuildRetries < Self.rebuildBackoffs.count {
                let delay = Self.rebuildBackoffs[rebuildRetries]
                rebuildRetries += 1
                let epoch = rebuildEpoch
                controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    guard self.wantRunning, self.rebuildEpoch == epoch else { return }
                    self.attemptRebuild()
                }
            } else {
                Self.logger.error("System-audio rebuild gave up after retries: \(String(describing: error), privacy: .public)")
                rebuildRetries = 0
                isRebuilding = false
                installDefaultOutputListener()
                onFailure?(error)
            }
        }
    }

    // MARK: - Hot path

    private func render(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let format = sourceFormat else { return }
        let channels = Int(format.mChannelsPerFrame)
        guard channels > 0, format.mBitsPerChannel == 32 else { return }

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
        // Continuous linear resample into the pre-allocated scratch: the resampler carries the
        // fractional source position and last sample across callbacks so the stream is rate-exact
        // over time with no per-callback seam. The tap format is typically already 48k float so this
        // path rarely runs.
        let produced = monoScratch.withUnsafeBufferPointer { mono -> Int in
            let input = UnsafeBufferPointer(rebasing: mono[0..<monoCount])
            return resampler.resample(input, into: &resampleScratch)
        }
        guard produced > 0 else { return }
        resampleScratch.withUnsafeBufferPointer { out in
            buffer.push(out.baseAddress!, count: produced)
        }
    }

    private func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw TapError.osStatus(call, status) }
    }
}
