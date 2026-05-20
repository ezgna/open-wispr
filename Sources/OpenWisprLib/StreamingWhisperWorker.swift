import Foundation
import WhisperBridge

protocol StreamingWhisperEngine: AnyObject {
    func transcribe(samples: [Float]) throws -> String
}

enum StreamingWhisperWorkerError: LocalizedError {
    case modelNotFound(String)
    case initializationFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let modelSize):
            return "Streaming Whisper model '\(modelSize)' not found"
        case .initializationFailed(let message):
            return "Streaming Whisper initialization failed: \(message)"
        case .transcriptionFailed(let message):
            return "Streaming Whisper transcription failed: \(message)"
        }
    }
}

final class LibWhisperEngine: StreamingWhisperEngine {
    private var context: OpaquePointer?
    private let threads: Int32

    init(
        modelPath: String,
        language: String,
        threads: Int = 4,
        useGPU: Bool = true,
        flashAttention: Bool = true
    ) throws {
        self.threads = Int32(max(1, threads))
        var error: UnsafeMutablePointer<CChar>?
        context = modelPath.withCString { modelPathPointer in
            language.withCString { languagePointer in
                ow_whisper_create(
                    modelPathPointer,
                    languagePointer,
                    self.threads,
                    useGPU,
                    flashAttention,
                    &error
                )
            }
        }

        if let error {
            let message = String(cString: error)
            ow_whisper_free_string(error)
            throw StreamingWhisperWorkerError.initializationFailed(message)
        }
        if context == nil {
            throw StreamingWhisperWorkerError.initializationFailed("unknown error")
        }
    }

    deinit {
        if let context {
            ow_whisper_free_context(context)
        }
    }

    func transcribe(samples: [Float]) throws -> String {
        guard let context else {
            throw StreamingWhisperWorkerError.transcriptionFailed("context is not available")
        }
        guard !samples.isEmpty else { return "" }

        let options = OWWhisperTranscribeOptions(
            threads: threads,
            max_tokens: 0,
            audio_ctx: 0,
            no_timestamps: true,
            single_segment: false,
            suppress_nst: true
        )
        var error: UnsafeMutablePointer<CChar>?
        let result = samples.withUnsafeBufferPointer { buffer -> UnsafeMutablePointer<CChar>? in
            ow_whisper_transcribe(
                context,
                buffer.baseAddress,
                Int32(buffer.count),
                options,
                &error
            )
        }

        if let error {
            let message = String(cString: error)
            ow_whisper_free_string(error)
            throw StreamingWhisperWorkerError.transcriptionFailed(message)
        }
        guard let result else {
            throw StreamingWhisperWorkerError.transcriptionFailed("empty bridge result")
        }
        defer { ow_whisper_free_string(result) }
        return String(cString: result)
    }
}

struct StreamingWhisperTranscript: Equatable {
    let text: String
    let generatedAt: Date
    let sampleCount: Int
}

enum StreamingWhisperStopResult: Equatable {
    case transcript(String)
    case fallback(String)
}

final class StreamingWhisperWorker {
    typealias TimingLogger = (_ stage: String, _ duration: TimeInterval, _ details: String?) -> Void

    private let engine: StreamingWhisperEngine
    private let config: StreamingWhisperConfig
    private let timingLogger: TimingLogger?
    private let sampleRate = 16_000.0
    private let condition = NSCondition()
    private let inferenceQueue = DispatchQueue(label: "open-wispr.streaming-whisper.inference", qos: .userInitiated)

    private var sessionID = 0
    private var samples: [Float] = []
    private var latestTranscript: StreamingWhisperTranscript?
    private var isInferring = false
    private var pendingInference = false
    private var lastScheduledSampleCount = 0
    private var fallbackReason: String?

    init(
        engine: StreamingWhisperEngine,
        config: StreamingWhisperConfig,
        timingLogger: TimingLogger? = nil
    ) {
        self.engine = engine
        self.config = config
        self.timingLogger = timingLogger
    }

    static func make(
        modelSize: String,
        language: String,
        config: StreamingWhisperConfig,
        timingLogger: TimingLogger? = nil
    ) throws -> StreamingWhisperWorker {
        guard let modelPath = Transcriber.findModel(modelSize: modelSize) else {
            throw StreamingWhisperWorkerError.modelNotFound(modelSize)
        }

        let start = Date()
        let engine: LibWhisperEngine
        do {
            engine = try LibWhisperEngine(modelPath: modelPath, language: language, useGPU: true, flashAttention: true)
        } catch {
            print("Warning: streaming Whisper GPU init failed, retrying CPU: \(error.localizedDescription)")
            engine = try LibWhisperEngine(modelPath: modelPath, language: language, useGPU: false, flashAttention: false)
        }
        timingLogger?(
            "streaming-model-load",
            Date().timeIntervalSince(start),
            "model=\(modelSize) language=\(language)"
        )
        return StreamingWhisperWorker(engine: engine, config: config, timingLogger: timingLogger)
    }

