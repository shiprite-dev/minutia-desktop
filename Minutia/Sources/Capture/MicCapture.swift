import Foundation
import AVFoundation
import os

/// Captures the local microphone through AVAudioEngine's voice-processing IO (echo cancellation +
/// noise suppression), converts to 48k mono Float32, and feeds a ring buffer. Ducking of other
/// audio is disabled so the system-audio tap still records the far end at full level.
final class MicCapture {
    enum CaptureError: Error {
        case permissionDenied
        case converterUnavailable
    }

    private let buffer: RingBuffer
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: MixPlan.sampleRate,
        channels: 1, interleaved: false)!
    private var running = false
    private var configObserver: NSObjectProtocol?

    // The converter is swapped on the config-change thread (device handoff) while the realtime tap
    // block reads it, so a lock guards the reference: the render thread snapshots (retains) it under
    // the lock and runs the conversion on the snapshot outside it.
    private var _converter: AVAudioConverter?
    private var converterLock = os_unfair_lock()

    private func setConverter(_ value: AVAudioConverter?) {
        os_unfair_lock_lock(&converterLock)
        _converter = value
        os_unfair_lock_unlock(&converterLock)
    }

    private func currentConverter() -> AVAudioConverter? {
        os_unfair_lock_lock(&converterLock)
        defer { os_unfair_lock_unlock(&converterLock) }
        return _converter
    }

    init(into buffer: RingBuffer) {
        self.buffer = buffer
    }

    /// Requests mic permission, enables voice processing, then starts the engine. Voice processing
    /// must be enabled before `engine.start()`, and the tap format is re-read after enabling it
    /// because enabling VP changes the input node's output format.
    func start() async throws {
        guard !running else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError.permissionDenied
        }

        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)

        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        setConverter(converter)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcm, _ in
            self?.process(pcm)
        }

        engine.prepare()
        try engine.start()
        running = true

        // Rebuild the tap + converter when the input device changes mid-recording (an AirPods mic
        // handoff), otherwise the stale tap drains silence against the old format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// Disables voice processing before stopping the engine; the reverse order crashes on recent
    /// macOS.
    func stop() {
        guard running else { return }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.stop()
        setConverter(nil)
        running = false
    }

    deinit { stop() }

    private func handleConfigurationChange() {
        guard running else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }
        input.removeTap(onBus: 0)
        setConverter(converter)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcm, _ in
            self?.process(pcm)
        }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    private func process(_ pcm: AVAudioPCMBuffer) {
        guard let converter = currentConverter(), pcm.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return pcm
        }

        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData else {
            return
        }
        buffer.push(channel[0], count: Int(out.frameLength))
    }
}
