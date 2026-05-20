import XCTest
@testable import OpenWisprLib

final class CodexTranslationServiceTests: XCTestCase {
    func testMakeArgumentsUsesSupportedCodexExecOptions() {
        let config = CodexTranslationConfig(command: "codex", model: "gpt-5.5")
        let args = CodexTranslationService.makeArguments(
            config: config,
            outputURL: URL(fileURLWithPath: "/tmp/out.txt"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(args.prefix(2), ["codex", "exec"])
        XCTAssertFalse(args.contains("--ask-for-approval"))
        XCTAssertTrue(args.contains("--ephemeral"))
        XCTAssertTrue(args.contains("--ignore-rules"))
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        XCTAssertTrue(args.contains("model_reasoning_effort=\"none\""))
        XCTAssertEqual(args.suffix(1), ["-"])
    }

    func testMakeArgumentsAllowsExtraArgsToOverrideDefaults() {
        let config = CodexTranslationConfig(
            command: "codex",
            model: nil,
            reasoningEffort: "low",
            timeoutSeconds: nil,
            extraArgs: ["-c", "model_reasoning_effort=\"medium\""]
        )
        let args = CodexTranslationService.makeArguments(
            config: config,
            outputURL: URL(fileURLWithPath: "/tmp/out.txt"),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertTrue(args.contains("model_reasoning_effort=\"low\""))
        XCTAssertTrue(args.contains("model_reasoning_effort=\"medium\""))
        XCTAssertEqual(args.suffix(1), ["-"])
    }

    func testCodexTranslationConfigDefaultsToAppServerSpeedSettings() {
        let config = CodexTranslationConfig(backend: "appServer")

        XCTAssertEqual(config.effectiveBackend, .appServer)
        XCTAssertEqual(config.effectiveModel, "gpt-5.4-mini")
        XCTAssertEqual(config.effectiveReasoningEffort, "none")
        XCTAssertEqual(config.effectiveAppServerPort, 8768)
        XCTAssertTrue(config.shouldFallbackToExec)
    }
}
