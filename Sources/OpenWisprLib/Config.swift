import Foundation

public struct LanguageOption: Equatable, Sendable {
    public let code: String
    public let name: String
}

public struct Config: Codable {
    public var hotkeys: [HotkeyConfig]
    public var profiles: [DictationProfile]?
    public var modelPath: String?
    public var modelSize: String
    public var language: String
    public var codexTranslation: CodexTranslationConfig?
    public var spokenPunctuation: FlexBool?
    public var maxRecordings: Int?
    public var toggleMode: FlexBool?
    public var audioInputDeviceID: UInt32?

    public var hotkey: HotkeyConfig {
        get { hotkeys[0] }
        set { hotkeys = Config.deduplicateHotkeys([newValue]) }
    }

    public func hotkeySummary() -> String {
        guard profiles?.isEmpty == false else {
            return hotkeys
                .map { KeyCodes.describe(keyCode: $0.keyCode, modifiers: $0.modifiers) }
                .joined(separator: " · ")
        }

        return runtimeProfiles()
            .map { profile in
                let desc = KeyCodes.describe(keyCode: profile.hotkey.keyCode, modifiers: profile.hotkey.modifiers)
                return "\(profile.id):\(desc)"
            }
            .joined(separator: " · ")
    }

    private static func deduplicateHotkeys(_ list: [HotkeyConfig]) -> [HotkeyConfig] {
        var out: [HotkeyConfig] = []
        for h in list where !out.contains(h) {
            out.append(h)
        }
        return out
    }

    private static func deduplicateProfiles(_ list: [DictationProfile]) -> [DictationProfile] {
        var out: [DictationProfile] = []
        for profile in list {
            if !out.contains(where: { $0.hotkey == profile.hotkey }) {
                out.append(profile)
            }
        }
        return out
    }

    public func runtimeProfiles() -> [DictationProfile] {
        if let profiles = profiles, !profiles.isEmpty {
            return profiles
        }

        return hotkeys.enumerated().map { index, hotkey in
            DictationProfile(
                id: index == 0 ? "default" : "hotkey-\(index + 1)",
                hotkey: hotkey,
                modelSize: nil,
                language: nil,
                action: nil,
                targetLanguage: nil,
                translator: nil
            )
        }
    }

    public func effectiveModelSize(for profile: DictationProfile) -> String {
        Config.resolveModelAlias(profile.modelSize ?? modelSize)
    }

    public func effectiveLanguage(for profile: DictationProfile) -> String {
        profile.language ?? language
    }

