import Foundation
import SpeakCore

/// A pinned archive installed as an immutable directory of verified files.
public struct LocalModelPackage: Hashable, Sendable {
    /// ASCII directory name, stable across releases of this package.
    public let identifier: String
    public let displayName: String
    public let archive: LocalModelPinnedArchive
    /// Files written flat into each installed version, by file name.
    public let installedFiles: [LocalModelPinnedFile]
    /// Licence and attribution text written as NOTICE.txt beside the files.
    public let notice: String
    /// Only model data may be imported from an extracted folder. Executable
    /// runtimes are accepted solely as their exact pinned archive.
    public let allowsFolderImport: Bool

    public init(
        identifier: String, displayName: String, archive: LocalModelPinnedArchive,
        installedFiles: [LocalModelPinnedFile], notice: String, allowsFolderImport: Bool
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.archive = archive
        self.installedFiles = installedFiles
        self.notice = notice
        self.allowsFolderImport = allowsFolderImport
    }

    /// The Parakeet v3 int8 recognizer files and their attribution.
    public static let parakeetTDTV3Int8: LocalModelPackage = {
        let spec = ParakeetLocalModels.tdtV3Int8OfflineRecognizer
        return LocalModelPackage(
            identifier: "parakeet-tdt-0.6b-v3-int8", displayName: spec.displayName, archive: spec.archive,
            installedFiles: spec.runtimeFiles, notice: spec.attribution, allowsFolderImport: true
        )
    }()
}

/// Provenance persisted beside every installed version.
public struct LocalModelInstallReceipt: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        public let name: String
        public let byteCount: Int64
        public let sha256: String
    }

    public enum Origin: String, Codable, Sendable {
        case download
        case archiveImport
        case folderImport
    }

    public let schemaVersion: Int
    public let packageIdentifier: String
    public let version: String
    public let origin: Origin
    public let sourceURL: String
    public let archiveByteCount: Int64
    public let archiveSHA256: String
    public let digestProvider: String
    public let installedAt: Date
    public let files: [File]

    func matches(_ package: LocalModelPackage) -> Bool {
        schemaVersion == 1 && packageIdentifier == package.identifier
            && archiveSHA256 == package.archive.sha256 && archiveByteCount == package.archive.byteCount
            && files == package.installedFiles.map { File(name: $0.filename, byteCount: $0.byteCount, sha256: $0.sha256) }
    }
}

/// A verified, immutable installed version. Files are addressed by pin; the
/// native runtime re-verifies their digests through held handles on load.
public struct LocalModelInstallation: Hashable, Sendable {
    public let package: LocalModelPackage
    public let directory: URL
    public let receipt: LocalModelInstallReceipt

    public var version: String { receipt.version }

    public func url(for file: LocalModelPinnedFile) -> URL {
        directory.appendingPathComponent(file.filename)
    }
}

public enum LocalModelInstallState: Equatable, Sendable {
    case notInstalled
    case downloading(received: Int64, total: Int64)
    case verifying
    case expanding(processed: Int64, total: Int64)
    case installed(LocalModelInstallReceipt)
    case failed(String)
}

public enum LocalModelStoreError: LocalizedError, Equatable {
    case invalidPackage
    case unsafeLocation(String)
    case fileSystem(String)
    case corruptRecord
    case busy
    case inUse
    case notInstalled
    case unsupportedHost(String)
    case download(String)
    case wrongArchive
    case folderImportUnsupported
    case executableContent(String)
    case coreMLModel(String)
    case rawNeMoCheckpoint(String)
    case wrongModel(String)
    case missingFiles([String])
    case linkedContent(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPackage: return "The local model definition is inconsistent."
        case .unsafeLocation(let name): return "The local model folder \(name) is not a private, regular location."
        case .fileSystem(let detail): return detail
        case .corruptRecord: return "The local model install record is unreadable. Download the model again."
        case .busy: return "Another download or import for this model is still running."
        case .inUse: return "The model is in use. Wait for transcription to finish or cancel it, then try again."
        case .notInstalled: return "The model is not installed."
        case .unsupportedHost(let detail): return detail
        case .download(let detail): return detail
        case .wrongArchive:
            return "The chosen file is not the pinned archive for this model; its size or SHA-256 differs."
        case .folderImportUnsupported:
            return "The local runtime can only be installed from its exact pinned archive, never from loose files."
        case .executableContent(let name):
            return "The folder contains \(name). Executables and libraries are never imported with model files."
        case .coreMLModel(let name):
            return "\(name) is a Core ML model. Core ML weights run only on macOS."
        case .rawNeMoCheckpoint(let name):
            return "\(name) is a raw NeMo checkpoint. Import the pinned sherpa-onnx int8 export instead."
        case .wrongModel(let name):
            return "\(name) belongs to a different export of this model. Import the pinned int8 files."
        case .missingFiles(let names): return "The folder is missing \(names.joined(separator: ", "))."
        case .linkedContent(let name): return "The folder contains a link or junction (\(name)), which is refused."
        }
    }
}
