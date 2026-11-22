import Foundation

/// Errors thrown by `VoiceProfileStore` when consent, quality, path safety or storage fails.
public enum VoiceProfileStoreError: LocalizedError, Equatable, Sendable {
    case consentRequired
    case qualityCheckFailed(VoiceProfileQualityReport)
    case validationFailed(VoiceProfileValidationError)
    case profileNotFound(UUID)
    case clipNotFound(UUID)
    case clipLimitReached(Int)
    case cannotRemoveLastClip
    case unsafePath
    case storageFailure(String)

    public var errorDescription: String? {
        switch self {
        case .consentRequired:
            "Permission consent must be accepted before saving a voice profile."
        case .qualityCheckFailed(let report):
            report.rejectionReasons.first ?? "The reference clip did not pass audio quality checks."
        case .validationFailed(let error):
            error.errorDescription
        case .profileNotFound:
            "The selected voice profile could not be found."
        case .clipNotFound:
            "The selected reference clip could not be found."
        case .clipLimitReached(let maximum):
            "Each voice profile can hold at most \(maximum) reference clips."
        case .cannotRemoveLastClip:
            "A voice profile must keep at least one reference clip."
        case .unsafePath:
            "The voice profile storage path is unsafe or invalid."
        case .storageFailure(let message):
            "Voice profile storage failed: \(message)"
        }
    }
}

/// Isolated per-device store for voice profiles, reference WAV clips and local embeddings.
///
/// Profiles live outside History, CloudKit sync, configuration exports, migration archives
/// and the phone-to-desktop receiver (`F46`).
public final class VoiceProfileStore: @unchecked Sendable {
    public static let storageDirectoryName = "PrivateVoiceProfiles"
    public static let metadataFilename = "profiles.json"

    public static func defaultDirectory(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    public struct ClipInput: Sendable {
        public let id: UUID
        public let pcmBuffer: VoiceProfilePCMBuffer
        public let targetFormat: VoiceProfileAudioFormat
        public let transcript: String
        public let source: VoiceProfileClipSource
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            pcmBuffer: VoiceProfilePCMBuffer,
            targetFormat: VoiceProfileAudioFormat = .pcm24k,
            transcript: String,
            source: VoiceProfileClipSource,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.pcmBuffer = pcmBuffer
            self.targetFormat = targetFormat
            self.transcript = transcript
            self.source = source
            self.createdAt = createdAt
        }
    }

    public struct DeletionResult: Equatable, Sendable {
        public let deletedProfileID: UUID
        public let deletedProfileName: String
        public let remoteBindings: [VoiceProfileRemoteBinding]

        public init(
            deletedProfileID: UUID,
            deletedProfileName: String,
            remoteBindings: [VoiceProfileRemoteBinding]
        ) {
            self.deletedProfileID = deletedProfileID
            self.deletedProfileName = deletedProfileName
            self.remoteBindings = remoteBindings
        }
    }

    struct StoreDocument: Codable {
        var schemaVersion = 1
        var profiles: [VoiceProfile] = []
    }

    public let rootDirectory: URL
    let lock = NSLock()
    let fileManager = FileManager.default

    public init(directory: URL) {
        rootDirectory = directory
    }

    public var metadataFileURL: URL {
        rootDirectory.appendingPathComponent(Self.metadataFilename, isDirectory: false)
    }

    public func listProfiles() throws -> [VoiceProfile] {
        try lock.withLock {
            try loadDocument().profiles
        }
    }

    public func profile(id: UUID) throws -> VoiceProfile? {
        try listProfiles().first { $0.id == id }
    }

    public func clipURL(for clip: VoiceProfileClip, in profileID: UUID) throws -> URL {
        guard VoiceProfile.isSafeRelativeFilename(clip.filename) else {
            throw VoiceProfileStoreError.unsafePath
        }
        return try safePath(profileID: profileID, relativePath: clip.filename)
    }

    public func embeddingURL(for binding: VoiceProfileEngineBinding, in profileID: UUID) throws -> URL? {
        guard let relativePath = binding.localEmbeddingPath else { return nil }
        guard VoiceProfile.isSafeRelativePath(relativePath) else {
            throw VoiceProfileStoreError.unsafePath
        }
        return try safePath(profileID: profileID, relativePath: relativePath)
    }

    public func createProfile(
        id: UUID = UUID(),
        name: String,
        language: String,
        clips: [ClipInput],
        consent: ConsentAttestation?,
        qualityGate: VoiceProfileQualityGate = VoiceProfileQualityGate(),
        now: Date = Date()
    ) throws -> VoiceProfile {
        guard let consent, consent.isCurrent else {
            throw VoiceProfileStoreError.consentRequired
        }
        guard (VoiceProfile.minimumClips...VoiceProfile.maximumClips).contains(clips.count) else {
            throw VoiceProfileStoreError.validationFailed(.clipCountOutOfRange(clips.count))
        }

        let prepared = try clips.map { input in
            try prepareClip(input: input, qualityGate: qualityGate)
        }
        let profile = VoiceProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language.trimmingCharacters(in: .whitespacesAndNewlines),
            clips: prepared.map(\.clip),
            consent: consent,
            engineBindings: [:],
            createdAt: now,
            updatedAt: now
        )
        do {
            try profile.validate()
        } catch let error as VoiceProfileValidationError {
            throw VoiceProfileStoreError.validationFailed(error)
        }

