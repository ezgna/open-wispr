import XCTest
@testable import OpenWisprLib

final class StreamingWhisperWorkerTests: XCTestCase {
    func testFinishSessionReturnsStreamingTranscript() {
        let engine = FakeStreamingWhisperEngine { samples in
            "samples=\(samples.count)"
        }
        let worker = StreamingWhisperWorker(
            engine: engine,
            config: StreamingWhisperConfig(stepMs: 100, staleMs: 1000, stopWaitMs: 1000, maxSessionSeconds: 2)
        )

        worker.startSession()
        worker.appendPCM(Array(repeating: 0.1, count: 1600))

        let result = worker.finishSession(waitSeconds: 1, staleSeconds: 1)

        XCTAssertEqual(result, .transcript("samples=1600"))
        XCTAssertEqual(engine.callCount, 1)
    }

    func testFinishSessionFallsBackWhenNoSamples() {
        let worker = StreamingWhisperWorker(
            engine: FakeStreamingWhisperEngine { _ in "unused" },
            config: StreamingWhisperConfig(stepMs: 100, staleMs: 1000, stopWaitMs: 0, maxSessionSeconds: 2)
        )

        worker.startSession()

        let result = worker.finishSession(waitSeconds: 0, staleSeconds: 1)

        if case .fallback(let reason) = result {
            XCTAssertTrue(reason.contains("no fresh"))
        } else {
            XCTFail("expected fallback, got \(result)")
        }
    }

    func testSessionFallsBackWhenMaxDurationExceeded() {
        let worker = StreamingWhisperWorker(
            engine: FakeStreamingWhisperEngine { _ in "unused" },
            config: StreamingWhisperConfig(stepMs: 100, staleMs: 1000, stopWaitMs: 0, maxSessionSeconds: 1)
        )

        worker.startSession()
        worker.appendPCM(Array(repeating: 0.1, count: 16_001))

        let result = worker.finishSession(waitSeconds: 0, staleSeconds: 1)

        if case .fallback(let reason) = result {
            XCTAssertTrue(reason.contains("exceeded"))
        } else {
            XCTFail("expected fallback, got \(result)")
        }
    }

    func testStartSessionClearsPreviousTranscript() {
        let worker = StreamingWhisperWorker(
            engine: FakeStreamingWhisperEngine { _ in "hello" },
            config: StreamingWhisperConfig(stepMs: 100, staleMs: 1000, stopWaitMs: 1000, maxSessionSeconds: 2)
        )

        worker.startSession()
        worker.appendPCM(Array(repeating: 0.1, count: 1600))
        XCTAssertEqual(worker.finishSession(waitSeconds: 1, staleSeconds: 1), .transcript("hello"))

        worker.startSession()
        let result = worker.finishSession(waitSeconds: 0, staleSeconds: 1)

        if case .fallback = result {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected fallback after reset, got \(result)")
        }
    }

    func testLocalAgreementCommitsRepeatedSegmentPrefix() {
        let engine = FakeStreamingWhisperEngine(
            textHandler: { _ in "unused" },
            segmentHandler: { callIndex, _ in
                if callIndex == 1 {
                    return [
                        WhisperSegment(startMs: 0, endMs: 1000, text: "Drizzleを"),
                        WhisperSegment(startMs: 1000, endMs: 2000, text: "入れる")
                    ]
                }
                if callIndex == 2 {
                    return [
                        WhisperSegment(startMs: 0, endMs: 1000, text: "Drizzleを"),
                        WhisperSegment(startMs: 1000, endMs: 2500, text: "入れるべき")
                    ]
                }
                return [
                    WhisperSegment(startMs: 0, endMs: 1500, text: "入れるべき")
                ]
            }
        )
        let worker = StreamingWhisperWorker(
            engine: engine,
            config: StreamingWhisperConfig(
                strategy: "localAgreement",
                chunkMs: 100,
                agreementN: 2,
                stopFinalWaitMs: 1000,
                maxUnconfirmedSeconds: 5
            )
        )

        worker.startSession()
        worker.appendPCM(Array(repeating: 0.1, count: 16_000))
        worker.appendPCM(Array(repeating: 0.1, count: 32_000))

        let result = worker.finishSession(waitSeconds: 1, staleSeconds: 1)

        XCTAssertEqual(result, .transcript("Drizzleを入れるべき"))
        XCTAssertEqual(engine.segmentCallCount, 3)
    }