    func startSession() {
        condition.lock()
        sessionID += 1
        samples.removeAll(keepingCapacity: true)
        latestTranscript = nil
        isInferring = false
        pendingInference = false
        lastScheduledSampleCount = 0
        fallbackReason = nil
        condition.broadcast()
        condition.unlock()
    }

    func appendPCM(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }

        condition.lock()
        defer { condition.unlock() }

        guard fallbackReason == nil else { return }

        samples.append(contentsOf: newSamples)
        let maxSampleCount = Int(config.effectiveMaxSessionSeconds * sampleRate)
        if samples.count > maxSampleCount {
            fallbackReason = "streaming session exceeded \(Self.format(config.effectiveMaxSessionSeconds))s"
            condition.broadcast()
            return
        }

        let stepSampleCount = Int(config.effectiveStepSeconds * sampleRate)
        if samples.count - lastScheduledSampleCount >= stepSampleCount {
            startInferenceLocked()
        }
    }

    func finishSession(waitSeconds: TimeInterval, staleSeconds: TimeInterval) -> StreamingWhisperStopResult {
        let waitStartedAt = Date()
        condition.lock()
        defer { condition.unlock() }

        if let fallbackReason {
            timingLogger?("streaming-stop-wait", Date().timeIntervalSince(waitStartedAt), "fallback=\(fallbackReason)")
            return .fallback(fallbackReason)
        }

        if let fresh = freshTranscriptLocked(staleSeconds: staleSeconds) {
            timingLogger?("streaming-stop-wait", Date().timeIntervalSince(waitStartedAt), "source=fresh chars=\(fresh.text.count)")
            return .transcript(fresh.text)
        }

        if !isInferring {
            startInferenceLocked()
        } else {
            pendingInference = true
        }

        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            condition.wait(until: deadline)
            if let fallbackReason {
                timingLogger?("streaming-stop-wait", Date().timeIntervalSince(waitStartedAt), "fallback=\(fallbackReason)")
                return .fallback(fallbackReason)
            }
            if let fresh = freshTranscriptLocked(staleSeconds: staleSeconds) {
                timingLogger?("streaming-stop-wait", Date().timeIntervalSince(waitStartedAt), "source=waited chars=\(fresh.text.count)")
                return .transcript(fresh.text)
            }
        }

        let reason = isInferring ? "streaming inference still running" : "no fresh streaming transcript"
        timingLogger?("streaming-stop-wait", Date().timeIntervalSince(waitStartedAt), "fallback=\(reason)")
        return .fallback(reason)
    }

    func shutdown() {
        condition.lock()
        sessionID += 1
        samples.removeAll()
        latestTranscript = nil
        fallbackReason = "worker shutdown"
        condition.broadcast()
        condition.unlock()
    }

    private func freshTranscriptLocked(staleSeconds: TimeInterval) -> StreamingWhisperTranscript? {
        guard let latestTranscript, !latestTranscript.text.isEmpty else { return nil }
        if Date().timeIntervalSince(latestTranscript.generatedAt) <= staleSeconds {
            return latestTranscript
        }
        return nil
    }

    private func startInferenceLocked() {
        guard !samples.isEmpty else { return }
        if isInferring {
            pendingInference = true
            return
        }

        let snapshot = samples
        let snapshotSessionID = sessionID
        isInferring = true
        pendingInference = false
        lastScheduledSampleCount = snapshot.count

        inferenceQueue.async { [weak self] in
            self?.runInference(sessionID: snapshotSessionID, samples: snapshot)
        }
    }

    private func runInference(sessionID snapshotSessionID: Int, samples snapshot: [Float]) {
        let start = Date()
        let sampleSeconds = Double(snapshot.count) / sampleRate
        let result: Result<String, Error>
        do {
            let raw = try engine.transcribe(samples: snapshot)
            let cleaned = Transcriber.stripWhisperMarkers(raw)
            result = .success(cleaned)
        } catch {
            result = .failure(error)
        }

        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }

        guard snapshotSessionID == sessionID else {
            return
        }

        switch result {
        case .success(let text):
            latestTranscript = StreamingWhisperTranscript(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                generatedAt: Date(),
                sampleCount: snapshot.count
            )
            timingLogger?(
                "streaming-infer",
                Date().timeIntervalSince(start),
                "audio=\(Self.format(sampleSeconds))s chars=\(latestTranscript?.text.count ?? 0)"
            )
        case .failure(let error):
            fallbackReason = error.localizedDescription
            timingLogger?(
                "streaming-infer",
                Date().timeIntervalSince(start),
                "error=\(error.localizedDescription)"
            )
        }

        isInferring = false
        if pendingInference && fallbackReason == nil {
            pendingInference = false
            startInferenceLocked()
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
