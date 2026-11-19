import CryptoKit
import Foundation

/// Only directories created with this ownership record are eligible for removal.
/// Legacy Hub caches and Apple's Core ML specialization caches are never adopted.
struct WhisperKitModelStorage {
    enum StorageError: LocalizedError {
        case unsafePath
        case unownedDirectory

        var errorDescription: String? {
            switch self {
            case .unsafePath: return "The model storage path is outside its managed directory."
            case .unownedDirectory:
                return "The model directory has no matching ownership record and was left untouched."
            }
        }
    }

    private struct Ownership: Codable {
        let version: Int
        let modelID: String
        var modelFolder: String?
        var removalPending: Bool?
    }

    private let root: URL
    private let fileManager: FileManager
    private let removeItem: (URL) throws -> Void
    private let writeData: (Data, URL) throws -> Void

    init(
        root: URL, fileManager: FileManager = .default,
        removeItem: ((URL) throws -> Void)? = nil, writeData: ((Data, URL) throws -> Void)? = nil
    ) {
        // Resolve system aliases in the parent, but never adopt a symlink replacing
        // our own root. Every operation checks that this boundary is still intact.
        self.root = root.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
        self.fileManager = fileManager
        self.removeItem = removeItem ?? { try fileManager.removeItem(at: $0) }
        self.writeData = writeData ?? { try $0.write(to: $1, options: .atomic) }
    }

    func hasOwnership(for modelID: String) throws -> Bool {
        try self.readOwnership(for: modelID) != nil
    }

    func hasDownload(for modelID: String) throws -> Bool {
        guard try self.readOwnership(for: modelID) != nil else { return false }
        return self.fileManager.fileExists(atPath: self.downloadBase(for: modelID).path)
    }

    /// Returns an exclusive Hub download base, including this model's tokenizers.
    /// An existing unmarked directory must never acquire ownership retroactively.
    func prepare(for modelID: String) throws -> URL {
        let slot = self.slot(for: modelID)
        try self.validateBoundaries(for: modelID)
        try self.fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        if !self.fileManager.fileExists(atPath: slot.path) {
            try self.fileManager.createDirectory(at: slot, withIntermediateDirectories: false)
            do {
                try self.write(Ownership(version: 1, modelID: modelID), for: modelID)
            } catch {
                // Recover only the empty directory created by this call. Never remove
                // an existing unmarked directory or anything another writer added.
                self.removeNewEmptySlot(for: modelID)
                throw error
            }
        }
        guard try self.readOwnership(for: modelID) != nil else { throw StorageError.unownedDirectory }
        let base = self.downloadBase(for: modelID)
        var isDirectory: ObjCBool = false
        if self.fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StorageError.unsafePath }
        } else {
            try self.fileManager.createDirectory(at: base, withIntermediateDirectories: false)
        }
        return base
    }

    /// Persist the SDK's actual model folder, never a guessed Hub layout.
    func recordModelFolder(_ folder: URL, for modelID: String) throws {
        guard var ownership = try self.readOwnership(for: modelID) else { throw StorageError.unownedDirectory }
        let base = self.downloadBase(for: modelID)
        try self.validateModelFolder(folder, inside: base)
        ownership.removalPending = false
        ownership.modelFolder = folder.standardizedFileURL.pathComponents.dropFirst(base.pathComponents.count)
            .joined(separator: "/")
        try self.write(ownership, for: modelID)
    }

    func modelFolder(for modelID: String) throws -> URL? {
        guard let ownership = try self.readOwnership(for: modelID), ownership.removalPending != true,
                    let relative = ownership.modelFolder else { return nil }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StorageError.unsafePath
        }
        let base = self.downloadBase(for: modelID)
        let folder = base.appendingPathComponent(relative, isDirectory: true)
        try self.validateModelFolder(folder, inside: base)
        var isDirectory: ObjCBool = false
        guard self.fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return folder
    }

    /// Keep the small ownership record outside the removable payload so a partial
    /// filesystem failure can be retried without losing proof of ownership.
    func removeDownload(for modelID: String) throws {
        guard var ownership = try self.readOwnership(for: modelID) else { return }
        let base = self.downloadBase(for: modelID)
        // Persist intent first: recursive removal may delete only some files before
        // failing. A surviving directory must not make that partial model installed.
        ownership.removalPending = true
        try self.write(ownership, for: modelID)
        if self.fileManager.fileExists(atPath: base.path) {
            try self.removeItem(base)
        }
        ownership.modelFolder = nil
        ownership.removalPending = false
        try self.write(ownership, for: modelID)
    }

    private func slot(for modelID: String) -> URL {
        let key = SHA256.hash(data: Data(modelID.utf8)).map { String(format: "%02x", $0) }.joined()
        return self.root.appendingPathComponent(key, isDirectory: true)
    }

    private func downloadBase(for modelID: String) -> URL {
        self.slot(for: modelID).appendingPathComponent("hub", isDirectory: true)
    }

    private func ownershipURL(for modelID: String) -> URL {
        self.slot(for: modelID).appendingPathComponent("ownership.json")
    }

    private func validateBoundaries(for modelID: String) throws {
        let boundaries = [
            self.root, self.slot(for: modelID), self.downloadBase(for: modelID), self.ownershipURL(for: modelID)
        ]
        for path in boundaries {
            guard path.isFileURL,
                        path.standardizedFileURL.path == path.resolvingSymlinksInPath().standardizedFileURL.path,
                        (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw StorageError.unsafePath
            }
        }
    }

    private func validateModelFolder(_ folder: URL, inside base: URL) throws {
        let parent = base.standardizedFileURL.pathComponents
        let lexical = folder.standardizedFileURL.pathComponents
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard folder.isFileURL, lexical.count > parent.count, resolved.count > parent.count,
                    lexical.starts(with: parent), resolved.starts(with: parent) else { throw StorageError.unsafePath }
    }

    private func readOwnership(for modelID: String) throws -> Ownership? {
        try self.validateBoundaries(for: modelID)
        guard self.fileManager.fileExists(atPath: self.slot(for: modelID).path) else { return nil }
        guard let data = try? Data(contentsOf: self.ownershipURL(for: modelID)),
                    let ownership = try? JSONDecoder().decode(Ownership.self, from: data),
                    ownership.version == 1, ownership.modelID == modelID else { throw StorageError.unownedDirectory }
        return ownership
    }

    private func removeNewEmptySlot(for modelID: String) {
        do {
            try self.validateBoundaries(for: modelID)
            let slot = self.slot(for: modelID)
            guard try self.fileManager.contentsOfDirectory(atPath: slot.path).isEmpty else { return }
            try self.fileManager.removeItem(at: slot)
        } catch {
            // An unremovable directory stays unowned and will be reported on retry.
        }
    }

    private func write(_ ownership: Ownership, for modelID: String) throws {
        try self.validateBoundaries(for: modelID)
        try self.writeData(JSONEncoder().encode(ownership), self.ownershipURL(for: modelID))
    }
}