    func testLocalAgreementStopUsesFinalTailWithoutPriorCommit() {
        let engine = FakeStreamingWhisperEngine(
            textHandler: { _ in "unused" },
            segmentHandler: { _, _ in
                [WhisperSegment(startMs: 0, endMs: 900, text: "Supabase Storage")]
            }
        )
        let worker = StreamingWhisperWorker(
            engine: engine,
            config: StreamingWhisperConfig(
                strategy: "localAgreement",
                chunkMs: 5000,
                agreementN: 2,
                stopFinalWaitMs: 1000,
                maxUnconfirmedSeconds: 5
            )
        )

        worker.startSession()
        worker.appendPCM(Array(repeating: 0.1, count: 1600))

        let result = worker.finishSession(waitSeconds: 1, staleSeconds: 1)

        XCTAssertEqual(result, .transcript("Supabase Storage"))
        XCTAssertEqual(engine.segmentCallCount, 1)
    }

    func testLocalAgreementInitialPromptIncludesFixedGlossary() {
        let engine = FakeStreamingWhisperEngine(
            textHandler: { _ in "unused" },
            segmentHandler: { _, _ in
                [WhisperSegment(startMs: 0, endMs: 900, text: "Typeless")]
            }
        )
        let worker = StreamingWhisperWorker(
            engine: engine,
            config: StreamingWhisperConfig(
                strategy: "localAgreement",
                chunkMs: 5000,
                stopFinalWaitMs: 1000
            )
        )

        worker.startSession()
        worker.appendPCM(Array(repeating: 0.1, count: 1600))

        _ = worker.finishSession(waitSeconds: 1, staleSeconds: 1)

        XCTAssertEqual(engine.segmentCallCount, 1)
        XCTAssertTrue(engine.initialPrompts.first??.contains("Typeless") == true)
        XCTAssertTrue(engine.initialPrompts.first??.contains("OpenWispr") == true)
        XCTAssertTrue(engine.initialPrompts.first??.contains("TypeScript") == true)
    }

    func testLocalAgreementAgeBasedCommitKeepsStableTail() {
        let engine = FakeStreamingWhisperEngine(
            textHandler: { _ in "unused" },
            segmentHandler: { callIndex, _ in
                if callIndex == 1 {
                    return [
                        WhisperSegment(startMs: 0, endMs: 1000, text: "Cloudflare"),
                        WhisperSegment(startMs: 1000, endMs: 2000, text: "と"),
                        WhisperSegment(startMs: 2000, endMs: 3000, text: "Drizzle")
                    ]
                }
                return [
                    WhisperSegment(startMs: 0, endMs: 1000, text: "Drizzle")
                ]
            }
        )
        let worker = StreamingWhisperWorker(
            engine: engine,
            config: StreamingWhisperConfig(
                strategy: "localAgreement",
                chunkMs: 100,
                agreementN: 2,
                stopFinalWaitMs: 1000,
                maxUnconfirmedSeconds: 10,
                stableTailMs: 1000
            )
        )

        worker.startSession()
        worker.appendPCM(Array(repeating: 0.1, count: 48_000))

        let result = worker.finishSession(waitSeconds: 1, staleSeconds: 1)

        XCTAssertEqual(result, .transcript("CloudflareとDrizzle"))
        XCTAssertEqual(engine.segmentCallCount, 2)
    }

    func testLocalAgreementFallsBackWhenUnconfirmedAudioExceeded() {
        let worker = StreamingWhisperWorker(
            engine: FakeStreamingWhisperEngine { _ in "unused" },
            config: StreamingWhisperConfig(
                strategy: "localAgreement",
                chunkMs: 100,
                agreementN: 2,
                stopFinalWaitMs: 0,
                maxUnconfirmedSeconds: 1
            )
        )

        worker.startSession()
        worker.appendPCM(Array(repeating: 0.1, count: 16_001))

        let result = worker.finishSession(waitSeconds: 0, staleSeconds: 1)

        if case .fallback(let reason) = result {
            XCTAssertTrue(reason.contains("unconfirmed"))
        } else {
            XCTFail("expected fallback, got \(result)")
        }
    }
}

private final class FakeStreamingWhisperEngine: StreamingWhisperEngine {
    private let handler: ([Float]) -> String
    private let segmentHandler: (Int, [Float]) -> [WhisperSegment]
    private(set) var callCount = 0
    private(set) var segmentCallCount = 0
    private(set) var initialPrompts: [String?] = []

    init(handler: @escaping ([Float]) -> String) {
        self.handler = handler
        self.segmentHandler = { _, _ in [] }
    }

    init(
        textHandler: @escaping ([Float]) -> String,
        segmentHandler: @escaping (Int, [Float]) -> [WhisperSegment]
    ) {
        self.handler = textHandler
        self.segmentHandler = segmentHandler
    }

    func transcribe(samples: [Float]) throws -> String {
        callCount += 1
        return handler(samples)
    }

    func transcribeSegments(samples: [Float], initialPrompt: String?) throws -> [WhisperSegment] {
        segmentCallCount += 1
        initialPrompts.append(initialPrompt)
        return segmentHandler(segmentCallCount, samples)
    }
}
