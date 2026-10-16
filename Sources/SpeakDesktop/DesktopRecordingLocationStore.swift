import Foundation

extension DesktopRecordingStore {
    /// Explicit local host authorization only; never called when importing settings/profiles/History.
    public func authorizeLocallySelectedAudioRoot(_ root: URL, id: UUID = UUID()) throws -> UUID {
        guard var locations = audioLocations else { throw DesktopRecordingLocationError.unregistered }
        let id = try locations.authorizeLocallySelectedRoot(root, id: id)
        audioLocations = locations
        return id
    }

    /// No default route is enabled. The host must explicitly choose a registered location and qualified factory.
    public func createLocallyAuthorizedCapture(
        at locationID: UUID, recordingID: UUID = UUID(), using factory: DesktopOwnedCaptureFile.Factory = .native
    ) throws -> DesktopRecordingLocations.Capture {
        try requireRetained(recordingID)
        guard try metadataFiles().allSatisfy({ Self.recordID(ofMetadataFile: $0) != recordingID }) else {
            throw DesktopRecordingLocationError.duplicateIdentity
        }
        guard var locations = audioLocations else { throw DesktopRecordingLocationError.unregistered }
        let capture = try locations.createCapture(at: locationID, recordingID: recordingID, using: factory)
        audioLocations = locations
        return capture
    }

    /// Bounded owned read, not a held mutation capability.
    public func readAudio(for record: Record, maximumBytes: UInt64) throws -> Data {
        try requireRetained(record.id)
        if record.localAudio != nil {
            guard let audioLocations else { throw DesktopRecordingLocationError.unregistered }
            return try audioLocations.read(record, maximumBytes: maximumBytes)
        }
        _ = try ownedAudioURL(for: record)
        let snapshot = try DesktopOwnedAppDataFileReader.readStrict(
            record.audioFilename, appDirectory: directory, maximumBytes: maximumBytes
        )
        guard let data = snapshot.data else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }

    func requireLegacyAudioMutation(_ record: Record) throws {
        guard record.localAudio == nil else { throw DesktopRecordingLocationError.mutationUnavailable }
    }
}
