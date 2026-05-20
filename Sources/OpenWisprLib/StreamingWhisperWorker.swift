import Foundation
import WhisperBridge

struct WhisperSegment: Equatable {
    let startMs: Int
    let endMs: Int
    let text: String
}

protocol StreamingWhisperEngine: AnyObject {
    func transcribe(samples: [Float]) throws -> String
    func transcribeSegments(samples: [Float], initialPrompt: String?) throws -> [WhisperSegment]
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

    func transcribeSegments(samples: [Float], initialPrompt: String?) throws -> [WhisperSegment] {
        guard let context else {
            throw StreamingWhisperWorkerError.transcriptionFailed("context is not available")
        }
        guard !samples.isEmpty else { return [] }

        let options = OWWhisperTranscribeOptions(
            threads: threads,
            max_tokens: 64,
            audio_ctx: 0,
            no_timestamps: false,
            single_segment: false,
            suppress_nst: true
        )
        var error: UnsafeMutablePointer<CChar>?
        let result: OWWhisperSegmentResult = samples.withUnsafeBufferPointer { buffer in
            if let initialPrompt, !initialPrompt.isEmpty {
                return initialPrompt.withCString { promptPointer in
                    ow_whisper_transcribe_segments(
                        context,
                        buffer.baseAddress,
                        Int32(buffer.count),
                        options,
                        promptPointer,
                        &error
                    )
                }
            }
            return ow_whisper_transcribe_segments(
                context,
                buffer.baseAddress,
                Int32(buffer.count),
                options,
                nil,
                &error
            )
        }

        if let error {
            let message = String(cString: error)
            ow_whisper_free_string(error)
            throw StreamingWhisperWorkerError.transcriptionFailed(message)
        }
        defer { ow_whisper_free_segment_result(result) }

        guard let segments = result.segments, result.segment_count > 0 else { return [] }
        return UnsafeBufferPointer(start: segments, count: Int(result.segment_count)).map { segment in
            WhisperSegment(
                startMs: Int(segment.start_ms),
                endMs: Int(segment.end_ms),
                text: segment.text.map { String(cString: $0) } ?? ""
            )
        }
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

    private var confirmedText = ""
    private var previousHypothesis: String?
    private var agreementCandidate = ""
    private var agreementCount = 0

    private static let defaultGlossaryTerms = [
        "Typeless",
        "OpenWispr",
        "OpenWhispr",
        "Whisper",
        "whisper.cpp",
        "whisper-cli",
        "large-v3-turbo",
        "UFAL",
        "LocalAgreement",
        "OpenAI",
        "Codex",
        "Codex SDK",
        "@openai/codex-sdk",
        "GPT Realtime",
        "Realtime API",
        "WebSocket",
        "Ollama",
        "llama.cpp",
        "MLX",
        "OpenRouter",
        "LM Studio",
        "Hugging Face",
        "TypeScript",
        "JavaScript",
        "Node.js",
        "Bun",
        "Vite",
        "React",
        "Next.js",
        "Vercel",
        "Cloudflare",
        "Cloudflare Workers",
        "Supabase",
        "Drizzle",
        "PostgreSQL",
        "Postgres",
        "SQLite",
        "Redis",
        "Turso",
        "Expo",
        "Expo Router",
        "Expo UI",
        "React Native",
        "NativeWind",
        "Tailwind CSS",
        "Zustand",
        "Firebase",
        "Firestore",
        "AdMob",
        "RevenueCat",
        "EAS",
        "App Store Connect",
        "TestFlight",
        "Xcode",
        "Swift",
        "SwiftPM",
        "SwiftUI",
        "Homebrew",
        "GitHub",
        "GitHub CLI",
        "GitNexus",
        "MCP",
        "Playwright",
        "Docker",
        "Docker Compose",
        "Coolify",
        "Huly",
        "Traefik",
        "Tailscale",
        "BigQuery",
        "Google Cloud",
        "gcloud",
        "Discord",
        "Kokusheep",
        "Liner",
        "Persona Studio"
    ]

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
        confirmedText = ""
        previousHypothesis = nil
        agreementCandidate = ""
        agreementCount = 0
        condition.broadcast()
        condition.unlock()
    }

