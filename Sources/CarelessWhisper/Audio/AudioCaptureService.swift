import AVFoundation
import CoreAudio
import os

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isDefault: Bool
}

final class AudioCaptureService {
    private let logger = Logger(subsystem: "com.carelesswhisper", category: "AudioCapture")

    private var audioEngine: AVAudioEngine?
    private let buffer = AudioBuffer()
    private let chunkBuffer = AudioBuffer()
    var selectedDeviceID: AudioDeviceID?

    /// Callback fired from the audio thread when a speech chunk is ready (after a pause).
    var onSpeechChunkReady: (([Float]) -> Void)?

    // VAD parameters
    private var isSpeechActive = false
    private var silenceSampleCount = 0
    private let silenceThreshold: Float = 0.01
    private let silenceDurationSamples = Int(targetSampleRate * 0.6)  // 600ms pause
    private let minChunkSamples = Int(targetSampleRate * 0.3)         // 300ms minimum
    private let maxChunkSamples = Int(targetSampleRate * 10)           // 10s forced boundary

    /// Target format: 16kHz mono Float32 (what whisper.cpp expects)
    static let targetSampleRate: Double = 16000
    static let targetChannelCount: AVAudioChannelCount = 1

    private var targetFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount,
            interleaved: false
        )!
    }

    func availableInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        let defaultID = defaultInputDeviceID()

        return deviceIDs.compactMap { id -> AudioInputDevice? in
            // Check if device has input channels
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return nil }

            let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPointer.deallocate() }
            guard AudioObjectGetPropertyData(id, &streamAddress, 0, nil, &streamSize, bufferListPointer) == noErr else { return nil }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { return nil }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr,
                  let name = nameRef?.takeUnretainedValue() as String? else {
                return nil
            }

            return AudioInputDevice(id: id, name: name, isDefault: id == defaultID)
        }
    }

    func startCapture() throws {
        let engine = AVAudioEngine()

        if let deviceID = selectedDeviceID {
            try setInputDevice(deviceID, on: engine)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        logger.info("Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }

        isSpeechActive = false
        silenceSampleCount = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcmBuffer, _ in
            self?.processAudioBuffer(pcmBuffer, converter: converter)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
        logger.info("Audio capture started")
    }

    func stopCapture() -> [Float] {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        logger.info("Audio capture stopped")
        return buffer.flush()
    }

    /// Returns any audio accumulated since the last chunk boundary.
    func flushRemainingChunk() -> [Float] {
        return chunkBuffer.flush()
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        var deviceID = deviceID
        let unit = inputNode.audioUnit!
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            logger.warning("Failed to set input device (\(status)), using default")
        }
    }

    private func defaultInputDeviceID() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private func processAudioBuffer(_ pcmBuffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(
            Double(pcmBuffer.frameLength) * Self.targetSampleRate / pcmBuffer.format.sampleRate
        )
        guard frameCapacity > 0 else { return }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        if let error {
            logger.error("Conversion error: \(error)")
            return
        }

        guard let channelData = outputBuffer.floatChannelData,
              outputBuffer.frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
        buffer.append(samples)
        chunkBuffer.append(samples)

        // Voice activity detection
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))

        if rms > silenceThreshold {
            isSpeechActive = true
            silenceSampleCount = 0
        } else {
            silenceSampleCount += samples.count
        }

        // Emit chunk on pause after speech, or when chunk exceeds max duration
        let shouldEmit = (isSpeechActive && silenceSampleCount >= silenceDurationSamples)
            || chunkBuffer.count >= maxChunkSamples

        if shouldEmit {
            let chunk = chunkBuffer.flush()
            if chunk.count >= minChunkSamples {
                onSpeechChunkReady?(chunk)
            }
            isSpeechActive = false
            silenceSampleCount = 0
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case converterCreationFailed
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .invalidInputFormat:
            return "Invalid audio input format (sample rate is 0). Check microphone permissions."
        }
    }
}
