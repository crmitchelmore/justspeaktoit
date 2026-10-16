import Foundation
import SpeakCore

/// Only a host with an implemented in-process adapter supplies this capability.
/// Model catalogue membership and transferred settings never grant execution.
public protocol DesktopLocalLLMEngine: Sendable {
    func complete(
        modelIdentifier: String, systemPrompt: String, userPrompt: String, temperature: Double
    ) async throws -> String
}

public protocol DesktopLocalLLMRuntime: Sendable {
    /// Must hash the immutable bytes actually loaded before inference, support
    /// cooperative cancellation and retain native resources until work ends.
    func complete(
        model: HuggingFaceGGUFModel, file: URL, systemPrompt: String, userPrompt: String, temperature: Double
    ) async throws -> String
}

public enum GGUFImportValidation {
    public static func validate(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalLLMError.unsupportedArtifact
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = [UInt8](try handle.read(upToCount: 24) ?? Data())
        guard header.count == 24, Array(header.prefix(4)) == Array("GGUF".utf8),
              header[4] == 3, header[5...7].allSatisfy({ $0 == 0 }),
              header[8...15].contains(where: { $0 != 0 }) else {
            throw LocalLLMError.unsupportedArtifact
        }
    }
}
