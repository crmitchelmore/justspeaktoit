import Foundation
import SpeakCore

@MainActor
extension MigrationStore {
    /// Saved TTS audio and recordings whose history was deleted remain user data.
    /// Include regular audio files in the user-selected recording folder too.
    func recordingItems() throws -> [HistoryItem] {
        var items = history.allItems.filter { $0.audioFileURL != nil }
        let knownPaths = Set(items.compactMap { $0.audioFileURL?.standardizedFileURL.path })
        var knownIDs = Set(items.map(\.id))
        let folder = defaults.string(forKey: "recordingsDirectory").map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("Recordings")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return items
        }
        let urls = try FileManager.default.contentsOfDirectory(at: folder,
                                                               includingPropertiesForKeys: [
                                                                   .isRegularFileKey,
                                                                   .isSymbolicLinkKey,
                                                                   .creationDateKey
                                                               ],
                                                               options: [.skipsHiddenFiles])
        let extensions: Set<String> = ["wav", "m4a", "mp3", "flac", "ogg", "aiff", "aif", "aac", "caf"]
        for url in urls
            where extensions.contains(url.pathExtension.lowercased()) && !knownPaths
            .contains(url.standardizedFileURL.path) {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .creationDateKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }
            let identifier = MigrationCoding.variantID(
                id: "standalone-recording",
                revision: url.lastPathComponent
            )
            guard let id = UUID(uuidString: identifier), knownIDs.insert(id).inserted else {
                continue
            }
            let date = values.creationDate ?? .distantPast
            items.append(standaloneRecording(id: id, date: date, url: url))
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }
    var recordingFolder: URL {
        defaults.string(forKey: "recordingsDirectory").map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("Recordings")
    }

    /// Run only after a successful import with its recovery backup already saved.
    func removeReplacedRecordings(previous: MigrationSnapshot, originalFolder: URL) -> [String] {
        let retained = Set(history.allItems.compactMap { $0.audioFileURL?.standardizedFileURL })
        let folders = Set([support.appendingPathComponent("Recordings"),
                           support.appendingPathComponent("ImportedRecordings")]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL })
        let historyIDs = Set(previous.records[.history, default: []].map(\.id))
        let knownFiles = Set(previous.records[.recordings, default: []].filter { historyIDs.contains($0.id) }
            .compactMap { $0.file.flatMap { previous.files[$0]?.standardizedFileURL } })
        var notices: [String] = []
        for url in Set(previous.files.values) where !retained.contains(url.standardizedFileURL) {
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard folders.contains(parent) || (parent == originalFolder.resolvingSymlinksInPath().standardizedFileURL
                && knownFiles.contains(url.standardizedFileURL)) else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try FileManager.default.removeItem(at: url)
            } catch {
                notices.append("Could not remove replaced recording: \(url.lastPathComponent).")
            }
        }
        return notices
    }

    private func standaloneRecording(id: UUID, date: Date, url: URL) -> HistoryItem {
        HistoryItem(id: id, createdAt: date, updatedAt: date, modelsUsed: [],
                    rawTranscription: nil, postProcessedTranscription: nil,
                    recordingDuration: 0, cost: nil,
                    audioFileURL: url, networkExchanges: [], events: [],
                    phaseTimestamps: .init(
                        recordingStarted: nil,
                        recordingEnded: nil,
                        transcriptionStarted: nil,
                        transcriptionEnded: nil,
                        postProcessingStarted: nil,
                        postProcessingEnded: nil,
                        outputDelivered: nil
                    ),
                    trigger: .init(gesture: .uiButton,
                                   hotKeyDescription: url.lastPathComponent,
                                   outputMethod: .none,
                                   destinationApplication: nil), personalCorrections: nil,
                    errors: [
                    ],
                    source: .importedFile)
    }

}

extension HistoryItem {
    /// Preserve local diagnostics when only the recording changes; exports remain redacted.
    func replacingMigrationAudio(_ url: URL?) throws -> HistoryItem {
        if audioFileURL == url { return self }
        var object = try MigrationCoding.value(self).value as? [String: Any] ?? [:]
        object["audioFileURL"] = url?.absoluteString
        return try MigrationCoding.decode(HistoryItem.self, AnyCodable(object))
    }
}
