import Foundation
import SpeakCore

/// Qualifies a user-chosen folder of extracted model files before anything
/// is copied. Links, executables and libraries, Core ML bundles and raw NeMo
/// checkpoints are refused by name; other ONNX exports are reported as the
/// wrong model rather than guessed at. Only the pinned files are copied, and
/// each is verified by size and SHA-256 afterwards.
struct LocalModelFolderImport {
    static let maximumEntries = 4_096
    static let maximumDepth = 4

    private static let executableExtensions: Set<String> = [
        "dll", "exe", "sys", "com", "bat", "cmd", "ps1", "psm1", "vbs", "js", "msi", "msix", "scr", "cpl",
        "ocx", "so", "dylib"
    ]
    private static let coreMLExtensions: Set<String> = ["mlmodelc", "mlpackage", "mlmodel"]

    let fileSystem: LocalModelFileSystem
    let package: LocalModelPackage

    /// The folder itself, or its child named after the archive root, when it
    /// holds every pinned file.
    func sourceDirectory(_ folder: URL) throws -> URL {
        let names = package.installedFiles.map(\.filename)
        guard fileSystem.itemKind(folder) == .directory else { throw LocalModelStoreError.missingFiles(names) }
        var budget = Self.maximumEntries
        try scan(folder, depth: 0, budget: &budget)
        let nested = folder.appendingPathComponent(package.archive.rootDirectory, isDirectory: true)
        if holdsAllFiles(folder) { return folder }
        if fileSystem.itemKind(nested) == .directory, holdsAllFiles(nested) { return nested }
        if let other = try onnxFiles(in: folder).first ?? onnxFiles(in: nested).first {
            throw LocalModelStoreError.wrongModel(other)
        }
        throw LocalModelStoreError.missingFiles(names)
    }

    private func holdsAllFiles(_ directory: URL) -> Bool {
        package.installedFiles.allSatisfy { file in
            if case .regularFile = fileSystem.itemKind(directory.appendingPathComponent(file.filename)) { return true }
            return false
        }
    }

    private func onnxFiles(in directory: URL) throws -> [String] {
        guard fileSystem.itemKind(directory) == .directory else { return [] }
        return try fileSystem.contentsOfDirectory(directory).filter { $0.lowercased().hasSuffix(".onnx") }.sorted()
    }

    private func scan(_ directory: URL, depth: Int, budget: inout Int) throws {
        for name in try fileSystem.contentsOfDirectory(directory).sorted() {
            budget -= 1
            guard budget >= 0 else {
                throw LocalModelStoreError.fileSystem("The folder contains too many items to import.")
            }
            let url = directory.appendingPathComponent(name)
            let kind = fileSystem.itemKind(url)
            try Self.classify(name, kind: kind)
            if kind == .directory, depth < Self.maximumDepth {
                try scan(url, depth: depth + 1, budget: &budget)
            }
        }
    }

    static func classify(_ name: String, kind: LocalModelItemKind) throws {
        let fileExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
        if kind == .other { throw LocalModelStoreError.linkedContent(name) }
        if coreMLExtensions.contains(fileExtension) { throw LocalModelStoreError.coreMLModel(name) }
        if fileExtension == "nemo" { throw LocalModelStoreError.rawNeMoCheckpoint(name) }
        if executableExtensions.contains(fileExtension) { throw LocalModelStoreError.executableContent(name) }
    }
}
