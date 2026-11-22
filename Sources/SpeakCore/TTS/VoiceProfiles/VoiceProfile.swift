import Foundation

/// Canonical mono WAV storage formats supported for reference voice profile clips.
public enum VoiceProfileAudioFormat: Int, Codable, Hashable, Sendable, CaseIterable {
    case pcm16k = 16_000
    case pcm24k = 24_000

    public var sampleRate: Int { rawValue }
    public var channels: Int { 1 }
    public var bitsPerSample: Int { 16 }

    public var displayName: String {
        switch self {
        case .pcm16k: "16 kHz Mono PCM WAV"
        case .pcm24k: "24 kHz Mono PCM WAV"
        }
    }
}

/// Where a reference voice clip came from.
public enum VoiceProfileClipSource: String, Codable, Hashable, Sendable, CaseIterable {
    case recorded
    case history
    case imported

    public var displayName: String {
        switch self {
        case .recorded: "Recorded"
        case .history: "From History"
        case .imported: "Imported File"
        }
    }
}

/// Recorded speaker/owner consent required before saving any voice profile.
public struct ConsentAttestation: Codable, Equatable, Hashable, Sendable {
    public static let currentVersion = "v1"
    public static let requiredText =
        "This is my voice, or I have the speaker's permission to copy it. I'll use it only for my own read aloud."

    public let version: String
    public let acceptedAt: Date

    public init(version: String = ConsentAttestation.currentVersion, acceptedAt: Date = Date()) {
        self.version = version
        self.acceptedAt = acceptedAt
    }

    public var isCurrent: Bool {
        version == Self.currentVersion && acceptedAt.timeIntervalSince1970.isFinite
    }
}

/// One validated reference audio sample belonging to a `VoiceProfile`.
public struct VoiceProfileClip: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let filename: String
    public let sampleRate: Int
    public let durationSeconds: Double
    public var transcript: String
    public let source: VoiceProfileClipSource
    public let createdAt: Date
    public let qualityReport: VoiceProfileQualityReport?

    public init(
        id: UUID = UUID(),
        filename: String,
        sampleRate: Int,
        durationSeconds: Double,
        transcript: String,
        source: VoiceProfileClipSource,
        createdAt: Date = Date(),
        qualityReport: VoiceProfileQualityReport? = nil
    ) {
        self.id = id
        self.filename = filename
        self.sampleRate = sampleRate
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.source = source
        self.createdAt = createdAt
        self.qualityReport = qualityReport
    }
}

/// Binding between a `VoiceProfile` and an execution engine (local embedding or remote clone).
public struct VoiceProfileEngineBinding: Codable, Equatable, Hashable, Sendable {
    public enum Target: Codable, Equatable, Hashable, Sendable {
        case localEmbedding(relativePath: String)
        case remoteVoice(voiceID: String, providerDisplayName: String?)
    }

    public let engineID: String
    public let engineDisplayName: String
    public let target: Target
    public let createdAt: Date

    public init(
        engineID: String,
        engineDisplayName: String,
        target: Target,
        createdAt: Date = Date()
    ) {
        self.engineID = engineID
        self.engineDisplayName = engineDisplayName
        self.target = target
        self.createdAt = createdAt
    }

    public var isRemote: Bool {
        if case .remoteVoice = target { return true }
        return false
    }

    public var localEmbeddingPath: String? {
        if case .localEmbedding(let path) = target { return path }
        return nil
    }

    public var remoteVoiceID: String? {
        if case .remoteVoice(let voiceID, _) = target { return voiceID }
        return nil
    }

    public func playableVoiceID(for profileID: UUID) -> String {
        switch target {
        case .remoteVoice(let voiceID, _):
            return voiceID.contains("/") ? voiceID : "\(engineID)/\(voiceID)"
        case .localEmbedding:
            return "\(engineID)/\(profileID.uuidString.lowercased())"
        }
    }
}

/// Remote clone reference returned on profile deletion so callers can offer remote deletion (#1824).
public struct VoiceProfileRemoteBinding: Equatable, Hashable, Sendable {
    public let profileID: UUID
    public let profileName: String
    public let engineID: String
    public let remoteVoiceID: String
    public let providerDisplayName: String

    public init(
        profileID: UUID,
        profileName: String,
        engineID: String,
        remoteVoiceID: String,
        providerDisplayName: String
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.engineID = engineID
        self.remoteVoiceID = remoteVoiceID
        self.providerDisplayName = providerDisplayName
    }
}

