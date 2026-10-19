import Foundation
import SpeakCore
import SpeakDesktop

/// The recordings folder chosen on this computer. Device-local: it never enters
/// portable settings, imports or backups, and an imported Mac `recordingsDirectory`
/// path cannot authorise one.
struct DesktopHostRecordingLocationSelection: Codable, Equatable, Sendable {
    let locationID: UUID
    let path: String
}

/// Host activation of SpeakDesktop's verified recording locations. The History store uses
/// the private namespace, held exclusively, until the controller has fully closed.
package struct DesktopHostRecordingLocationState {
    var persistence: DesktopLocalRecordingPersistence?
    var selection: DesktopHostRecordingLocationSelection?
    var notice: String?
    var cancel: (@Sendable () -> Void)?
}

enum DesktopHostRecordingLocation {
    static let filename = "recording-location.json"
    static let unavailable = "Choosing a recordings folder is not yet available on this platform. "
        + "New recordings stay in the app's History folder."

    /// Only hosts with a qualified held-capture writer and native registry offer the choice.
    /// Windows keeps its registry fenced until native identity and restart integration exist.
    static var isQualifiedPlatform: Bool {
        #if os(Linux) && canImport(Glibc)
        true
        #else
        false
        #endif
    }

    /// Blocking: run on a worker. Opening never creates the namespace; only an explicit
    /// local choice initializes it. Returns nil when no folder was ever chosen here, and
    /// otherwise the namespace the store now uses (`active` when it already had one).
    static func activate(
        _ store: DesktopRecordingStore, initialize: Bool
    ) async throws -> Activation? {
        guard await !store.hasAudioLocations else { return .active }
        let history = await store.directory
        let persistence: DesktopLocalRecordingPersistence
        do {
            persistence = try DesktopLocalRecordingPersistence.open(historyDirectory: history)
        } catch DesktopRecordingRegistryError.missing {
            guard initialize else { return nil }
            persistence = try DesktopLocalRecordingPersistence.initialize(historyDirectory: history)
        }
        do {
            let locations = try DesktopRecordingLocations(historyDirectory: history, persistence: persistence)
            try Task.checkCancellation()
            try await store.activateAudioLocations(locations)
            return .opened(persistence)
        } catch {
            try? persistence.close()
            throw error
        }
    }

    enum Activation: Sendable {
        case active
        case opened(DesktopLocalRecordingPersistence)

        var persistence: DesktopLocalRecordingPersistence? {
            if case let .opened(persistence) = self { return persistence }
            return nil
        }
    }

    static func isUnavailable(_ error: Error) -> Bool {
        switch error {
        case DesktopRecordingRegistryError.unsupported, DesktopRecordingRegistryError.identityUnavailable,
             DesktopOwnedCaptureError.unsupportedPlatform:
            return true
        default:
            return false
        }
    }

    static func loadSelection(_ url: URL) -> DesktopHostRecordingLocationSelection? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DesktopHostRecordingLocationSelection.self, from: data)
    }

    static func isInside(_ candidate: URL, _ folder: URL) -> Bool {
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(with: folder) {
            $0.caseInsensitiveCompare($1) == .orderedSame
        }
    }
}

extension DesktopHostController {
    /// Before History recovery: reopens an existing private namespace so audio saved in a
    /// chosen folder stays playable, and restores the verified choice. Never creates the
    /// namespace, authorises a folder or moves audio.
    func activateRecordingLocations() async {
        guard !closed, recordingLocation.cancel == nil else { return }
        let store = store
        let selectionURL = directory.appendingPathComponent(DesktopHostRecordingLocation.filename)
        let worker = Task.detached { () async throws -> (
            DesktopHostRecordingLocation.Activation?, DesktopHostRecordingLocationSelection?, URL?
        ) in
            let saved = DesktopHostRecordingLocation.loadSelection(selectionURL)
            guard let activation = try await DesktopHostRecordingLocation.activate(store, initialize: false) else {
                return (nil, saved, nil)
            }
            var root: URL?
            if let saved { root = await store.audioLocationRoot(saved.locationID) }
            return (activation, saved, root)
        }
        recordingLocation.cancel = { worker.cancel() }
        defer { recordingLocation.cancel = nil }
        do {
            let (activation, saved, root) = try await worker.value
            guard let activation else {
                if saved != nil {
                    recordingLocation.notice = "The chosen recordings folder is not registered on this computer. "
                        + "New recordings are saved in History until you choose a folder again."
                }
                return
            }
            if let persistence = activation.persistence { recordingLocation.persistence = persistence }
            guard let saved else { return }
            if let root, root.standardizedFileURL.path == saved.path {
                recordingLocation.selection = saved
            } else {
                recordingLocation.notice = "The chosen recordings folder could not be verified. "
                    + "New recordings are saved in History until you choose a folder again."
            }
        } catch {
            // Without an earlier choice nothing depends on the namespace, so stay quiet.
            guard !DesktopHostRecordingLocation.isUnavailable(error),
                  FileManager.default.fileExists(atPath: selectionURL.path) else { return }
            recordingLocation.notice = "Recordings saved in a chosen folder are unavailable: "
                + "\(error.localizedDescription) New recordings are saved in History."
        }
    }

