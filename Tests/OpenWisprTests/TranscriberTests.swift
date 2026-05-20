import XCTest
@testable import OpenWisprLib

final class TranscriberTests: XCTestCase {

    func testBlankAudioMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO]"), "")
    }

    func testBlankAudioWithWhitespace() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("  [BLANK_AUDIO]  "), "")
    }

    func testMultipleMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] [silence]"), "")
    }

    func testParenthesizedMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(BLANK_AUDIO)"), "")
    }

    func testNonSpeechEventMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[Music] [Applause]"), "")
    }

    func testMarkerMixedWithText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO] world"), "hello world")
    }

    func testMarkerAtStartOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] hello"), "hello")
    }

    func testMarkerAtEndOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO]"), "hello")
    }

    func testNormalTextUnchanged() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello world"), "hello world")
    }

    func testEmptyString() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(""), "")
    }

    func testUnknownBracketsPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("see [1] and (later)"), "see [1] and (later)")
    }

    func testKnownMarkerStrippedUnknownPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] see [1]"), "see [1]")
    }

    func testSilenceGateSkipsSilentAudio() {
        let levels = AudioLevels(rms: 0, peak: 0, durationSeconds: 1, activeDurationSeconds: 0)

        XCTAssertTrue(Transcriber.shouldSkipForSilence(levels: levels))
    }

    func testSilenceGateKeepsAudibleAudio() {
        let levels = AudioLevels(rms: 0.05, peak: 0.2, durationSeconds: 1, activeDurationSeconds: 0.4)

        XCTAssertFalse(Transcriber.shouldSkipForSilence(levels: levels))
    }

    func testSilenceGateSkipsShortClick() {
        let levels = AudioLevels(rms: 0.05, peak: 1, durationSeconds: 1, activeDurationSeconds: 0.03)

        XCTAssertTrue(Transcriber.shouldSkipForSilence(levels: levels))
    }

    func testSilenceGateSkipsTooShortRecording() {
        let levels = AudioLevels(rms: 0.2, peak: 0.5, durationSeconds: 0.05, activeDurationSeconds: 0.05)

        XCTAssertTrue(Transcriber.shouldSkipForSilence(levels: levels))
    }
}
