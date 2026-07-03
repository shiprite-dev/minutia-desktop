import Foundation
import AVFoundation

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
    private var converter: AVAudioConverter?
    private var running = false

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
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcm, _ in
            self?.process(pcm)
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    /// Disables voice processing before stopping the engine; the reverse order crashes on recent
    /// macOS.
    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine.stop()
        converter = nil
        running = false
    }

    deinit { stop() }

    private func process(_ pcm: AVAudioPCMBuffer) {
        guard let converter, pcm.frameLength > 0 else { return }
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
