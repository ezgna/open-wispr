import AVFoundation
import CoreAudio
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var currentOutputURL: URL?
    private let levelsLock = NSLock()
    private var levelSumSquares = 0.0
    private var levelPeak = 0.0
    private var levelSampleCount = 0
    private var levelDurationSeconds = 0.0
    private var levelActiveDurationSeconds = 0.0
    private(set) var lastRecordingLevels: AudioLevels?
    var preferredDeviceID: AudioDeviceID?
    var pcmHandler: (([Float]) -> Void)?

    func prewarm() {
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()

        if let deviceID = preferredDeviceID,
           deviceID != AudioDeviceManager.getDefaultInputDeviceID() {
            setInputDevice(deviceID, on: engine)
        }

        _ = engine.inputNode
        engine.prepare()
        audioEngine = engine
    }

    /// Stop and release the engine. Call before changing input device or on shutdown.
    func teardown() {
        if isRecording {
            audioEngine?.inputNode.removeTap(onBus: 0)
            isRecording = false
            currentOutputURL = nil
        }
        pcmHandler = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    /// Re-prewarm with the current preferredDeviceID. Use after a config change.
    func reload() {
        teardown()
        prewarm()
    }

    func startRecording(to outputURL: URL) throws {
        guard !isRecording else { return }
        resetRecordingLevels()

        if audioEngine == nil {
            prewarm()
        }

        guard let engine = audioEngine else {
            throw NSError(
                domain: "OpenWispr.AudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio engine is not available"]
            )
        }

        try engine.start()

        let inputFmt = engine.inputNode.outputFormat(forBus: 0)

        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let file = try AVAudioFile(forWriting: outputURL, settings: settings)
        let converter = AVAudioConverter(from: inputFmt, to: recordingFormat)

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFmt) { buffer, _ in
            guard let converter = converter else { return }

            let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: recordingFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(buffer.frameLength) * 16000.0 / inputFmt.sampleRate
                )
            )!

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil && convertedBuffer.frameLength > 0 {
                self.updateRecordingLevels(from: convertedBuffer)
                if let samples = Self.copyFloatSamples(from: convertedBuffer) {
                    self.pcmHandler?(samples)
                }
                try? file.write(from: convertedBuffer)
            }
        }

        currentOutputURL = outputURL
        isRecording = true
    }

    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        let url = currentOutputURL
        currentOutputURL = nil
        pcmHandler = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        lastRecordingLevels = currentRecordingLevels()

        return url
    }

    private func resetRecordingLevels() {
        levelsLock.lock()
        levelSumSquares = 0
        levelPeak = 0
        levelSampleCount = 0
        levelDurationSeconds = 0
        levelActiveDurationSeconds = 0
        lastRecordingLevels = nil
        levelsLock.unlock()
    }

    private func updateRecordingLevels(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0 && channelCount > 0 else { return }

        var sumSquares = 0.0
        var peak = 0.0
        var sampleCount = 0
        var activeSampleCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let value = Double(samples[frame])
                let absolute = abs(value)
                sumSquares += value * value
                peak = max(peak, absolute)
                if absolute >= Transcriber.speechSampleLevelThreshold {
                    activeSampleCount += 1
                }
                sampleCount += 1
            }
        }

        let sampleRate = buffer.format.sampleRate
        levelsLock.lock()
        levelSumSquares += sumSquares
        levelPeak = max(levelPeak, peak)
        levelSampleCount += sampleCount
        levelDurationSeconds += Double(frameLength) / sampleRate
        levelActiveDurationSeconds += Double(activeSampleCount) / Double(channelCount) / sampleRate
        levelsLock.unlock()
    }

    private func currentRecordingLevels() -> AudioLevels {
        levelsLock.lock()
        defer { levelsLock.unlock() }

        guard levelSampleCount > 0 else {
            return AudioLevels(rms: 0, peak: 0, durationSeconds: 0, activeDurationSeconds: 0)
        }

        return AudioLevels(
            rms: sqrt(levelSumSquares / Double(levelSampleCount)),
            peak: levelPeak,
            durationSeconds: levelDurationSeconds,
            activeDurationSeconds: levelActiveDurationSeconds
        )
    }

    private static func copyFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }

        let samples = channelData[0]
        return Array(UnsafeBufferPointer(start: samples, count: frameLength))
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) {
        guard let audioUnit = engine.inputNode.audioUnit else {
            print("Warning: could not access audio unit to set input device")
            return
        }

        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("Warning: failed to set audio input device (status: \(status))")
        }
    }
}
