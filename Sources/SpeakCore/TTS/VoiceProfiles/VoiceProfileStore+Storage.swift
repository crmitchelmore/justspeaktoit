import Foundation

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
