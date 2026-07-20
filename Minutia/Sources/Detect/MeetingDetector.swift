import AppKit
import CoreAudio
import Darwin
import Foundation

/// Watches the default input device for activity, then corroborates with the running meeting app,
/// a browser holding a live audio-input stream, and a live calendar agenda item to decide whether a
/// meeting is actually happening. Mic state is event-driven via a CoreAudio property listener,
/// corrected by a 15s poll (some devices, notably AirPods, report stale `DeviceIsRunningSomewhere`
/// values). While the mic is active, app/browser/agenda signals are polled every 5s and folded
/// through `DetectionRules`; the app surfaces the result via the published `confidence`.
@MainActor
final class MeetingDetector: ObservableObject {
    @Published private(set) var confidence: DetectionConfidence = .none

    private let controlQueue = DispatchQueue(label: "app.minutia.detector.control")

    private var inputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    private var correctionTimer: Timer?
    private var pollTimer: Timer?
    private var agendaProvider: (() async -> [AgendaItem])?

    private var cachedAgenda: [AgendaItem] = []
    private var cachedAgendaAt: Date?
    private let agendaCacheTTL: TimeInterval = 60

    private var micActive = false
    /// The previous poll's raw browser-input hit, so a browser meeting must persist across two
    /// consecutive polls before it counts. Reset to false whenever the mic goes inactive, alongside
    /// the rest of the per-mic-session state.
    private var lastBrowserHit = false
    private var isRunning = false

