import Foundation
import SpeakCore

enum DesktopVocabularyMigrationSource {
    static func read(
        _ path: String, root: URL, checkCancellation: () throws -> Void
    ) throws -> Data? {
        try checkCancellation()
        let components = path.split(separator: "/").map(String.init)
        var parent = root
        for component in components.dropLast() {
            guard try directoryExists(parent) else { return nil }
            parent.appendPathComponent(component, isDirectory: true)
        }
        guard try directoryExists(parent) else { return nil }
        let file = root.appendingPathComponent(path)
        let identity: DesktopRecordingAudioSnapshot.Identity
        do {
            identity = try ownedIdentity(at: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard identity.size <= DataMigrationArchivePolicy.maximumJSONBytes else {
            throw DataMigrationError.invalid("A vocabulary store exceeds the JSON size limit.")
        }
        try checkCancellation()
        let handle = try FileHandle(forReadingFrom: file)
        let data: Data
        do {
            data = try read(handle, maximumBytes: identity.size, checkCancellation: checkCancellation)
            guard UInt64(data.count) == identity.size,
                  try ownedIdentity(at: file) == identity,
                  try directoryExists(parent) else {
                throw DataMigrationError.invalid("A vocabulary source changed during collection.")
            }
        } catch {
            let original = error
            do { try handle.close() } catch {
                throw DataMigrationError.invalid(
                    "\(original.localizedDescription) The vocabulary source could not be closed: "
                        + error.localizedDescription
                )
            }
            throw original
        }
        try handle.close()
        try checkCancellation()
        return data
    }

    private static func ownedIdentity(at url: URL) throws -> DesktopRecordingAudioSnapshot.Identity {
        do {
            return try DesktopRecordingStore.audioCleanupIdentity(at: url)
        } catch DesktopRecordingAudioCleanupError.unsafeFile {
            throw DataMigrationError.invalid("A vocabulary source is linked, non-regular, or has unreadable ownership.")
        }
    }

    private static func directoryExists(_ url: URL) throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
                throw DataMigrationError.invalid("Vocabulary storage must be an owned non-linked directory.")
            }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }

    private static func read(
        _ handle: FileHandle, maximumBytes: UInt64, checkCancellation: () throws -> Void
    ) throws -> Data {
        var result = Data()
        while true {
            try checkCancellation()
            let remaining = maximumBytes - UInt64(result.count)
            guard let chunk = try handle.read(upToCount: Int(min(65_536, remaining + 1))),
                  !chunk.isEmpty else { break }
            result.append(chunk)
            guard UInt64(result.count) <= maximumBytes else {
                throw DataMigrationError.invalid("A vocabulary source grew during collection.")
            }
        }
        return result
    }
}
