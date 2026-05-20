import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var hotkeyRouter: ProfileHotkeyManager?
    var recorder: AudioRecorder!
    var transcriber: Transcriber!
    var inserter: TextInserter!
    var config: Config!
    var streamingWorker: StreamingWhisperWorker?
    var isPressed = false
    var isReady = false
    var activeProfile: DictationProfile?
    public var lastTranscription: String?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        recorder = AudioRecorder()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        streamingWorker?.shutdown()
        CodexTranslationService.shutdown()
    }

    private func setup() {
        do {
            try setupInner()
        } catch {
            print("Fatal setup error: \(error.localizedDescription)")
        }
    }

    private func setupInner() throws {
        config = Config.load()
        inserter = TextInserter()
        recorder.preferredDeviceID = config.audioInputDeviceID
        if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
            RecordingStore.deleteAllRecordings()
        }
        transcriber = Transcriber(modelSize: config.modelSize, language: config.language)
        transcriber.spokenPunctuation = config.spokenPunctuation?.value ?? false

        DispatchQueue.main.async {
            self.statusBar.reprocessHandler = { [weak self] url in
                self?.reprocess(audioURL: url)
            }
            self.statusBar.onConfigChange = { [weak self] newConfig in
                self?.applyConfigChange(newConfig)
            }
            self.statusBar.buildMenu()
        }

        if Transcriber.findWhisperBinary() == nil {
            print("Error: whisper-cpp not found. Install it with: brew install whisper-cpp")
            return
        }

        if Permissions.didUpgrade() {
            print("Accessibility: upgrade detected, resetting permissions...")
            Permissions.resetAccessibility()
            Thread.sleep(forTimeInterval: 1)
        }

        if !AXIsProcessTrusted() {
            DispatchQueue.main.async {
                self.statusBar.state = .waitingForPermission
                self.statusBar.buildMenu()
            }
        }

        Permissions.ensureMicrophone()

        if !AXIsProcessTrusted() {
            print("Accessibility: not granted")
            Permissions.promptAccessibility()
            Permissions.openAccessibilitySettings()
            print("Waiting for Accessibility permission...")
            while !AXIsProcessTrusted() {
                Thread.sleep(forTimeInterval: 0.5)
            }
            print("Accessibility: granted")
        } else {
            print("Accessibility: granted")
        }

        try ensureRequiredModelsAvailable(config)
        loadStreamingWorkerIfNeeded(config)

        recorder.prewarm()

        DispatchQueue.main.async { [weak self] in
            self?.startListening()
        }
    }

    private func startListening() {
        hotkeyRouter?.stop()
        let router = ProfileHotkeyManager(
            profiles: config.runtimeProfiles(),
            toggleMode: config.toggleMode?.value ?? false
        )
        router.start(
            onKeyDown: { [weak self] profile in
                self?.handleKeyDown(profile: profile)
            },
            onKeyUp: { [weak self] profile in
                self?.handleKeyUp(profile: profile)
            }
        )
        hotkeyRouter = router

        isReady = true
        statusBar.state = .idle
        statusBar.buildMenu()

        let hotkeyDesc = config.hotkeySummary()
        print("open-wispr v\(OpenWispr.version)")
        print("Hotkey: \(hotkeyDesc)")
        print("Model: \(config.modelSize)")
        print("Ready.")
    }

    private func loadStreamingWorkerIfNeeded(_ config: Config) {
        streamingWorker?.shutdown()
        streamingWorker = nil

        let streamingConfig = config.effectiveStreamingWhisper
        guard streamingConfig.effectiveEnabled else { return }
        guard let profile = config.runtimeProfiles().first(where: { $0.usesStreamingTranscriber }) else { return }

        do {
            let worker = try StreamingWhisperWorker.make(
                modelSize: config.effectiveModelSize(for: profile),
                language: config.effectiveLanguage(for: profile),
                config: streamingConfig
            ) { stage, duration, details in
                Self.logTiming(profile: profile, stage: stage, duration: duration, details: details)
            }
            streamingWorker = worker
        } catch {
            print("Warning: streaming Whisper worker disabled: \(error.localizedDescription)")
        }
    }

    public func reloadConfig() {
        let newConfig = Config.load()
        applyConfigChange(newConfig)
    }

    func applyConfigChange(_ newConfig: Config) {
        guard isReady else { return }
        let wasDownloading: Bool
        if case .downloading = statusBar.state { wasDownloading = true } else { wasDownloading = false }
        let deviceChanged = recorder.preferredDeviceID != newConfig.audioInputDeviceID
        config = newConfig
        recorder.preferredDeviceID = config.audioInputDeviceID
        if deviceChanged {
            recorder.reload()
        }
        transcriber = Transcriber(modelSize: config.modelSize, language: config.language)
        transcriber.spokenPunctuation = config.spokenPunctuation?.value ?? false
        inserter = TextInserter()
        loadStreamingWorkerIfNeeded(config)

        hotkeyRouter?.stop()
        let router = ProfileHotkeyManager(
            profiles: config.runtimeProfiles(),
            toggleMode: config.toggleMode?.value ?? false
        )
        router.start(
            onKeyDown: { [weak self] profile in self?.handleKeyDown(profile: profile) },
            onKeyUp: { [weak self] profile in self?.handleKeyUp(profile: profile) }
        )
        hotkeyRouter = router

        let missingModels = requiredModelSizes(config).filter { !Transcriber.modelExists(modelSize: $0) }
        if !wasDownloading && !missingModels.isEmpty {
            statusBar.state = .downloading
            statusBar.updateDownloadProgress("Downloading \(missingModels[0]) model...")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    for modelSize in missingModels {
                        try ModelDownloader.download(modelSize: modelSize) { percent in
                            DispatchQueue.main.async {
                                let pct = Int(percent)
                                self?.statusBar.updateDownloadProgress("Downloading \(modelSize) model... \(pct)%", percent: percent)
                            }
                        }
                    }
                    DispatchQueue.main.async {
                        self?.statusBar.state = .idle
                        self?.statusBar.updateDownloadProgress(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        print("Error downloading model: \(error.localizedDescription)")
                        self?.statusBar.state = .idle
                        self?.statusBar.updateDownloadProgress(nil)
                    }
                }
            }
        }

        statusBar.buildMenu()

        let hotkeyDesc = config.hotkeySummary()
        print("Config updated: lang=\(config.language) model=\(config.modelSize) hotkey=\(hotkeyDesc)")
    }

    private func handleKeyDown(profile: DictationProfile) {
        guard isReady else { return }

        let isToggle = config.toggleMode?.value ?? false

        if isToggle {
            if isPressed {
                handleRecordingStop()
            } else {
                handleRecordingStart(profile: profile)
            }
        } else {
            guard !isPressed else { return }
            handleRecordingStart(profile: profile)
        }
    }

    private func handleKeyUp(profile _: DictationProfile) {
        let isToggle = config.toggleMode?.value ?? false
        if isToggle { return }

        handleRecordingStop()
    }

    private func handleRecordingStart(profile: DictationProfile) {
        guard !isPressed else { return }
        isPressed = true
        activeProfile = profile
        statusBar.state = .recording
        recorder.pcmHandler = nil
        if profile.usesStreamingTranscriber,
           config.effectiveStreamingWhisper.effectiveEnabled,
           let streamingWorker {
            streamingWorker.startSession()
            recorder.pcmHandler = { [weak streamingWorker] samples in
                streamingWorker?.appendPCM(samples)
            }
        }
        do {
            let outputURL: URL
            if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
                outputURL = RecordingStore.tempRecordingURL()
            } else {
                outputURL = RecordingStore.newRecordingURL()
            }
            try recorder.startRecording(to: outputURL)
        } catch {
            print("Error: \(error.localizedDescription)")
            isPressed = false
            recorder.pcmHandler = nil
            statusBar.state = .idle
        }
    }

    private func handleRecordingStop() {
        guard isPressed else { return }
        isPressed = false
        let stopStartedAt = Date()

        guard let audioURL = recorder.stopRecording() else {
            statusBar.state = .idle
            activeProfile = nil
            return
        }
        let recordedLevels = recorder.lastRecordingLevels
        let profile = activeProfile ?? config.runtimeProfiles()[0]
        activeProfile = nil

        statusBar.state = .transcribing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let pipelineStartedAt = Date()
            let maxRecordings = Config.effectiveMaxRecordings(self.config.maxRecordings)
            defer {
                if maxRecordings == 0 {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }
            do {
                if let recordedLevels,
                   Transcriber.shouldSkipForSilence(levels: recordedLevels) {
                    Self.logTiming(
                        profile: profile,
                        stage: "silence-skip",
                        duration: Date().timeIntervalSince(pipelineStartedAt),
                        details: "rms=\(Self.format(recordedLevels.rms)) active=\(Self.format(recordedLevels.activeDurationSeconds))s duration=\(Self.format(recordedLevels.durationSeconds))s"
                    )
                    DispatchQueue.main.async {
                        self.statusBar.state = .idle
                        self.statusBar.buildMenu()
                    }
                    return
                }

                let runCLITranscription = { () throws -> String in
                    let transcriber = Transcriber(
                        modelSize: self.config.effectiveModelSize(for: profile),
                        language: self.config.effectiveLanguage(for: profile)
                    )
                    transcriber.spokenPunctuation = self.config.spokenPunctuation?.value ?? false
                    let whisperStartedAt = Date()
                    let raw = try transcriber.transcribe(audioURL: audioURL)
                    Self.logTiming(
                        profile: profile,
                        stage: "whisper",
                        duration: Date().timeIntervalSince(whisperStartedAt),
                        details: "chars=\(raw.count)"
                    )
                    return raw
                }

                let raw: String
                let whisperStartedAt = Date()
                if profile.usesStreamingTranscriber,
                   self.config.effectiveStreamingWhisper.effectiveEnabled,
                   let streamingWorker = self.streamingWorker {
                    switch streamingWorker.finishSession(
                        waitSeconds: self.config.effectiveStreamingWhisper.effectiveStopWaitSeconds,
                        staleSeconds: self.config.effectiveStreamingWhisper.effectiveStaleSeconds
                    ) {
                    case .transcript(let text):
                        raw = text
                        Self.logTiming(
                            profile: profile,
                            stage: "streaming-transcript",
                            duration: Date().timeIntervalSince(whisperStartedAt),
                            details: "chars=\(raw.count)"
                        )
                    case .fallback(let reason):
                        Self.logTiming(
                            profile: profile,
                            stage: "streaming-fallback-cli",
                            duration: Date().timeIntervalSince(whisperStartedAt),
                            details: "reason=\(reason)"
                        )
                        guard self.config.effectiveStreamingWhisper.effectiveFallbackToCli else {
                            throw StreamingWhisperWorkerError.transcriptionFailed(reason)
                        }
                        raw = try runCLITranscription()
                    }
                } else {
                    raw = try runCLITranscription()
                }

                let postProcessStartedAt = Date()
                var text = (self.config.spokenPunctuation?.value ?? false) ? TextPostProcessor.process(raw) : raw
                Self.logTiming(
                    profile: profile,
                    stage: "postprocess",
                    duration: Date().timeIntervalSince(postProcessStartedAt),
                    details: "chars=\(text.count)"
                )
                if profile.usesTranslation {
                    guard let targetLanguage = profile.targetLanguage else {
                        throw CodexTranslationError.failed("profile '\(profile.id)' に targetLanguage が必要です")
                    }
                    let translateStartedAt = Date()
                    text = try CodexTranslationService.translate(
                        text: text,
                        sourceLanguage: self.config.effectiveLanguage(for: profile),
                        targetLanguage: targetLanguage,
                        config: self.config.codexTranslation
                    )
                    Self.logTiming(
                        profile: profile,
                        stage: "codex-translate",
                        duration: Date().timeIntervalSince(translateStartedAt),
                        details: "chars=\(text.count)"
                    )
                } else if profile.usesPolish {
                    let polishStartedAt = Date()
                    text = try CodexTranslationService.polish(
                        text: text,
                        language: self.config.effectiveLanguage(for: profile),
                        config: self.config.codexTranslation
                    )
                    Self.logTiming(
                        profile: profile,
                        stage: "codex-polish",
                        duration: Date().timeIntervalSince(polishStartedAt),
                        details: "chars=\(text.count)"
                    )
                }
                if maxRecordings > 0 {
                    let pruneStartedAt = Date()
                    RecordingStore.prune(maxCount: maxRecordings)
                    Self.logTiming(profile: profile, stage: "prune", duration: Date().timeIntervalSince(pruneStartedAt))
                }
                DispatchQueue.main.async {
                    let insertStartedAt = Date()
                    if !text.isEmpty {
                        self.lastTranscription = text
                        self.inserter.insert(text: text)
                    }
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                    Self.logTiming(
                        profile: profile,
                        stage: "insert-ui",
                        duration: Date().timeIntervalSince(insertStartedAt),
                        details: "inserted=\(!text.isEmpty)"
                    )
                    Self.logTiming(
                        profile: profile,
                        stage: "total",
                        duration: Date().timeIntervalSince(stopStartedAt),
                        details: "pipeline=\(Self.format(Date().timeIntervalSince(pipelineStartedAt)))s"
                    )
                }
            } catch {
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    print("Error: \(error.localizedDescription)")
                    self.statusBar.state = .error(error.localizedDescription)
                    self.statusBar.buildMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if case .error = self.statusBar.state {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    }
                }
            }
        }
    }

    private static func logTiming(
        profile: DictationProfile,
        stage: String,
        duration: TimeInterval,
        details: String? = nil
    ) {
        let suffix = details.map { " \($0)" } ?? ""
        TimingLog.write("Timing: profile=\(profile.id) stage=\(stage) duration=\(format(duration))s\(suffix)")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func requiredModelSizes(_ config: Config) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for profile in config.runtimeProfiles() {
            let modelSize = config.effectiveModelSize(for: profile)
            if !seen.contains(modelSize) {
                seen.insert(modelSize)
                result.append(modelSize)
            }
        }
        return result
    }

    private func ensureRequiredModelsAvailable(_ config: Config) throws {
        for modelSize in requiredModelSizes(config) {
            if !Transcriber.modelExists(modelSize: modelSize) {
                DispatchQueue.main.async {
                    self.statusBar.state = .downloading
                    self.statusBar.updateDownloadProgress("Downloading \(modelSize) model...")
                }
                print("Downloading \(modelSize) model...")
                try ModelDownloader.download(modelSize: modelSize) { [weak self] percent in
                    DispatchQueue.main.async {
                        let pct = Int(percent)
                        self?.statusBar.updateDownloadProgress("Downloading \(modelSize) model... \(pct)%", percent: percent)
                    }
                }
                DispatchQueue.main.async {
                    self.statusBar.updateDownloadProgress(nil)
                }
            }

            if let modelPath = Transcriber.findModel(modelSize: modelSize) {
                let modelURL = URL(fileURLWithPath: modelPath)
                if !ModelDownloader.isValidGGMLFile(at: modelURL) {
                    let msg = "Model file is corrupted. Re-download with: open-wispr download-model \(modelSize)"
                    print("Error: \(msg)")
                    DispatchQueue.main.async {
                        self.statusBar.state = .error(msg)
                        self.statusBar.buildMenu()
                    }
                    throw TranscriberError.modelNotFound(modelSize)
                }
            }
        }
    }

    public func reprocess(audioURL: URL) {
        guard case .idle = statusBar.state else { return }

        statusBar.state = .transcribing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let raw = try self.transcriber.transcribe(audioURL: audioURL)
                let text = (self.config.spokenPunctuation?.value ?? false) ? TextPostProcessor.process(raw) : raw
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.statusBar.state = .copiedToClipboard
                        self.statusBar.buildMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    } else {
                        self.statusBar.state = .idle
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("Reprocess error: \(error.localizedDescription)")
                    self.statusBar.state = .idle
                }
            }
        }
    }
}
