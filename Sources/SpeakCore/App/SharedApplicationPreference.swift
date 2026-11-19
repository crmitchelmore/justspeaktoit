import Foundation

/// An Apple app whose native `AppSettings` store projects a shared preference.
public enum ApplePreferencePlatform: String, CaseIterable, Sendable {
    case macOS
    case iOS
}

/// One persisted preference that both Apple `AppSettings` stores keep.
///
/// It owns the metadata only: each platform's storage key, its default and the
/// value domain that validates a stored value. The native `ObservableObject`
/// stores, their side effects, migrations and any platform-only filtering stay
/// in the apps. A platform default or reader that differs is deliberate and is
/// written here, next to the other platform's, rather than in two files.
public struct SharedApplicationPreference<Value: Sendable>: Sendable {
    /// How one platform persists and reads the preference.
    public struct Projection: Sendable {
        public let key: String
        public let defaultValue: Value
        private let read: @Sendable (UserDefaults, String) -> Value?

        public init(key: String, defaultValue: Value, read: @escaping @Sendable (UserDefaults, String) -> Value?) {
            self.key = key
            self.defaultValue = defaultValue
            self.read = read
        }

        /// The stored value inside this preference's domain, or the default.
        public func value(in defaults: UserDefaults) -> Value {
            read(defaults, key) ?? defaultValue
        }
    }

    public let macOS: Projection
    public let iOS: Projection

    public init(macOS: Projection, iOS: Projection) {
        self.macOS = macOS
        self.iOS = iOS
    }

    /// Both platforms store the value under one key, with one default and reader.
    public init(
        key: ApplicationPreferenceKey,
        defaultValue: Value,
        read: @escaping @Sendable (UserDefaults, String) -> Value?
    ) {
        let projection = Projection(key: key.rawValue, defaultValue: defaultValue, read: read)
        self.init(macOS: projection, iOS: projection)
    }

    public func projection(on platform: ApplePreferencePlatform) -> Projection {
        switch platform {
        case .macOS: return macOS
        case .iOS: return iOS
        }
    }
}