        return try lock.withLock {
            try ensurePrivateContainer()
            let folder = try profileDirectory(for: profile.id)
            try createPrivateDirectory(folder)
            do {
                for entry in prepared {
                    let clipFile = folder.appendingPathComponent(entry.clip.filename, isDirectory: false)
                    try writePrivateFile(entry.wavData, to: clipFile)
                }
                var document = try loadDocument()
                document.profiles.append(profile)
                try saveDocument(document)
                return profile
            } catch {
                try? fileManager.removeItem(at: folder)
                throw error
            }
        }
    }

    public func renameProfile(
        id: UUID,
        name: String,
        language: String? = nil,
        now: Date = Date()
    ) throws -> VoiceProfile {
        try updateProfile(id: id, now: now) { profile in
            profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let language {
                profile.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    public func updateClipTranscript(
        profileID: UUID,
        clipID: UUID,
        transcript: String,
        now: Date = Date()
    ) throws -> VoiceProfile {
        try updateProfile(id: profileID, now: now) { profile in
            guard let index = profile.clips.firstIndex(where: { $0.id == clipID }) else {
                throw VoiceProfileStoreError.clipNotFound(clipID)
            }
            profile.clips[index].transcript = transcript
        }
    }

    public func addClip(
        _ input: ClipInput,
        to profileID: UUID,
        qualityGate: VoiceProfileQualityGate = VoiceProfileQualityGate(),
        now: Date = Date()
    ) throws -> VoiceProfile {
        let prepared = try prepareClip(input: input, qualityGate: qualityGate)
        return try lock.withLock {
            try ensurePrivateContainer()
            var document = try loadDocument()
            guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw VoiceProfileStoreError.profileNotFound(profileID)
            }
            guard document.profiles[index].clips.count < VoiceProfile.maximumClips else {
                throw VoiceProfileStoreError.clipLimitReached(VoiceProfile.maximumClips)
            }
            var updated = document.profiles[index]
            updated.clips.append(prepared.clip)
            updated.updatedAt = now
            do {
                try updated.validate()
            } catch let error as VoiceProfileValidationError {
                throw VoiceProfileStoreError.validationFailed(error)
            }

            let folder = try profileDirectory(for: profileID)
            try createPrivateDirectory(folder)
            let clipFile = folder.appendingPathComponent(prepared.clip.filename, isDirectory: false)
            try writePrivateFile(prepared.wavData, to: clipFile)
            document.profiles[index] = updated
            do {
                try saveDocument(document)
            } catch {
                try? fileManager.removeItem(at: clipFile)
                throw error
            }
            return updated
        }
    }

    public func removeClip(
        clipID: UUID,
        from profileID: UUID,
        now: Date = Date()
    ) throws -> VoiceProfile {
        try lock.withLock {
            var document = try loadDocument()
            guard let profileIndex = document.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw VoiceProfileStoreError.profileNotFound(profileID)
            }
            var updated = document.profiles[profileIndex]
            guard updated.clips.count > VoiceProfile.minimumClips else {
                throw VoiceProfileStoreError.cannotRemoveLastClip
            }
            guard let clipIndex = updated.clips.firstIndex(where: { $0.id == clipID }) else {
                throw VoiceProfileStoreError.clipNotFound(clipID)
            }
            let removedClip = updated.clips.remove(at: clipIndex)
            updated.updatedAt = now
            document.profiles[profileIndex] = updated
            try saveDocument(document)
            if let fileURL = try? safePath(profileID: profileID, relativePath: removedClip.filename) {
                try? fileManager.removeItem(at: fileURL)
            }
            return updated
        }
    }

    public func upsertEngineBinding(
        _ binding: VoiceProfileEngineBinding,
        for profileID: UUID,
        now: Date = Date()
    ) throws -> VoiceProfile {
        try updateProfile(id: profileID, now: now) { profile in
            profile.engineBindings[binding.engineID] = binding
        }
    }

    public func removeEngineBinding(
        engineID: String,
        from profileID: UUID,
        now: Date = Date()
    ) throws -> VoiceProfile {
        var removedEmbedding: URL?
        let updated = try lock.withLock {
            var document = try loadDocument()
            guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw VoiceProfileStoreError.profileNotFound(profileID)
            }
            var profile = document.profiles[index]
            if let oldBinding = profile.engineBindings.removeValue(forKey: engineID),
               let path = oldBinding.localEmbeddingPath {
                removedEmbedding = try? safePath(profileID: profileID, relativePath: path)
            }
            profile.updatedAt = now
            document.profiles[index] = profile
            try saveDocument(document)
            return profile
        }
        if let removedEmbedding {
            try? fileManager.removeItem(at: removedEmbedding)
        }
        return updated
    }

    /// Removes the profile, all clips, all local embeddings and bindings, returning any remote clones.
    public func deleteProfile(id: UUID) throws -> DeletionResult {
        try lock.withLock {
            var document = try loadDocument()
            guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
                throw VoiceProfileStoreError.profileNotFound(id)
            }
            let removed = document.profiles.remove(at: index)
            let remote = removed.remoteBindings
            try ensurePrivateContainer()
            try saveDocument(document)

            let folder = try profileDirectory(for: id)
            if fileManager.fileExists(atPath: folder.path) {
                try fileManager.removeItem(at: folder)
            }
            return DeletionResult(
                deletedProfileID: removed.id,
                deletedProfileName: removed.name,
                remoteBindings: remote
            )
        }
    }
}