    func appendPCM(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }

        condition.lock()
        defer { condition.unlock() }

        guard fallbackReason == nil else { return }

        switch config.effectiveStrategy {
        case .precompute:
            appendPrecomputePCMLocked(newSamples)
        case .localAgreement:
            appendLocalAgreementPCMLocked(newSamples)
        }
    }

    func finishSession(waitSeconds: TimeInterval, staleSeconds: TimeInterval) -> StreamingWhisperStopResult {
        switch config.effectiveStrategy {
        case .precompute:
            return finishPrecomputeSession(waitSeconds: waitSeconds, staleSeconds: staleSeconds)
        case .localAgreement:
            return finishLocalAgreementSession(waitSeconds: waitSeconds)
        }
    }

    func shutdown() {
        condition.lock()
        sessionID += 1
        samples.removeAll()
        latestTranscript = nil
        fallbackReason = "worker shutdown"
        confirmedText = ""
        previousHypothesis = nil
        agreementCandidate = ""
        agreementCount = 0
        condition.broadcast()
        condition.unlock()
    }

    private func appendPrecomputePCMLocked(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
        let maxSampleCount = Int(config.effectiveMaxSessionSeconds * sampleRate)
        if samples.count > maxSampleCount {
            fallbackReason = "streaming session exceeded \(Self.format(config.effectiveMaxSessionSeconds))s"
            condition.broadcast()
            return
        }

        let stepSampleCount = Int(config.effectiveStepSeconds * sampleRate)
        if samples.count - lastScheduledSampleCount >= stepSampleCount {
            startPrecomputeInferenceLocked()
        }
    }

    private func appendLocalAgreementPCMLocked(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
        let maxSampleCount = Int(config.effectiveMaxUnconfirmedSeconds * sampleRate)
        if samples.count > maxSampleCount {
            fallbackReason = "agreement unconfirmed audio exceeded \(Self.format(config.effectiveMaxUnconfirmedSeconds))s"
            condition.broadcast()
            return
        }

        let chunkSampleCount = Int(config.effectiveChunkSeconds * sampleRate)
        if samples.count >= lastScheduledSampleCount + chunkSampleCount {
            startAgreementInferenceLocked()
        }
    }

    private func finishPrecomputeSession(waitSeconds: TimeInterval, staleSeconds: TimeInterval) -> StreamingWhisperStopResult {
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
            startPrecomputeInferenceLocked()
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

    private func finishLocalAgreementSession(waitSeconds: TimeInterval) -> StreamingWhisperStopResult {
        let waitStartedAt = Date()
        let snapshot: [Float]
        let prompt: String?
        let snapshotSessionID: Int

        condition.lock()
        if let fallbackReason {
            condition.unlock()
            timingLogger?("agreement-stop-final", Date().timeIntervalSince(waitStartedAt), "fallback=\(fallbackReason)")
            return .fallback(fallbackReason)
        }

        let deadline = Date().addingTimeInterval(waitSeconds)
        while isInferring && Date() < deadline {
            condition.wait(until: deadline)
            if let fallbackReason {
                condition.unlock()
                timingLogger?("agreement-stop-final", Date().timeIntervalSince(waitStartedAt), "fallback=\(fallbackReason)")
                return .fallback(fallbackReason)
            }
        }

        if isInferring {
            condition.unlock()
            let reason = "agreement inference still running"
            timingLogger?("agreement-stop-final", Date().timeIntervalSince(waitStartedAt), "fallback=\(reason)")
            return .fallback(reason)
        }

        if samples.isEmpty {
            let text = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
            condition.unlock()
            if text.isEmpty {
                timingLogger?("agreement-stop-final", Date().timeIntervalSince(waitStartedAt), "fallback=no agreement transcript")
                return .fallback("no agreement transcript")
            }
            timingLogger?("agreement-stop-final", Date().timeIntervalSince(waitStartedAt), "source=confirmed chars=\(text.count)")
            return .transcript(text)
        }

        snapshot = samples
        prompt = makeInitialPromptLocked()
        snapshotSessionID = sessionID
        condition.unlock()

        let finalStartedAt = Date()
        let result: Result<[WhisperSegment], Error>
        do {
            result = .success(try engine.transcribeSegments(samples: snapshot, initialPrompt: prompt))
        } catch {
            result = .failure(error)
        }

        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }

        guard snapshotSessionID == sessionID else {
            return .fallback("agreement session changed")
        }

        switch result {
        case .success(let segments):
            let tail = Self.joinSegmentText(Self.cleanSegments(segments))
            let text = Self.finalText(confirmedText + tail)
            timingLogger?(
                "agreement-stop-final",
                Date().timeIntervalSince(finalStartedAt),
                "audio=\(Self.format(Double(snapshot.count) / sampleRate))s tailChars=\(tail.count) chars=\(text.count)"
            )
            if text.isEmpty {
                return .fallback("empty agreement transcript")
            }
            return .transcript(text)
        case .failure(let error):
            let reason = error.localizedDescription
            timingLogger?("agreement-stop-final", Date().timeIntervalSince(finalStartedAt), "fallback=\(reason)")
            return .fallback(reason)
        }
    }

    private func freshTranscriptLocked(staleSeconds: TimeInterval) -> StreamingWhisperTranscript? {
        guard let latestTranscript, !latestTranscript.text.isEmpty else { return nil }
        if Date().timeIntervalSince(latestTranscript.generatedAt) <= staleSeconds {
            return latestTranscript
        }
        return nil
    }

    private func startPrecomputeInferenceLocked() {
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
            self?.runPrecomputeInference(sessionID: snapshotSessionID, samples: snapshot)
        }
    }

    private func startAgreementInferenceLocked() {
        guard !samples.isEmpty else { return }
        if isInferring {
            pendingInference = true
            return
        }

        let snapshot = samples
        let prompt = makeInitialPromptLocked()
        let snapshotSessionID = sessionID
        isInferring = true
        pendingInference = false
        lastScheduledSampleCount = snapshot.count

        inferenceQueue.async { [weak self] in
            self?.runAgreementInference(sessionID: snapshotSessionID, samples: snapshot, initialPrompt: prompt)
        }
    }

    private func runPrecomputeInference(sessionID snapshotSessionID: Int, samples snapshot: [Float]) {
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
            startPrecomputeInferenceLocked()
        }
    }

    private func runAgreementInference(sessionID snapshotSessionID: Int, samples snapshot: [Float], initialPrompt: String?) {
        let start = Date()
        let sampleSeconds = Double(snapshot.count) / sampleRate
        let result: Result<[WhisperSegment], Error>
        do {
            result = .success(try engine.transcribeSegments(samples: snapshot, initialPrompt: initialPrompt))
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
        case .success(let segments):
            let cleanedSegments = Self.cleanSegments(segments)
            applyAgreementLocked(segments: cleanedSegments, snapshotSampleCount: snapshot.count)
            timingLogger?(
                "agreement-infer",
                Date().timeIntervalSince(start),
                "audio=\(Self.format(sampleSeconds))s confirmed=\(confirmedText.count) hypothesis=\(previousHypothesis?.count ?? 0)"
            )
        case .failure(let error):
            fallbackReason = error.localizedDescription
            timingLogger?(
                "agreement-infer",
                Date().timeIntervalSince(start),
                "error=\(error.localizedDescription)"
            )
        }

        isInferring = false
        if pendingInference && fallbackReason == nil {
            pendingInference = false
            startAgreementInferenceLocked()
        }
    }

    private func applyAgreementLocked(segments: [WhisperSegment], snapshotSampleCount: Int) {
        let hypothesis = Self.joinSegmentText(segments)
        guard !hypothesis.isEmpty else {
            previousHypothesis = ""
            agreementCandidate = ""
            agreementCount = 0
            return
        }

        var didCommit = false
        if let previousHypothesis, !previousHypothesis.isEmpty {
            let rawPrefix = Self.commonPrefix(previousHypothesis, hypothesis)
            if let commit = Self.segmentCommit(for: rawPrefix, segments: segments) {
                if commit.text == agreementCandidate {
                    agreementCount += 1
                } else {
                    agreementCandidate = commit.text
                    agreementCount = 2
                }

                if agreementCount >= config.effectiveAgreementN {
                    commitAgreementLocked(commit, segments: segments, reason: "agreement")
                    didCommit = true
                } else {
                    self.previousHypothesis = hypothesis
                }
            } else {
                self.previousHypothesis = hypothesis
                agreementCandidate = ""
                agreementCount = 0
            }
        } else {
            self.previousHypothesis = hypothesis
        }

        if !didCommit, let commit = Self.ageBasedCommit(
            segments: segments,
            snapshotSampleCount: snapshotSampleCount,
            sampleRate: sampleRate,
            stableTailSeconds: config.effectiveStableTailSeconds
        ) {
            commitAgreementLocked(commit, segments: segments, reason: "age")
        }
    }

    private func commitAgreementLocked(
        _ commit: (text: String, endMs: Int, segmentCount: Int),
        segments: [WhisperSegment],
        reason: String
    ) {
        confirmedText += commit.text
        let trimCount = min(Int((Double(commit.endMs) / 1000.0) * sampleRate), samples.count)
        if trimCount > 0 {
            samples.removeFirst(trimCount)
            lastScheduledSampleCount = max(0, lastScheduledSampleCount - trimCount)
        }
        let remaining = Array(segments.dropFirst(commit.segmentCount))
        self.previousHypothesis = Self.joinSegmentText(remaining)
        agreementCandidate = ""
        agreementCount = 0
        timingLogger?(
            "agreement-commit",
            0,
            "reason=\(reason) chars=\(commit.text.count) end=\(Self.format(Double(commit.endMs) / 1000.0))s remainingAudio=\(Self.format(Double(samples.count) / sampleRate))s"
        )
    }

    private func makeInitialPromptLocked() -> String? {
        let glossary = Self.defaultGlossaryTerms.joined(separator: ", ") + "."
        let suffix = String(confirmedText.suffix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.isEmpty {
            return glossary
        }
        return "\(suffix)\n\(glossary)"
    }

    private static func cleanSegments(_ segments: [WhisperSegment]) -> [WhisperSegment] {
        segments.compactMap { segment in
            let text = Transcriber.stripWhisperMarkers(segment.text)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return WhisperSegment(startMs: segment.startMs, endMs: segment.endMs, text: text)
        }
    }

    private static func joinSegmentText(_ segments: [WhisperSegment]) -> String {
        finalText(segments.map(\.text).joined())
    }

    private static func finalText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        var result = ""
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            result.append(left)
        }
        return result
    }

    private static func segmentCommit(for prefix: String, segments: [WhisperSegment]) -> (text: String, endMs: Int, segmentCount: Int)? {
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var accumulated = ""
        var committedText = ""
        var committedEndMs = 0
        var committedCount = 0

        for segment in segments {
            let next = accumulated + segment.text
            if next.count <= prefix.count {
                accumulated = next
                committedText += segment.text
                committedEndMs = max(committedEndMs, segment.endMs)
                committedCount += 1
            } else {
                break
            }
        }

        guard !committedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, committedCount > 0 else { return nil }
        return (committedText, committedEndMs, committedCount)
    }

    private static func ageBasedCommit(
        segments: [WhisperSegment],
        snapshotSampleCount: Int,
        sampleRate: Double,
        stableTailSeconds: TimeInterval
    ) -> (text: String, endMs: Int, segmentCount: Int)? {
        let snapshotMs = Int((Double(snapshotSampleCount) / sampleRate) * 1000.0)
        let cutoffMs = max(0, snapshotMs - Int(stableTailSeconds * 1000.0))
        guard cutoffMs > 0 else { return nil }

        var committedText = ""
        var committedEndMs = 0
        var committedCount = 0

        for segment in segments {
            guard segment.endMs <= cutoffMs else { break }
            committedText += segment.text
            committedEndMs = max(committedEndMs, segment.endMs)
            committedCount += 1
        }

        guard !committedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, committedCount > 0 else { return nil }
        return (committedText, committedEndMs, committedCount)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