/// Value domains the shared preferences are read through.
public enum SharedPreferenceReader {
    /// A stored `Bool` only; any other stored type falls back to the default.
    @Sendable public static func strictBool(_ defaults: UserDefaults, _ key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    /// `UserDefaults.bool(forKey:)` coercion of any stored value; missing reads the default.
    @Sendable public static func coercedBool(_ defaults: UserDefaults, _ key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    @Sendable public static func string(_ defaults: UserDefaults, _ key: String) -> String? {
        defaults.string(forKey: key)
    }

    /// A stored raw value that names a case; anything else falls back to the default.
    public static func choice<Choice: RawRepresentable & Sendable>(
        _ type: Choice.Type
    ) -> @Sendable (UserDefaults, String) -> Choice? where Choice.RawValue == String {
        { defaults, key in defaults.string(forKey: key).flatMap(Choice.init(rawValue:)) }
    }

    /// A stored string passed through a catalogue normaliser, which owns the default.
    public static func normalized(
        _ normalize: @escaping @Sendable (String?) -> String
    ) -> @Sendable (UserDefaults, String) -> String? {
        { defaults, key in normalize(defaults.string(forKey: key)) }
    }
}

/// The canonical metadata for preferences macOS and iOS both persist.
///
/// `transcriptionMode` and `rememberedRemoteTranscriptionMode` share key names
/// too, but each app stores its own mode enumeration under them, so they are not
/// listed here: a shared definition would have to pretend the domains match.
public enum SharedApplicationPreferences {
    /// The live (streaming) transcription model. The two apps have always used
    /// different keys, and iOS starts from Apple Speech before its own
    /// selectable-model fallback; both normalise through the shared catalogue.
    public static let liveTranscriptionModel = SharedApplicationPreference<String>(
        macOS: .init(
            key: ApplicationPreferenceKey.liveTranscriptionModel.rawValue,
            defaultValue: ModelCatalog.normalizedLiveTranscriptionModel(nil),
            read: SharedPreferenceReader.normalized { ModelCatalog.normalizedLiveTranscriptionModel($0) }
        ),
        iOS: .init(
            key: "selectedModel",
            defaultValue: ModelCatalog.normalizedLiveTranscriptionModel(AppleLocalModels.preferredSpeechModelID),
            read: SharedPreferenceReader.normalized {
                ModelCatalog.normalizedLiveTranscriptionModel($0 ?? AppleLocalModels.preferredSpeechModelID)
            }
        )
    )

    public static let batchTranscriptionModel = SharedApplicationPreference<String>(
        key: .batchTranscriptionModel,
        defaultValue: ModelCatalog.normalizedBatchTranscriptionModel(nil),
        read: SharedPreferenceReader.normalized { ModelCatalog.normalizedBatchTranscriptionModel($0) }
    )

    /// iOS additionally narrows the normalised value to the models it can run.
    public static let postProcessingModel = SharedApplicationPreference<String>(
        key: .postProcessingModel,
        defaultValue: ModelCatalog.normalizedPostProcessingModel(nil),
        read: SharedPreferenceReader.normalized { ModelCatalog.normalizedPostProcessingModel($0) }
    )

    public static let preferredLocale = SharedApplicationPreference<String>(
        key: .preferredLocale,
        defaultValue: TranscriptionLanguageCatalog.normalizedIdentifier(nil),
        read: SharedPreferenceReader.normalized { TranscriptionLanguageCatalog.normalizedIdentifier($0) }
    )

    /// macOS also mirrors this list into `assemblyAIKeyterms`; iOS does not.
    public static let transcriptionKeywords = SharedApplicationPreference<String>(
        key: .transcriptionKeywords,
        defaultValue: "",
        read: SharedPreferenceReader.string
    )

    public static let visualDensity = SharedApplicationPreference<AppVisualDensity>(
        key: .visualDensity,
        defaultValue: .normal,
        read: SharedPreferenceReader.choice(AppVisualDensity.self)
    )

    /// Cleanup has always defaulted on for the Mac and off for iPhone; sharing
    /// the key name does not adopt the other platform's default.
    public static let postProcessingEnabled = SharedApplicationPreference<Bool>(
        macOS: .init(
            key: ApplicationPreferenceKey.postProcessingEnabled.rawValue,
            defaultValue: true,
            read: SharedPreferenceReader.strictBool
        ),
        iOS: .init(
            key: ApplicationPreferenceKey.postProcessingEnabled.rawValue,
            defaultValue: false,
            read: SharedPreferenceReader.coercedBool
        )
    )

    public static let handsFreeDictationEnabled = SharedApplicationPreference<Bool>(
        macOS: .init(
            key: ApplicationPreferenceKey.handsFreeDictationEnabled.rawValue,
            defaultValue: false,
            read: SharedPreferenceReader.strictBool
        ),
        iOS: .init(
            key: ApplicationPreferenceKey.handsFreeDictationEnabled.rawValue,
            defaultValue: false,
            read: SharedPreferenceReader.coercedBool
        )
    )

    public static let keepAudioOnCancel = SharedApplicationPreference<Bool>(
        key: .keepAudioOnCancel,
        defaultValue: SpeechDefaults.keepAudioOnCancel,
        read: SharedPreferenceReader.strictBool
    )

    /// Device-local metadata discovery; never part of automatic transfer.
    public static let cleanupModelDiscoveryEnabled = SharedApplicationPreference<Bool>(
        key: .cleanupModelDiscoveryEnabled,
        defaultValue: false,
        read: SharedPreferenceReader.coercedBool
    )

    /// Every shared preference's key on `platform`, for coverage and pinning tests.
    public static func storageKeys(on platform: ApplePreferencePlatform) -> [String] {
        let strings = [liveTranscriptionModel, batchTranscriptionModel, postProcessingModel, preferredLocale,
                       transcriptionKeywords].map { $0.projection(on: platform).key }
        let flags = [postProcessingEnabled, handsFreeDictationEnabled, keepAudioOnCancel,
                     cleanupModelDiscoveryEnabled].map { $0.projection(on: platform).key }
        return strings + flags + [visualDensity.projection(on: platform).key]
            + [LiveTranscriptionSelection.DefaultsKey.onDeviceModel, LiveTranscriptionSelection.DefaultsKey.remoteModel]
    }
}
