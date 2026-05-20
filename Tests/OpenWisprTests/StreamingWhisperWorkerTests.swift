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
}

private final class FakeStreamingWhisperEngine: StreamingWhisperEngine {
    private let handler: ([Float]) -> String
    private(set) var callCount = 0

    init(handler: @escaping ([Float]) -> String) {
        self.handler = handler
    }

    func transcribe(samples: [Float]) throws -> String {
        callCount += 1
        return handler(samples)
    }
}
