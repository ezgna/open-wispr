import Foundation

final class CodexAppServerTranslationService {
    static let shared = CodexAppServerTranslationService()

    private let lock = NSLock()
    private var process: Process?
    private var session: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var nextRequestID = 1

    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        config: CodexTranslationConfig
    ) throws -> String {
        let prompt = CodexTranslationService.makePrompt(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        return try run(
            prompt: prompt,
            config: config,
            baseInstructions: "あなたは翻訳関数です。最終的な翻訳文だけを返してください。ツールは使わず、説明もしません。",
            developerInstructions: "意味を保って自然かつ正確に翻訳してください。出力はプレーンテキストだけにしてください。"
        )
    }

    func polish(
        text: String,
        language: String,
        config: CodexTranslationConfig
    ) throws -> String {
        let prompt = CodexTranslationService.makePolishPrompt(text: text, language: language)
        return try run(
            prompt: prompt,
            config: config,
            baseInstructions: "あなたは音声入力の整形関数です。最終的な整形済み本文だけを返してください。ツールは使わず、説明もしません。",
            developerInstructions: "入力言語と意味を保ち、句読点、改行、専門用語表記、誤認識を自然に整えてください。出力はプレーンテキストだけにしてください。"
        )
    }

    private func run(
        prompt: String,
        config: CodexTranslationConfig,
        baseInstructions: String,
        developerInstructions: String
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let deadline = Date().addingTimeInterval(config.effectiveTimeoutSeconds)
        do {
            return try runLocked(
                prompt: prompt,
                config: config,
                baseInstructions: baseInstructions,
                developerInstructions: developerInstructions,
                deadline: deadline
            )
        } catch {
            resetConnection(terminateProcess: true)
            return try runLocked(
                prompt: prompt,
                config: config,
                baseInstructions: baseInstructions,
                developerInstructions: developerInstructions,
                deadline: Date().addingTimeInterval(config.effectiveTimeoutSeconds)
            )
        }
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        resetConnection(terminateProcess: true)
    }

    private func runLocked(
        prompt: String,
        config: CodexTranslationConfig,
        baseInstructions: String,
        developerInstructions: String,
        deadline: Date
    ) throws -> String {
        let connectStartedAt = Date()
        try ensureConnected(config: config, deadline: deadline)
        Self.logTiming(stage: "appserver-connect", duration: Date().timeIntervalSince(connectStartedAt))
        let threadStartedAt = Date()
        let threadID = try startThread(
            config: config,
            deadline: deadline,
            baseInstructions: baseInstructions,
            developerInstructions: developerInstructions
        )
        Self.logTiming(stage: "thread-start", duration: Date().timeIntervalSince(threadStartedAt))
        defer { try? unsubscribe(threadID: threadID) }

        let turnStartedAt = Date()
        let turnRequestID = try sendRequest(method: "turn/start", params: [
            "threadId": threadID,
            "input": [
                [
                    "type": "text",
                    "text": prompt,
                    "text_elements": [],
                ],
            ],
            "effort": config.effectiveReasoningEffort,
            "model": config.effectiveModel,
        ])

        var streamedText = ""
        var completedText = ""

        while Date() < deadline {
            let message = try receiveJSON(deadline: deadline)

            if let id = message["id"] as? Int, id == turnRequestID {
                try throwIfError(message)
                continue
            }

            guard let method = message["method"] as? String else { continue }
            switch method {
            case "item/agentMessage/delta":
                if let params = message["params"] as? [String: Any],
                   params["threadId"] as? String == threadID,
                   let delta = params["delta"] as? String {
                    streamedText += delta
                }
            case "item/completed":
                if let params = message["params"] as? [String: Any],
                   params["threadId"] as? String == threadID,
                   let item = params["item"] as? [String: Any],
                   item["type"] as? String == "agentMessage",
                   let text = item["text"] as? String {
                    completedText = text
                }
            case "turn/completed":
                if let params = message["params"] as? [String: Any],
                   params["threadId"] as? String == threadID {
                    let result = streamedText.isEmpty ? completedText : streamedText
                    let cleaned = CodexTranslationService.clean(result)
                    guard !cleaned.isEmpty else { throw CodexTranslationError.emptyResponse }
                    Self.logTiming(
                        stage: "turn-completed",
                        duration: Date().timeIntervalSince(turnStartedAt),
                        details: "chars=\(cleaned.count)"
                    )
                    return cleaned
                }
            case "error":
                throw CodexTranslationError.failed(describeError(message))
            default:
                continue
            }
        }

        throw CodexTranslationError.timedOut
    }

    private static func logTiming(stage: String, duration: TimeInterval, details: String? = nil) {
        let suffix = details.map { " \($0)" } ?? ""
        TimingLog.write("Timing: codex stage=\(stage) duration=\(format(duration))s\(suffix)")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func ensureConnected(config: CodexTranslationConfig, deadline: Date) throws {
        if webSocket != nil { return }

        do {
            try connectAndInitialize(config: config, deadline: deadline)
            return
        } catch {
            resetConnection(terminateProcess: false)
        }

        try startAppServer(config: config)

        var lastError: Error?
        while Date() < deadline {
            do {
                try connectAndInitialize(config: config, deadline: deadline)
                return
            } catch {
                lastError = error
                resetConnection(terminateProcess: false)
                Thread.sleep(forTimeInterval: 0.15)
            }
        }

        throw lastError ?? CodexTranslationError.timedOut
    }

    private func startThread(
        config: CodexTranslationConfig,
        deadline: Date,
        baseInstructions: String,
        developerInstructions: String
    ) throws -> String {
        var params: [String: Any] = [
            "model": config.effectiveModel,
            "cwd": FileManager.default.temporaryDirectory.path,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "ephemeral": true,
            "baseInstructions": baseInstructions,
            "developerInstructions": developerInstructions,
            "config": [
                "model_reasoning_effort": config.effectiveReasoningEffort,
                "web_search": "disabled",
                "tools": [
                    "view_image": false,
                ],
            ],
        ]
        if let serviceTier = config.serviceTier, !serviceTier.isEmpty {
            params["serviceTier"] = serviceTier
        }

        let requestID = try sendRequest(method: "thread/start", params: params)
        while Date() < deadline {
            let message = try receiveJSON(deadline: deadline)
            if let id = message["id"] as? Int, id == requestID {
                try throwIfError(message)
                guard
                    let result = message["result"] as? [String: Any],
                    let thread = result["thread"] as? [String: Any],
                    let threadID = thread["id"] as? String
                else {
                    throw CodexTranslationError.failed("Codex app-server の thread/start 応答を読めませんでした")
                }
                return threadID
            }
            if message["method"] as? String == "error" {
                throw CodexTranslationError.failed(describeError(message))
            }
        }
        throw CodexTranslationError.timedOut
    }

    private func unsubscribe(threadID: String) throws {
        _ = try sendRequest(method: "thread/unsubscribe", params: ["threadId": threadID])
    }

    private func connectAndInitialize(config: CodexTranslationConfig, deadline: Date) throws {
        let url = URL(string: "ws://127.0.0.1:\(config.effectiveAppServerPort)")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.webSocket = task
        task.resume()

        let requestID = try sendRequest(method: "initialize", params: [
            "clientInfo": [
                "name": "open-wispr",
                "title": "OpenWispr",
                "version": OpenWispr.version,
            ],
            "capabilities": [
                "experimentalApi": true,
                "optOutNotificationMethods": [
                    "mcpServer/startupStatus/updated",
                    "thread/tokenUsage/updated",
                    "account/rateLimits/updated",
                ],
            ],
        ])

        while Date() < deadline {
            let message = try receiveJSON(deadline: deadline)
            if let id = message["id"] as? Int, id == requestID {
                try throwIfError(message)
                return
            }
        }
        throw CodexTranslationError.timedOut
    }

    private func startAppServer(config: CodexTranslationConfig) throws {
        let codexHome = try prepareCodexHome(config: config)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "CODEX_HOME=\(codexHome)",
            config.effectiveCommand,
            "app-server",
            "--listen",
            "ws://127.0.0.1:\(config.effectiveAppServerPort)",
        ]
        if let null = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = null
            process.standardError = null
        }
        try process.run()
        self.process = process
    }

    private func prepareCodexHome(config: CodexTranslationConfig) throws -> String {
        if let codexHome = config.codexHome, !codexHome.isEmpty {
            return NSString(string: codexHome).expandingTildeInPath
        }

        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/open-wispr/codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configURL = directory.appendingPathComponent("config.toml")
        let configText = """
        model = \(tomlString(config.effectiveModel))
        model_reasoning_effort = \(tomlString(config.effectiveReasoningEffort))
        approval_policy = "never"
        sandbox_mode = "read-only"
        web_search = "disabled"

        [shell_environment_policy]
        inherit = "none"
        """
        try configText.write(to: configURL, atomically: true, encoding: .utf8)

        let defaultAuth = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        let authURL = directory.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: defaultAuth.path) {
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: authURL.path),
               destination != defaultAuth.path {
                try? FileManager.default.removeItem(at: authURL)
            }
            if !FileManager.default.fileExists(atPath: authURL.path),
               (try? FileManager.default.destinationOfSymbolicLink(atPath: authURL.path)) == nil {
                try FileManager.default.createSymbolicLink(at: authURL, withDestinationURL: defaultAuth)
            }
        }

        return directory.path
    }

    private func sendRequest(method: String, params: Any?) throws -> Int {
        let requestID = nextRequestID
        nextRequestID += 1
        var payload: [String: Any] = [
            "id": requestID,
            "method": method,
        ]
        if let params {
            payload["params"] = params
        }
        try sendJSON(payload)
        return requestID
    }

    private func sendJSON(_ payload: [String: Any]) throws {
        guard let webSocket else {
            throw CodexTranslationError.failed("Codex app-server に接続していません")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodexTranslationError.failed("Codex app-server 送信JSONを作れませんでした")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?
        webSocket.send(.string(string)) { error in
            sendError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw CodexTranslationError.timedOut
        }
        if let sendError { throw sendError }
    }

    private func receiveJSON(deadline: Date) throws -> [String: Any] {
        guard let webSocket else {
            throw CodexTranslationError.failed("Codex app-server に接続していません")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var received: Result<URLSessionWebSocketTask.Message, Error>?
        webSocket.receive { result in
            received = result
            semaphore.signal()
        }

        let remaining = max(0.01, deadline.timeIntervalSinceNow)
        guard semaphore.wait(timeout: .now() + remaining) == .success else {
            throw CodexTranslationError.timedOut
        }

        switch received {
        case .success(.string(let string)):
            return try parseJSON(string)
        case .success(.data(let data)):
            guard let string = String(data: data, encoding: .utf8) else {
                throw CodexTranslationError.failed("Codex app-server のバイナリ応答を読めませんでした")
            }
            return try parseJSON(string)
        case .failure(let error):
            throw error
        case .none:
            throw CodexTranslationError.failed("Codex app-server の応答がありません")
        @unknown default:
            throw CodexTranslationError.failed("Codex app-server の未知の応答形式です")
        }
    }

    private func parseJSON(_ string: String) throws -> [String: Any] {
        guard
            let data = string.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CodexTranslationError.failed("Codex app-server のJSON応答を読めませんでした")
        }
        return object
    }

    private func throwIfError(_ message: [String: Any]) throws {
        if message["error"] != nil {
            throw CodexTranslationError.failed(describeError(message))
        }
    }

    private func describeError(_ message: [String: Any]) -> String {
        if let error = message["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            return String(describing: error)
        }
        if let params = message["params"] as? [String: Any] {
            if let message = params["message"] as? String { return message }
            if let error = params["error"] as? String { return error }
            return String(describing: params)
        }
        return String(describing: message)
    }

    private func resetConnection(terminateProcess: Bool) {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        if terminateProcess {
            process?.terminate()
            process = nil
        }
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