    /// An explicit local choice. Existing recordings stay where they are; nothing is moved or deleted.
    package func chooseRecordingsDirectory(_ path: String) async {
        guard !closed else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { useDefaultRecordingsDirectory(); return }
        guard DesktopHostRecordingLocation.isQualifiedPlatform else {
            update(DesktopHostRecordingLocation.unavailable)
            return
        }
        guard recordingLocation.cancel == nil else {
            update("A recordings folder change is already running.")
            return
        }
        guard !busy, recording == nil, ownedDictation == nil, ownedCaptureStartup == nil,
              handsFreeRun == nil, comparisonCapture == nil else {
            update("Finish the current recording before changing the recordings folder.")
            return
        }
        guard (trimmed as NSString).isAbsolutePath else {
            update("Choose a recordings folder with a full path.")
            return
        }
        let root = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        if let current = recordingLocation.selection, current.path == root.path {
            update("New recordings are already saved in \(root.path).")
            return
        }
        guard !DesktopHostRecordingLocation.isInside(root, directory) else {
            update("Choose a folder outside the app's data folder. The default already saves recordings there.")
            return
        }
        activeOperations += 1
        defer { finishOperation() }
        let store = store
        let worker = Task.detached { () async -> (DesktopLocalRecordingPersistence?, Result<UUID, any Error>) in
            let activation: DesktopHostRecordingLocation.Activation?
            do {
                activation = try await DesktopHostRecordingLocation.activate(store, initialize: true)
            } catch {
                return (nil, .failure(error))
            }
            // Once activated the store keeps the namespace even if authorisation fails.
            do {
                try Task.checkCancellation()
                let locationID = try await store.authorizeLocallySelectedAudioRoot(root)
                return (activation?.persistence, .success(locationID))
            } catch {
                return (activation?.persistence, .failure(error))
            }
        }
        recordingLocation.cancel = { worker.cancel() }
        defer { recordingLocation.cancel = nil }
        let (persistence, result) = await worker.value
        if let persistence { recordingLocation.persistence = persistence }
        let locationID: UUID
        do {
            locationID = try result.get()
        } catch {
            guard !closed else { return }
            update(DesktopHostRecordingLocation.isUnavailable(error) ? DesktopHostRecordingLocation.unavailable
                : "Could not use that recordings folder: \(error.localizedDescription)")
            return
        }
        guard !closed else { return }
        let selection = DesktopHostRecordingLocationSelection(locationID: locationID, path: root.path)
        recordingLocation.selection = selection
        recordingLocation.notice = nil
        var status = "New recordings will be saved in \(root.path). Existing recordings stay where they are."
        do {
            try effects.writeSettings(
                JSONEncoder().encode(selection),
                to: directory.appendingPathComponent(DesktopHostRecordingLocation.filename)
            )
        } catch {
            status += " The choice could not be saved and resets when the app restarts: "
                + error.localizedDescription
        }
        update(status)
    }

    /// Returns new recordings to History. Audio already saved in a chosen folder stays there and playable.
    package func useDefaultRecordingsDirectory() {
        guard !closed else { return }
        let previous = recordingLocation.selection
        recordingLocation.selection = nil
        recordingLocation.notice = nil
        let url = directory.appendingPathComponent(DesktopHostRecordingLocation.filename)
        var status = previous.map {
            "New recordings will be saved in History. Recordings already in \($0.path) stay there."
        } ?? "New recordings are saved in History."
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch {
                status += " The previous choice could not be cleared: \(error.localizedDescription)"
            }
        }
        update(status)
    }

    /// The WAV for a new recording: in the verified chosen folder when one is selected,
    /// otherwise in History. A chosen folder that fails falls back to History with a note.
    func openRecordingFile(
        id: UUID, rate: Int, profile: DesktopProfileSession
    ) async throws -> (file: PCMRecordingFile, record: DesktopRecordingStore.Record) {
        let filename = id.uuidString + ".wav"
        var fallback: String?
        if let selection = recordingLocation.selection {
            do {
                let capture = try await store.createLocallyAuthorizedCapture(
                    at: selection.locationID, recordingID: id
                )
                let file = try PCMRecordingFile(ownedFile: capture.file, sampleRate: rate)
                return (file, profileRecord(id: id, filename: filename, profile: profile, capture: capture))
            } catch {
                fallback = "Saved in History: the chosen recordings folder was unavailable "
                    + "(\(error.localizedDescription))."
            }
        }
        let file = try PCMRecordingFile(
            url: directory.appendingPathComponent("History").appendingPathComponent(filename), sampleRate: rate
        )
        var record = profileRecord(id: id, filename: filename, profile: profile)
        if let fallback { record.profileNotes = (record.profileNotes ?? []) + [fallback] }
        return (file, record)
    }

    /// After a complete close: releases the exclusive namespace so the next launch can open it.
    func releaseRecordingLocations() {
        guard let persistence = recordingLocation.persistence else { return }
        recordingLocation.persistence = nil
        do { try persistence.close() } catch {
            let message = "Recording locations close failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    /// The folder Open folder reveals: the chosen folder, otherwise History.
    func recordingsFolderToReveal() async -> URL {
        if let selection = recordingLocation.selection {
            return URL(fileURLWithPath: selection.path, isDirectory: true)
        }
        return await store.directory
    }
}
