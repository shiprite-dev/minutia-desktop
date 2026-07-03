import AppKit
import CoreAudio
import Darwin
import Foundation
import UserNotifications

/// Watches the default input device for activity, then corroborates with the running meeting app
/// and a live calendar agenda item to decide whether a meeting is actually happening. Mic state is
/// event-driven via a CoreAudio property listener, corrected by a 15s poll (some devices, notably
/// AirPods, report stale `DeviceIsRunningSomewhere` values). While the mic is active, app/agenda
/// signals are polled every 5s and folded through `DetectionRules`.
@MainActor
final class MeetingDetector: ObservableObject {
    @Published private(set) var confidence: DetectionConfidence = .none

    static let notificationCategoryId = "app.minutia.meetingDetected"
    static let recordActionId = "app.minutia.record"

    private static var categoryRegistered = false

    /// Registers the "Record this meeting?" notification category and its Record action. Safe to
    /// call more than once (e.g. every app launch); only the first call does any work.
    static func registerNotificationCategory() {
        guard !categoryRegistered else { return }
        categoryRegistered = true
        let record = UNNotificationAction(
            identifier: recordActionId, title: "Record", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: notificationCategoryId, actions: [record], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

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
    private var notifiedHigh = false
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
        notifiedHigh = false
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
            notifiedHigh = false
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
        let app = DetectionRules.detectApp(
            processNames: Self.runningProcessNames(), bundleIds: Self.runningBundleIds())
        let agenda = await agendaSnapshot()
        let calendarLive = DetectionRules.liveAgendaItem(agenda, now: Date()) != nil
        let result = DetectionRules.assess(micActive: micActive, app: app, calendarLive: calendarLive)

        confidence = result
        if case .high = result {
            if !notifiedHigh {
                notifiedHigh = true
                postRecordNotification(app: app)
            }
        } else {
            notifiedHigh = false
        }
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

    private func postRecordNotification(app: MeetingApp?) {
        let content = UNMutableNotificationContent()
        content.title = "Record this meeting?"
        content.body = app.map { "Detected \($0.rawValue.capitalized) running." }
            ?? "Looks like a meeting just started."
        content.categoryIdentifier = Self.notificationCategoryId
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Raw signal gathering

    /// `NSWorkspace.runningApplications` misses helper processes like Zoom's `CptHost`, which never
    /// registers as a full running application, so bundle ids alone cannot detect an active Zoom
    /// call; process names via libproc catch it.
    private static func runningProcessNames() -> [String] {
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

    private static func runningBundleIds() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    }
}