    private enum CodingKeys: String, CodingKey {
        case hotkey
        case hotkeys
        case profiles
        case modelPath
        case modelSize
        case language
        case codexTranslation
        case spokenPunctuation
        case maxRecordings
        case toggleMode
        case audioInputDeviceID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let profilesList = try c.decodeIfPresent([DictationProfile].self, forKey: .profiles)
        let hotkeysList = try c.decodeIfPresent([HotkeyConfig].self, forKey: .hotkeys)
        let legacyHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey)
        if let list = profilesList, !list.isEmpty {
            self.profiles = Config.deduplicateProfiles(list)
            self.hotkeys = Config.deduplicateHotkeys(self.profiles?.map { $0.hotkey } ?? [])
        } else if let list = hotkeysList, !list.isEmpty {
            self.profiles = nil
            self.hotkeys = Config.deduplicateHotkeys(list)
        } else if let legacy = legacyHotkey {
            self.profiles = nil
            self.hotkeys = [legacy]
        } else {
            self.profiles = nil
            self.hotkeys = [HotkeyConfig(keyCode: 63, modifiers: [])]
        }
        self.modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
        self.modelSize = try c.decode(String.self, forKey: .modelSize)
        self.language = try c.decode(String.self, forKey: .language)
        self.codexTranslation = try c.decodeIfPresent(CodexTranslationConfig.self, forKey: .codexTranslation)
        self.spokenPunctuation = try c.decodeIfPresent(FlexBool.self, forKey: .spokenPunctuation)
        self.maxRecordings = try c.decodeIfPresent(Int.self, forKey: .maxRecordings)
        self.toggleMode = try c.decodeIfPresent(FlexBool.self, forKey: .toggleMode)
        self.audioInputDeviceID = try c.decodeIfPresent(UInt32.self, forKey: .audioInputDeviceID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotkeys, forKey: .hotkeys)
        try c.encode(hotkeys[0], forKey: .hotkey)
        try c.encodeIfPresent(profiles, forKey: .profiles)
        try c.encodeIfPresent(modelPath, forKey: .modelPath)
        try c.encode(modelSize, forKey: .modelSize)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(codexTranslation, forKey: .codexTranslation)
        try c.encodeIfPresent(spokenPunctuation, forKey: .spokenPunctuation)
        try c.encodeIfPresent(maxRecordings, forKey: .maxRecordings)
        try c.encodeIfPresent(toggleMode, forKey: .toggleMode)
        try c.encodeIfPresent(audioInputDeviceID, forKey: .audioInputDeviceID)
    }

    public init(
        hotkeys: [HotkeyConfig],
        profiles: [DictationProfile]? = nil,
        modelPath: String?,
        modelSize: String,
        language: String,
        codexTranslation: CodexTranslationConfig? = nil,
        spokenPunctuation: FlexBool?,
        maxRecordings: Int?,
        toggleMode: FlexBool?,
        audioInputDeviceID: UInt32? = nil
    ) {
        if let profiles = profiles, !profiles.isEmpty {
            self.profiles = Config.deduplicateProfiles(profiles)
            self.hotkeys = Config.deduplicateHotkeys(self.profiles?.map { $0.hotkey } ?? [])
        } else {
            self.profiles = nil
            self.hotkeys = hotkeys.isEmpty
                ? [HotkeyConfig(keyCode: 63, modifiers: [])]
                : Config.deduplicateHotkeys(hotkeys)
        }
        self.modelPath = modelPath
        self.modelSize = modelSize
        self.language = language
        self.codexTranslation = codexTranslation
        self.spokenPunctuation = spokenPunctuation
        self.maxRecordings = maxRecordings
        self.toggleMode = toggleMode
        self.audioInputDeviceID = audioInputDeviceID
    }

    public static let supportedLanguages: [LanguageOption] = [
        LanguageOption(code: "auto", name: "Auto-Detect"),
        LanguageOption(code: "en", name: "English"),
        LanguageOption(code: "zh", name: "Chinese"),
        LanguageOption(code: "de", name: "German"),
        LanguageOption(code: "es", name: "Spanish"),
        LanguageOption(code: "ru", name: "Russian"),
        LanguageOption(code: "ko", name: "Korean"),
        LanguageOption(code: "fr", name: "French"),
        LanguageOption(code: "ja", name: "Japanese"),
        LanguageOption(code: "pt", name: "Portuguese"),
        LanguageOption(code: "tr", name: "Turkish"),
        LanguageOption(code: "pl", name: "Polish"),
        LanguageOption(code: "ca", name: "Catalan"),
        LanguageOption(code: "nl", name: "Dutch"),
        LanguageOption(code: "ar", name: "Arabic"),
        LanguageOption(code: "sv", name: "Swedish"),
        LanguageOption(code: "it", name: "Italian"),
        LanguageOption(code: "id", name: "Indonesian"),
        LanguageOption(code: "hi", name: "Hindi"),
        LanguageOption(code: "fi", name: "Finnish"),
        LanguageOption(code: "vi", name: "Vietnamese"),
        LanguageOption(code: "he", name: "Hebrew"),
        LanguageOption(code: "uk", name: "Ukrainian"),
        LanguageOption(code: "el", name: "Greek"),
        LanguageOption(code: "ms", name: "Malay"),
        LanguageOption(code: "cs", name: "Czech"),
        LanguageOption(code: "ro", name: "Romanian"),
        LanguageOption(code: "da", name: "Danish"),
        LanguageOption(code: "hu", name: "Hungarian"),
        LanguageOption(code: "ta", name: "Tamil"),
        LanguageOption(code: "no", name: "Norwegian"),
        LanguageOption(code: "th", name: "Thai"),
        LanguageOption(code: "ur", name: "Urdu"),
        LanguageOption(code: "hr", name: "Croatian"),
        LanguageOption(code: "bg", name: "Bulgarian"),
        LanguageOption(code: "lt", name: "Lithuanian"),
        LanguageOption(code: "la", name: "Latin"),
        LanguageOption(code: "mi", name: "Maori"),
        LanguageOption(code: "ml", name: "Malayalam"),
        LanguageOption(code: "cy", name: "Welsh"),
        LanguageOption(code: "sk", name: "Slovak"),
        LanguageOption(code: "te", name: "Telugu"),
        LanguageOption(code: "fa", name: "Persian"),
        LanguageOption(code: "lv", name: "Latvian"),
        LanguageOption(code: "bn", name: "Bengali"),
        LanguageOption(code: "sr", name: "Serbian"),
        LanguageOption(code: "az", name: "Azerbaijani"),
        LanguageOption(code: "sl", name: "Slovenian"),
        LanguageOption(code: "kn", name: "Kannada"),
        LanguageOption(code: "et", name: "Estonian"),
        LanguageOption(code: "mk", name: "Macedonian"),
        LanguageOption(code: "br", name: "Breton"),
        LanguageOption(code: "eu", name: "Basque"),
        LanguageOption(code: "is", name: "Icelandic"),
        LanguageOption(code: "hy", name: "Armenian"),
        LanguageOption(code: "ne", name: "Nepali"),
        LanguageOption(code: "mn", name: "Mongolian"),
        LanguageOption(code: "bs", name: "Bosnian"),
        LanguageOption(code: "kk", name: "Kazakh"),
        LanguageOption(code: "sq", name: "Albanian"),
        LanguageOption(code: "sw", name: "Swahili"),
        LanguageOption(code: "gl", name: "Galician"),
        LanguageOption(code: "mr", name: "Marathi"),
        LanguageOption(code: "pa", name: "Punjabi"),
        LanguageOption(code: "si", name: "Sinhala"),
        LanguageOption(code: "km", name: "Khmer"),
        LanguageOption(code: "sn", name: "Shona"),
        LanguageOption(code: "yo", name: "Yoruba"),
        LanguageOption(code: "so", name: "Somali"),
        LanguageOption(code: "af", name: "Afrikaans"),
        LanguageOption(code: "oc", name: "Occitan"),
        LanguageOption(code: "ka", name: "Georgian"),
        LanguageOption(code: "be", name: "Belarusian"),
        LanguageOption(code: "tg", name: "Tajik"),
        LanguageOption(code: "sd", name: "Sindhi"),
        LanguageOption(code: "gu", name: "Gujarati"),
        LanguageOption(code: "am", name: "Amharic"),
        LanguageOption(code: "yi", name: "Yiddish"),
        LanguageOption(code: "lo", name: "Lao"),
        LanguageOption(code: "uz", name: "Uzbek"),
        LanguageOption(code: "fo", name: "Faroese"),
        LanguageOption(code: "ht", name: "Haitian Creole"),
        LanguageOption(code: "ps", name: "Pashto"),
        LanguageOption(code: "tk", name: "Turkmen"),
        LanguageOption(code: "nn", name: "Nynorsk"),
        LanguageOption(code: "mt", name: "Maltese"),
        LanguageOption(code: "sa", name: "Sanskrit"),
        LanguageOption(code: "lb", name: "Luxembourgish"),
        LanguageOption(code: "my", name: "Myanmar"),
        LanguageOption(code: "bo", name: "Tibetan"),
        LanguageOption(code: "tl", name: "Tagalog"),
        LanguageOption(code: "mg", name: "Malagasy"),
        LanguageOption(code: "as", name: "Assamese"),
        LanguageOption(code: "tt", name: "Tatar"),
        LanguageOption(code: "haw", name: "Hawaiian"),
        LanguageOption(code: "ln", name: "Lingala"),
        LanguageOption(code: "ha", name: "Hausa"),
        LanguageOption(code: "ba", name: "Bashkir"),
        LanguageOption(code: "jw", name: "Javanese"),
        LanguageOption(code: "su", name: "Sundanese"),
    ]

    public static let supportedModels: [String] = [
        "tiny.en", "tiny.en-q5_1",
        "tiny",
        "base.en", "base.en-q5_1",
        "base",
        "small.en", "small.en-q5_1",
        "small",
        "medium.en", "medium.en-q5_0",
        "medium",
        "large-v3-turbo", "large-v3-turbo-q8_0", "large-v3-turbo-q5_0",
        "large-v3",
    ]

    public static let modelAliases: [String: String] = [
        "large": "large-v3",
    ]

    public static func resolveModelAlias(_ size: String) -> String {
        return modelAliases[size] ?? size
    }

    public static func isEnglishOnlyModel(_ name: String) -> Bool {
        return name.hasSuffix(".en") || name.contains(".en-")
    }

    public static let defaultMaxRecordings = 0

    public static func effectiveMaxRecordings(_ value: Int?) -> Int {
        let raw = value ?? Config.defaultMaxRecordings
        if raw == 0 { return 0 }
        return min(max(1, raw), 100)
    }

    public static let defaultConfig = Config(
        hotkeys: [HotkeyConfig(keyCode: 63, modifiers: [])],
        profiles: nil,
        modelPath: nil,
        modelSize: "base.en",
        language: "en",
        codexTranslation: nil,
        spokenPunctuation: FlexBool(false),
        maxRecordings: nil,
        toggleMode: FlexBool(false)
    )

    public static var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/open-wispr")
    }

    public static var configFile: URL {
        configDir.appendingPathComponent("config.json")
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: configFile) else {
            let config = Config.defaultConfig
            try? config.save()
            return config
        }

        do {
            var config = try JSONDecoder().decode(Config.self, from: data)
            let resolved = Config.resolveModelAlias(config.modelSize)
            if resolved != config.modelSize {
                config.modelSize = resolved
                try? config.save()
            }
            return config
        } catch {
            fputs("Warning: unable to parse \(configFile.path): \(error.localizedDescription)\n", stderr)
            return Config.defaultConfig
        }
    }

    public static func decode(from data: Data) throws -> Config {
        var config = try JSONDecoder().decode(Config.self, from: data)
        config.modelSize = Config.resolveModelAlias(config.modelSize)
        return config
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        try data.write(to: Config.configFile)
    }
}

