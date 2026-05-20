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
        let prompt = makePrompt(
            text: trimmed,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        if config.effectiveBackend == .appServer {
            do {
                return try CodexAppServerTranslationService.shared.translate(
                    text: trimmed,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    config: config
                )
            } catch {
                guard config.shouldFallbackToExec else { throw error }
                print("Codex app-server translation failed, falling back to codex exec: \(error.localizedDescription)")
            }
        }

        return try runWithExec(prompt: prompt, config: config)
    }

    public static func polish(
        text: String,
        language: String,
        config: CodexTranslationConfig?
    ) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let config = config ?? CodexTranslationConfig()
        let prompt = makePolishPrompt(text: trimmed, language: language)
        if config.effectiveBackend == .appServer {
            do {
                return try CodexAppServerTranslationService.shared.polish(
                    text: trimmed,
                    language: language,
                    config: config
                )
            } catch {
                guard config.shouldFallbackToExec else { throw error }
                print("Codex app-server polish failed, falling back to codex exec: \(error.localizedDescription)")
            }
        }

        return try runWithExec(prompt: prompt, config: config)
    }

    private static func runWithExec(prompt: String, config: CodexTranslationConfig) throws -> String {
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
        stdinPipe.fileHandleForWriting.write(Data(prompt.utf8))
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
            "-c", "model_reasoning_effort=\"\(config.effectiveReasoningEffort)\"",
        ]
        if config.model?.isEmpty == false {
            args += ["-m", config.effectiveModel]
        }
        if let extraArgs = config.extraArgs {
            args += extraArgs
        }
        args.append("-")
        return args
    }

    static func makePrompt(text: String, sourceLanguage: String, targetLanguage: String) -> String {
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

    static func makePolishPrompt(text: String, language: String) -> String {
        """
        あなたは音声入力の後処理関数です。
        Whisper の文字起こし結果を、入力言語を保ったまま自然で読みやすい文章に整えてください。

        入力の主な言語:
        \(languageName(language))

        条件:
        - 整形済み本文だけを返す
        - 説明、引用符、Markdown、前置きは出さない
        - 意味を変えない。情報を足さない
        - 日本語、英語、製品名、コード、コマンド、専門用語が混ざっている場合は、その混在を保つ
        - 日本語内の英語表記や固有名詞を不必要に翻訳しない
        - 誤認識と思われる箇所は文脈に合わせて自然に直す
        - 句読点、改行、段落を自然に補う
        - フィラー、言い直し、重複、不要な口癖を取り除く
        - 技術用語、固有名詞、アプリ名、ライブラリ名は一般的な表記へ整える
        - 不確かな専門用語は強く推測しすぎず、元の音に近い自然な表記を優先する

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

    static func clean(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func shutdown() {
        CodexAppServerTranslationService.shared.shutdown()
    }
}

enum CodexTranslationError: LocalizedError {
    case timedOut
    case emptyResponse
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Codex 処理がタイムアウトしました"
        case .emptyResponse:
            return "Codex 処理の応答が空でした"
        case .failed(let message):
            return "Codex 処理に失敗しました: \(message)"
        }
    }
}
