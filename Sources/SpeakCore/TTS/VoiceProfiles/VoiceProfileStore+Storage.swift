import Foundation

struct VoiceProfileStorePendingRemoteBinding: Codable, Equatable {
    let engineID: String
    let remoteVoiceID: String
    let providerDisplayName: String
}

struct VoiceProfileStorePendingDeletion: Codable, Equatable {
    let profileID: UUID
    let profileName: String
    let remoteBindings: [VoiceProfileStorePendingRemoteBinding]
}

struct VoiceProfileStoreDocument: Codable {
    var schemaVersion = 1
    var profiles: [VoiceProfile] = []
    var pendingDeletions: [VoiceProfileStorePendingDeletion] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profiles
        case pendingDeletions
    }

    init(
        schemaVersion: Int = 1,
        profiles: [VoiceProfile] = [],
        pendingDeletions: [VoiceProfileStorePendingDeletion] = []
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.pendingDeletions = pendingDeletions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        profiles = try container.decodeIfPresent([VoiceProfile].self, forKey: .profiles) ?? []
        pendingDeletions =
            try container.decodeIfPresent([VoiceProfileStorePendingDeletion].self, forKey: .pendingDeletions) ?? []
    }
}

extension VoiceProfileStore {
    func prepareClip(
        input: ClipInput,
        qualityGate: VoiceProfileQualityGate
    ) throws -> (clip: VoiceProfileClip, wavData: Data) {
        let normalized = VoiceProfileWAVCodec.resample(input.pcmBuffer, to: input.targetFormat)
        let report = qualityGate.evaluate(normalized)
        guard report.passed else {
            throw VoiceProfileStoreError.qualityCheckFailed(report)
        }
        let wavData = try VoiceProfileWAVCodec.encodeWAV(normalized, format: input.targetFormat)
        let clip = VoiceProfileClip(
            id: input.id,
            filename: "clip-\(input.id.uuidString.lowercased()).wav",
            sampleRate: normalized.sampleRate,
            durationSeconds: normalized.durationSeconds,
            transcript: input.transcript,
            source: input.source,
            createdAt: input.createdAt,
            qualityReport: report
        )
        return (clip, wavData)
    }

    func updateProfile(
        id: UUID,
        now: Date,
        mutate: (inout VoiceProfile) throws -> Void
    ) throws -> VoiceProfile {
        try lock.withLock {
            try ensurePrivateContainer()
            var document = try loadDocument()
            guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
                throw VoiceProfileStoreError.profileNotFound(id)
            }
            var updated = document.profiles[index]
            try mutate(&updated)
            updated.updatedAt = now
            do {
                try updated.validate()
            } catch let error as VoiceProfileValidationError {
                throw VoiceProfileStoreError.validationFailed(error)
            }
            document.profiles[index] = updated
            let persisted = try saveDocument(document)
            return persisted.profiles[index]
        }
    }

    func loadDocument() throws -> StoreDocument {
        let url = metadataFileURL
        guard fileManager.fileExists(atPath: url.path) else {
            return StoreDocument()
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VoiceProfileStoreError.unsafePath
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoreDocument.self, from: data)
    }

    func preparePendingDeletion(
        id: UUID,
        in document: inout StoreDocument
    ) throws -> PendingDeletion {
        if let existing = document.pendingDeletions.first(where: { $0.profileID == id }) {
            return existing
        }
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
            throw VoiceProfileStoreError.profileNotFound(id)
        }
        let removed = document.profiles.remove(at: index)
        let pending = PendingDeletion(
            profileID: removed.id,
            profileName: removed.name,
            remoteBindings: removed.remoteBindings.map {
                PendingRemoteBinding(
                    engineID: $0.engineID,
                    remoteVoiceID: $0.remoteVoiceID,
                    providerDisplayName: $0.providerDisplayName
                )
            }
        )
        document.pendingDeletions.append(pending)
        document = try saveDocument(document)
        return pending
    }

    func finalizePendingDeletion(
        _ pending: PendingDeletion,
        in document: inout StoreDocument
    ) throws -> DeletionResult {
        document.pendingDeletions.removeAll { $0.profileID == pending.profileID }
        try saveDocument(document)
        let remote = pending.remoteBindings.map {
            VoiceProfileRemoteBinding(
                profileID: pending.profileID,
                profileName: pending.profileName,
                engineID: $0.engineID,
                remoteVoiceID: $0.remoteVoiceID,
                providerDisplayName: $0.providerDisplayName
            )
        }
        return DeletionResult(
            deletedProfileID: pending.profileID,
            deletedProfileName: pending.profileName,
            remoteBindings: remote
        )
    }

    @discardableResult
    func saveDocument(_ document: StoreDocument) throws -> StoreDocument {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try writePrivateFile(data, to: metadataFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoreDocument.self, from: data)
    }

    func profileDirectory(for profileID: UUID) throws -> URL {
        let candidate = rootDirectory.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        let rootComponents = rootDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidateComponents = candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard candidateComponents.starts(with: rootComponents) else {
            throw VoiceProfileStoreError.unsafePath
        }
        return candidate
    }

    func safePath(profileID: UUID, relativePath: String) throws -> URL {
        let folder = try profileDirectory(for: profileID)
        let folderResolved = folder.resolvingSymlinksInPath().standardizedFileURL
        var target = folder
        for segment in relativePath.split(separator: "/") {
            target.appendPathComponent(String(segment), isDirectory: false)
        }
        let values = try? target.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw VoiceProfileStoreError.unsafePath
        }
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedTarget.pathComponents.starts(with: folderResolved.pathComponents) else {
            throw VoiceProfileStoreError.unsafePath
        }
        return resolvedTarget
    }

    func ensurePrivateContainer() throws {
        try createPrivateDirectory(rootDirectory)
    }

    func createPrivateDirectory(_ directory: URL) throws {
        #if os(Windows)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #else
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
        #if os(macOS) || os(iOS)
        var mutableURL = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
        #endif
    }

    func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        #if !os(Windows)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
        #if os(macOS) || os(iOS)
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
        #endif
    }
}