public struct FlexBool: Codable, Equatable {
    public let value: Bool

    public init(_ value: Bool) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            value = b
        } else if let s = try? container.decode(String.self) {
            value = ["true", "yes", "1"].contains(s.lowercased())
        } else if let i = try? container.decode(Int.self) {
            value = i != 0
        } else {
            value = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct HotkeyConfig: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: [String]

    public init(keyCode: UInt16, modifiers: [String]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var modifierFlags: UInt64 {
        var flags: UInt64 = 0
        for mod in modifiers {
            switch mod.lowercased() {
            case "cmd", "command": flags |= UInt64(1 << 20)
            case "shift": flags |= UInt64(1 << 17)
            case "ctrl", "control": flags |= UInt64(1 << 18)
            case "opt", "option", "alt": flags |= UInt64(1 << 19)
            case "fn", "function", "globe": flags |= UInt64(1 << 23)
            default: break
            }
        }
        return flags
    }
}

public enum DictationAction: String, Codable {
    case transcribe
    case translate
}

public struct DictationProfile: Codable, Equatable {
    public var id: String
    public var hotkey: HotkeyConfig
    public var modelSize: String?
    public var language: String?
    public var action: String?
    public var targetLanguage: String?
    public var translator: String?

    public init(
        id: String,
        hotkey: HotkeyConfig,
        modelSize: String?,
        language: String?,
        action: String?,
        targetLanguage: String?,
        translator: String?
    ) {
        self.id = id
        self.hotkey = hotkey
        self.modelSize = modelSize.map(Config.resolveModelAlias)
        self.language = language
        self.action = action
        self.targetLanguage = targetLanguage
        self.translator = translator
    }

    public var effectiveAction: DictationAction {
        DictationAction(rawValue: action ?? DictationAction.transcribe.rawValue) ?? .transcribe
    }

    public var usesTranslation: Bool {
        effectiveAction == .translate || targetLanguage != nil
    }
}

public struct CodexTranslationConfig: Codable, Equatable {
    public var command: String?
    public var model: String?
    public var timeoutSeconds: Double?
    public var extraArgs: [String]?

    public init(
        command: String? = nil,
        model: String? = nil,
        timeoutSeconds: Double? = nil,
        extraArgs: [String]? = nil
    ) {
        self.command = command
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.extraArgs = extraArgs
    }

    public var effectiveCommand: String {
        command?.isEmpty == false ? command! : "codex"
    }

    public var effectiveTimeoutSeconds: Double {
        max(5, timeoutSeconds ?? 45)
    }
}