/// Validation errors enforced before persisting a `VoiceProfile`.
public enum VoiceProfileValidationError: LocalizedError, Equatable, Sendable {
    case emptyName
    case nameTooLong
    case emptyLanguage
    case clipCountOutOfRange(Int)
    case invalidClipFilename(String)
    case unsupportedSampleRate(Int)
    case clipDurationOutOfRange(Double)
    case missingConsent
    case invalidEngineBinding(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a name for this voice profile."
        case .nameTooLong:
            "Voice profile names must be 120 characters or fewer."
        case .emptyLanguage:
            "Choose a language for this voice profile."
        case .clipCountOutOfRange(let count):
            "A voice profile requires between \(VoiceProfile.minimumClips) and "
                + "\(VoiceProfile.maximumClips) reference clips (found \(count))."
        case .invalidClipFilename(let name):
            "The reference clip filename \"\(name)\" is invalid."
        case .unsupportedSampleRate(let rate):
            "Reference clips must use 16 kHz or 24 kHz mono WAV audio (found \(rate) Hz)."
        case .clipDurationOutOfRange(let seconds):
            String(
                format: "Each reference clip must be between %.0f and %.0f seconds long (got %.1f s).",
                VoiceProfile.minimumClipDuration,
                VoiceProfile.maximumClipDuration,
                seconds
            )
        case .missingConsent:
            "You must confirm permission to use this voice before saving."
        case .invalidEngineBinding(let engineID):
            "The engine binding for \"\(engineID)\" is invalid."
        }
    }
}

/// A consented reference voice stored privately on this device.
public struct VoiceProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public static let minimumClips = 1
    public static let maximumClips = 3
    public static let minimumClipDuration: Double = 5.0
    public static let maximumClipDuration: Double = 30.0
    public static let supportedSampleRates: Set<Int> = [16_000, 24_000]
    public static let maximumNameLength = 120

    public let id: UUID
    public var name: String
    public var language: String
    public var clips: [VoiceProfileClip]
    public var consent: ConsentAttestation
    public var engineBindings: [String: VoiceProfileEngineBinding]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        language: String,
        clips: [VoiceProfileClip],
        consent: ConsentAttestation,
        engineBindings: [String: VoiceProfileEngineBinding] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.clips = clips
        self.consent = consent
        self.engineBindings = engineBindings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Every remote provider voice bound to this profile, sorted deterministically by engine ID.
    public var remoteBindings: [VoiceProfileRemoteBinding] {
        engineBindings.keys.sorted().compactMap { key in
            guard let binding = engineBindings[key],
                  case .remoteVoice(let voiceID, let providerName) = binding.target else {
                return nil
            }
            return VoiceProfileRemoteBinding(
                profileID: id,
                profileName: name,
                engineID: binding.engineID,
                remoteVoiceID: voiceID,
                providerDisplayName: providerName ?? binding.engineDisplayName
            )
        }
    }

    public func validate() throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw VoiceProfileValidationError.emptyName }
        guard trimmedName.count <= Self.maximumNameLength else { throw VoiceProfileValidationError.nameTooLong }
        let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLanguage.isEmpty else { throw VoiceProfileValidationError.emptyLanguage }
        try validateClips()
        guard consent.isCurrent else { throw VoiceProfileValidationError.missingConsent }
        try validateEngineBindings()
    }

    private func validateClips() throws {
        guard (Self.minimumClips...Self.maximumClips).contains(clips.count) else {
            throw VoiceProfileValidationError.clipCountOutOfRange(clips.count)
        }
        for clip in clips {
            guard Self.isSafeRelativeFilename(clip.filename) else {
                throw VoiceProfileValidationError.invalidClipFilename(clip.filename)
            }
            guard Self.supportedSampleRates.contains(clip.sampleRate) else {
                throw VoiceProfileValidationError.unsupportedSampleRate(clip.sampleRate)
            }
            guard clip.durationSeconds.isFinite,
                  (Self.minimumClipDuration...Self.maximumClipDuration).contains(clip.durationSeconds) else {
                throw VoiceProfileValidationError.clipDurationOutOfRange(clip.durationSeconds)
            }
        }
    }

    private func validateEngineBindings() throws {
        for (key, binding) in engineBindings {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  key == binding.engineID else {
                throw VoiceProfileValidationError.invalidEngineBinding(key)
            }
            try Self.validateBindingTarget(binding.target, engineID: key)
        }
    }

    private static func validateBindingTarget(
        _ target: VoiceProfileEngineBinding.Target,
        engineID: String
    ) throws {
        switch target {
        case .localEmbedding(let path):
            guard isSafeRelativePath(path) else {
                throw VoiceProfileValidationError.invalidEngineBinding(engineID)
            }
        case .remoteVoice(let voiceID, _):
            guard !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceProfileValidationError.invalidEngineBinding(engineID)
            }
        }
    }

    public static func isSafeRelativeFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains("\\")
            && !filename.contains(":")
            && !filename.utf8.contains(0)
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains(":"),
              !path.utf8.contains(0) else {
            return false
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