    func start(agendaProvider: @escaping () async -> [AgendaItem]) {
        guard !isRunning else { return }
        isRunning = true
        self.agendaProvider = agendaProvider

        resolveDefaultInputDevice()
        installRunningListener()
        installDefaultInputListener()
        refreshMicState()

        correctionTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMicState() }
        }
    }

    func stop() {
        removeRunningListener()
        removeDefaultInputListener()
        correctionTimer?.invalidate()
        correctionTimer = nil
        stopPolling()

        agendaProvider = nil
        cachedAgenda = []
        cachedAgendaAt = nil
        inputDeviceID = AudioObjectID(kAudioObjectUnknown)
        micActive = false
        lastBrowserHit = false
        isRunning = false
        confidence = .none
    }

    // MARK: - Mic liveness (CoreAudio)

    private func resolveDefaultInputDevice() {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        inputDeviceID = status == noErr ? deviceID : AudioObjectID(kAudioObjectUnknown)
    }

    private func readDeviceIsRunningSomewhere() -> Bool {
        guard inputDeviceID != AudioObjectID(kAudioObjectUnknown) else { return false }
        var running: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(inputDeviceID, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    private func installRunningListener() {
        guard inputDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshMicState() }
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(inputDeviceID, &address, controlQueue, listener) == noErr {
            runningListener = listener
        }
    }

    private func removeRunningListener() {
        guard let listener = runningListener, inputDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            runningListener = nil
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(inputDeviceID, &address, controlQueue, listener)
        runningListener = nil
    }

    private func installDefaultInputListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleDefaultInputChanged() }
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener) == noErr {
            defaultInputListener = listener
        }
    }

    private func removeDefaultInputListener() {
        guard let listener = defaultInputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        defaultInputListener = nil
    }

    /// The default input device changed (e.g. AirPods connected/disconnected): re-point the
    /// liveness listener at the new device before re-reading its state.
    private func handleDefaultInputChanged() {
        removeRunningListener()
        resolveDefaultInputDevice()
        installRunningListener()
        refreshMicState()
    }

    private func refreshMicState() {
        guard isRunning else { return }
        let wasActive = micActive
        let isActive = readDeviceIsRunningSomewhere()
        micActive = isActive

        if isActive && !wasActive {
            startPolling()
        } else if !isActive && wasActive {
            stopPolling()
        }

        if !isActive {
            lastBrowserHit = false
            confidence = .none
        } else {
            poll()
        }
    }

    // MARK: - App + agenda polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard micActive else { return }
        Task { [weak self] in
            await self?.evaluate()
        }
    }

    private func evaluate() async {
        guard micActive else { return }
        // `proc_listallpids` plus a `proc_name` syscall per PID, plus the CoreAudio process-object
        // sweep, is hundreds of syscalls; run it off the main actor so the 5s poll never stalls the
        // UI. Re-check micActive after the hop: the mic can go inactive while it runs, and
        // refreshMicState would already have reset state.
        let signals = await Task.detached {
            (processNames: Self.runningProcessNames(),
             bundleIds: Self.runningBundleIds(),
             inputBundleIds: Self.inputBundleIds())
        }.value
        guard micActive else { return }
        let app = DetectionRules.detectApp(
            processNames: signals.processNames, bundleIds: signals.bundleIds)
        let browserHit = DetectionRules.detectBrowserMeeting(inputBundleIds: signals.inputBundleIds)
        let browserConfirmed = DetectionRules.browserSignalConfirmed(
            previousPollHit: lastBrowserHit, currentPollHit: browserHit)
        lastBrowserHit = browserHit
        let agenda = await agendaSnapshot()
        let calendarLive = DetectionRules.liveAgendaItem(agenda, now: Date()) != nil
        confidence = DetectionRules.assess(
            micActive: micActive, app: app, calendarLive: calendarLive, browserActive: browserConfirmed)
    }

    private func agendaSnapshot() async -> [AgendaItem] {
        if let cachedAt = cachedAgendaAt, Date().timeIntervalSince(cachedAt) < agendaCacheTTL {
            return cachedAgenda
        }
        guard let provider = agendaProvider else { return [] }
        let items = await provider()
        cachedAgenda = items
        cachedAgendaAt = Date()
        return items
    }

    // MARK: - Raw signal gathering

    /// `NSWorkspace.runningApplications` misses helper processes like Zoom's `CptHost`, which never
    /// registers as a full running application, so bundle ids alone cannot detect an active Zoom
    /// call; process names via libproc catch it.
    nonisolated private static func runningProcessNames() -> [String] {
        let neededSize = proc_listallpids(nil, 0)
        guard neededSize > 0 else { return [] }
        let capacity = Int(neededSize) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let writtenSize = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard writtenSize > 0 else { return [] }
        let count = min(Int(writtenSize) / MemoryLayout<pid_t>.size, capacity)

        var names: [String] = []
        names.reserveCapacity(count)
        var nameBuffer = [CChar](repeating: 0, count: 256)
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            nameBuffer.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress?.initialize(repeating: 0, count: buf.count)
                _ = proc_name(pid, buf.baseAddress, UInt32(buf.count))
            }
            let name = nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    nonisolated private static func runningBundleIds() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    }

    /// Bundle ids of every process that currently holds a live audio-input stream, read from
    /// CoreAudio's process-object list. This is what catches a browser meeting (Google Meet in
    /// Chrome/Safari/Arc), which registers no meeting-specific process or bundle. Our own process is
    /// excluded by both pid and bundle id so Minutia's own mic/system-audio capture never reads back
    /// as a meeting.
    ///
    /// The process-object list and its per-process properties are macOS 14.4+ (the app's deployment
    /// floor, and the same HAL generation SystemAudioTap relies on for its process-tap API), so no
    /// runtime availability check is needed, matching SystemAudioTap.
    nonisolated private static func inputBundleIds() -> Set<String> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processes) == noErr
        else { return [] }

        let ownPID = getpid()
        let ownBundleID = Bundle.main.bundleIdentifier
        var ids: Set<String> = []
        for process in processes where process != AudioObjectID(kAudioObjectUnknown) {
            guard readProcessRunningInput(process) else { continue }
            if readProcessPID(process) == ownPID { continue }
            guard let bundleID = readProcessBundleID(process) else { continue }
            if bundleID == ownBundleID { continue }
            ids.insert(bundleID)
        }
        return ids
    }

    nonisolated private static func readProcessRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    nonisolated private static func readProcessPID(_ process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : -1
    }

    nonisolated private static func readProcessBundleID(_ process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var bundleID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &bundleID)
        guard status == noErr, let value = bundleID?.takeRetainedValue() else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }
}
