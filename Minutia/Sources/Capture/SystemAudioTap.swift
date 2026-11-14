import Foundation
import CoreAudio
import AudioToolbox
import os

/// Coalesces a burst of output-device notifications into one rebuild: it fires once the burst has
/// been quiet for `quietInterval`, or `maxWait` after its first event, whichever comes first.
struct DeviceChangeDebounce: Equatable {
    enum Trigger: Equatable { case device, rate }
    static let quietInterval: TimeInterval = 0.5
    static let maxWait: TimeInterval = 2

    private var firstEvent: TimeInterval?
    private var deadline: TimeInterval = 0
    private var sawDevice = false

    mutating func record(_ trigger: Trigger, at now: TimeInterval) -> TimeInterval {
        let first = firstEvent ?? now
        firstEvent = first
        if trigger == .device { sawDevice = true }
        deadline = min(now + Self.quietInterval, first + Self.maxWait)
        return deadline
    }

    mutating func takeDue(at now: TimeInterval) -> Trigger? {
        guard firstEvent != nil, now >= deadline else { return nil }
        let trigger: Trigger = sawDevice ? .device : .rate
        reset()
        return trigger
    }

    mutating func reset() { self = Self() }
}

/// Rebuild retries: a few fast backoffs for a device handoff, then a slow retry for as long as the
/// tap should run. The failure is reported once, when the fast budget is spent.
struct RebuildRetryPolicy: Equatable {
    struct Step: Equatable {
        let delay: TimeInterval
        let reportFailure: Bool
    }
    static let fastBackoffs: [TimeInterval] = [0.3, 0.6, 1.2]
    static let slowRetry: TimeInterval = 5

    private var failures = 0
    private var reported = false

    mutating func attemptFailed() -> Step {
        failures += 1
        if failures <= Self.fastBackoffs.count {
            return Step(delay: Self.fastBackoffs[failures - 1], reportFailure: false)
        }
        let report = failures == Self.fastBackoffs.count + 1
        if report { reported = true }
        return Step(delay: Self.slowRetry, reportFailure: report)
    }

    mutating func attemptSucceeded() -> Bool {
        defer { reset() }
        return reported
    }

    mutating func reset() { self = Self() }
}

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
    /// Invoked when a rebuild succeeds after `onFailure` was reported.
    var onRecovered: (() -> Void)?

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
    private var debounce = DeviceChangeDebounce()
    private var retry = RebuildRetryPolicy()
    /// Bumped by `stop()` so a debounce or retry timer scheduled before the stop cannot fire a
    /// rebuild against a later run of the same instance.
    private var rebuildEpoch = 0

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
            debounce.reset()
            retry.reset()
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

            var source = readAggregateInputFormat() ?? format
            if let rate = readNominalSampleRate(aggregateID) { source.mSampleRate = rate }
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
            // Neither call waits for an IOBlock the HAL already dispatched; drain it so the state
            // `_start` reassigns next cannot race `render`.
            ioQueue.sync {}
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

    /// A device's clock rate. The aggregate's stream format can keep reporting the tap's native rate
    /// after the output device drops to a headset rate, so the device rate is authoritative.
    private func readNominalSampleRate(_ id: AudioObjectID) -> Double? {
        var rate: Double = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
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
        { [weak self] count, addresses in
            let changed = UnsafeBufferPointer(start: addresses, count: Int(count))
            let trigger: DeviceChangeDebounce.Trigger =
                changed.contains { $0.mSelector != kAudioDevicePropertyNominalSampleRate } ? .device : .rate
            self?.controlQueue.async { self?.noteDeviceChange(trigger) }
        }
    }

    static func shouldRebuild(configuredRate: Double?, deviceRate: Double?) -> Bool {
        guard let configuredRate, let deviceRate, configuredRate > 0, deviceRate > 0 else { return true }
        return abs(configuredRate - deviceRate) > 0.5
    }

    private func noteDeviceChange(_ trigger: DeviceChangeDebounce.Trigger) {
        guard wantRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let deadline = debounce.record(trigger, at: now)
        let epoch = rebuildEpoch
        controlQueue.asyncAfter(deadline: .now() + (deadline - now)) { [weak self] in
            guard let self, self.wantRunning, self.rebuildEpoch == epoch else { return }
            self.fireDebounced()
        }
    }

    /// Every event schedules a timer; only the one at the burst's current deadline finds it due.
    private func fireDebounced() {
        guard let trigger = debounce.takeDue(at: ProcessInfo.processInfo.systemUptime) else { return }
        if trigger == .rate,
           !Self.shouldRebuild(configuredRate: sourceFormat?.mSampleRate, deviceRate: readNominalSampleRate(outputDeviceID)) {
            return
        }
        rebuildForDeviceChange()
    }

    /// Output-device properties that invalidate the running aggregate. A nominal-rate change (a
    /// Bluetooth headset switching profile when its mic opens) leaves the device alive, but the
    /// aggregate then clocks the IOProc at the new rate while `sourceFormat` still holds the old one.
    static let outputDeviceRebuildSelectors = [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate]

    private func installAliveListener() {
        guard deviceListener == nil, outputDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        let rebuild = makeRebuildListener()
        for selector in Self.outputDeviceRebuildSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(outputDeviceID, &address, controlQueue, rebuild) == noErr {
                deviceListener = rebuild
            }
        }
    }

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
            for selector in Self.outputDeviceRebuildSelectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(outputDeviceID, &address, controlQueue, block)
            }
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
        attemptRebuild()
    }

    /// One rebuild attempt on `controlQueue`. A failure (the new default output is briefly
    /// unavailable during an AirPods handoff, or gone until another device appears) is retried for
    /// as long as the tap should run; each attempt reads the current default output.
    private func attemptRebuild() {
        _stop()
        do {
            try _start()
            isRebuilding = false
            if retry.attemptSucceeded() { onRecovered?() }
        } catch {
            let step = retry.attemptFailed()
            let epoch = rebuildEpoch
            controlQueue.asyncAfter(deadline: .now() + step.delay) { [weak self] in
                guard let self, self.wantRunning, self.rebuildEpoch == epoch else { return }
                self.attemptRebuild()
            }
            if step.reportFailure {
                Self.logger.error("System-audio rebuild failing, still retrying: \(String(describing: error), privacy: .public)")
                onFailure?(error)
            }
        }
    }

    // MARK: - Hot path

    private func render(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let format = sourceFormat else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let monoCount = monoScratch.withUnsafeMutableBufferPointer { Self.downmix(abl, into: $0) }
        guard monoCount > 0 else { return }
        pushResampled(monoCount: monoCount, sourceRate: format.mSampleRate)
    }

    /// Averages every channel of every delivered buffer into mono Float32. The layout comes from
    /// the buffers themselves, not a cached stream format: a Bluetooth headset entering its headset
    /// mode changes the buffer count and channel layout mid-recording.
    static func downmix(_ abl: UnsafeMutableAudioBufferListPointer, into mono: UnsafeMutableBufferPointer<Float>) -> Int {
        var frames = mono.count
        var channels = 0
        for buffer in abl {
            guard buffer.mData != nil else { continue }
            let ch = max(1, Int(buffer.mNumberChannels))
            frames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / ch)
            channels += ch
        }
        guard channels > 0, frames > 0 else { return 0 }
        for f in 0..<frames { mono[f] = 0 }
        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let ch = max(1, Int(buffer.mNumberChannels))
            let ptr = data.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<ch { sum += ptr[f * ch + c] }
                mono[f] += sum
            }
        }
        let scale = 1 / Float(channels)
        for f in 0..<frames { mono[f] *= scale }
        return frames
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
