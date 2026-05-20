import Foundation

public final class CodexTranslationService {
    public static func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        config: CodexTranslationConfig?
    ) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let config = config ?? CodexTranslationConfig()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-wispr-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        let args = makeArguments(
            config: config,
            outputURL: outputURL,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        process.arguments = args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(prompt(
            text: trimmed,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        ).utf8))
        try? stdinPipe.fileHandleForWriting.close()

        var stdoutData = Data()
        var stderrData = Data()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(config.effectiveTimeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            readGroup.wait()
            throw CodexTranslationError.timedOut
        }

        process.waitUntilExit()
        readGroup.wait()

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CodexTranslationError.failed(stderr.isEmpty ? "codex exec が失敗しました" : stderr)
        }

        if let output = try? String(contentsOf: outputURL, encoding: .utf8) {
            let cleaned = clean(output)
            if !cleaned.isEmpty { return cleaned }
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let cleaned = clean(stdout)
        guard !cleaned.isEmpty else {
            throw CodexTranslationError.emptyResponse
        }
        return cleaned
    }

    static func makeArguments(
        config: CodexTranslationConfig,
        outputURL: URL,
        workingDirectory: URL
    ) -> [String] {
        var args = [
            config.effectiveCommand,
            "exec",
            "--ephemeral",
            "--ignore-rules",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--color", "never",
            "--output-last-message", outputURL.path,
            "-C", workingDirectory.path,
            "-c", "model_reasoning_effort=\"low\"",
        ]
        if let model = config.model, !model.isEmpty {
            args += ["-m", model]
        }
        if let extraArgs = config.extraArgs {
            args += extraArgs
        }
        args.append("-")
        return args
    }

    private static func prompt(text: String, sourceLanguage: String, targetLanguage: String) -> String {
        """
        あなたは翻訳関数です。
        次のテキストを\(languageName(sourceLanguage))から\(languageName(targetLanguage))へ自然に翻訳してください。

        条件:
        - 翻訳結果だけを返す
        - 説明、引用符、Markdown、前置きは出さない
        - 入力が断片でも、意味を変えずに自然な文に整える
        - 固有名詞、コマンド、コード片は不必要に訳さない

        テキスト:
        \(text)
        """
    }

    private static func languageName(_ code: String) -> String {
        switch code.lowercased() {
        case "ja", "japanese":
            return "日本語"
        case "en", "english":
            return "英語"
        default:
            return code
        }
    }

    private static func clean(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CodexTranslationError: LocalizedError {
    case timedOut
    case emptyResponse
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Codex 翻訳がタイムアウトしました"
        case .emptyResponse:
            return "Codex 翻訳の応答が空でした"
        case .failed(let message):
            return "Codex 翻訳に失敗しました: \(message)"
        }
    }
}
