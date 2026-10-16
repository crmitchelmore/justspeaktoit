import Foundation
import SpeakCore
import CLlamaCpp

/// Packaging, not user settings or migration data, provisions this directory.
/// There is deliberately no automatic runtime download or guessed checksum.
public struct NativeLocalLLMProvisioning: Codable, Equatable, Sendable {
    public static let abiCommit = "a7a98e0fffed794396b3fbad4dcdbbc184963645"
    public let schemaVersion: Int
    public let commit: String
    public let platform: String
    public let architecture: String
    public let library: String
    public let sha256: String

    public static var hostPlatform: String {
        #if os(Windows)
        return "windows"
        #elseif os(Linux)
        return "linux"
        #else
        return "unsupported"
        #endif
    }
    public static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
    public static var libraryName: String { hostPlatform == "windows" ? "llama.dll" : "libllama.so" }

    public static func read(directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("provisioning.json")
        do {
            let folder = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard folder.isDirectory == true, folder.isSymbolicLink != true,
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (1...16_384).contains(size) else {
                throw LocalLLMError.runtimeUnavailable("Invalid runtime provisioning manifest.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 16_385) ?? Data()
            guard bytes.count <= 16_384 else { throw LocalLLMError.runtimeUnavailable("Manifest exceeds its bound.") }
            let manifest = try JSONDecoder().decode(Self.self, from: bytes)
            guard hostPlatform != "unsupported", hostArchitecture != "unsupported",
                  manifest.schemaVersion == 1, manifest.commit == abiCommit,
                  manifest.platform == hostPlatform, manifest.architecture == hostArchitecture,
                  manifest.library == libraryName,
                  HuggingFaceWhisperModel.isHex(manifest.sha256, count: 64) else {
                throw LocalLLMError.runtimeUnavailable(
                    "Install the pinned native CPU runtime for this platform and ABI."
                )
            }
            let library = directory.appendingPathComponent(manifest.library)
            let binary = try library.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard binary.isRegularFile == true, binary.isSymbolicLink != true,
                  let byteCount = binary.fileSize, (1...536_870_912).contains(byteCount) else {
                throw LocalLLMError.runtimeUnavailable("The provisioned runtime library is missing or invalid.")
            }
            return manifest
        } catch let error as LocalLLMError {
            throw error
        } catch {
            throw LocalLLMError.runtimeUnavailable(
                "Install or repair an app package containing LocalLLMRuntime and its pinned provisioning manifest. "
                    + "No automatic native-runtime installer is available. \(error.localizedDescription)"
            )
        }
    }
}

/// CPU inference runs in process on a dedicated queue, never on the host actor,
/// UI/settings admission queue, capture thread, Python process or local server.
public final class NativeLocalLLMRuntime: DesktopLocalLLMRuntime, @unchecked Sendable {
    public let directory: URL
    private let digests: LocalModelDigestProvider
    private let queue = DispatchQueue(label: "JustSpeakToIt.local-llm.inference", qos: .userInitiated)

    public init(directory: URL, digests: LocalModelDigestProvider) {
        self.directory = directory
        self.digests = digests
    }

    public func complete(
        model: HuggingFaceGGUFModel, file: URL, systemPrompt: String, userPrompt: String, temperature: Double
    ) async throws -> String {
        try Task.checkCancellation()
        guard temperature.isFinite, (0...1).contains(temperature) else {
            throw DesktopPostProcessingError.invalidTemperature
        }
        guard !systemPrompt.contains("\0"), !userPrompt.contains("\0"),
              systemPrompt.utf8.count + userPrompt.utf8.count <= 256 * 1_024 else {
            throw LocalLLMError.inference("The prompt contains a NUL character or exceeds the native input limit.")
        }
        let run = try NativeLLMRun(digests: digests, digest: model.sha256)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self, run] in
                    do {
                        try run.checkCancellation()
                        let manifest = try NativeLocalLLMProvisioning.read(directory: directory)
                        let library = directory.appendingPathComponent(manifest.library)
                        try run.verifyLibrary(library, expected: manifest.sha256)
                        try run.checkCancellation()
                        let result = try run.complete(
                            library: library,
                            request: NativeLLMCompletionRequest(
                                model: model, file: file, system: systemPrompt,
                                user: userPrompt, temperature: temperature
                            )
                        )
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { run.cancel() }
    }
}

/// Bundles the prompt inputs for one native completion so the native run's
/// entry point stays within SwiftLint's parameter-count limit without losing
/// any of the pinned library/model/file/system/user/temperature identities.
private struct NativeLLMCompletionRequest {
    let model: HuggingFaceGGUFModel
    let file: URL
    let system: String
    let user: String
    let temperature: Double
}

private final class NativeLLMRun: @unchecked Sendable {
    let pointer: OpaquePointer
    let digests: LocalModelDigestProvider
    let digest: String
    var verificationError: Error?

    init(digests: LocalModelDigestProvider, digest: String) throws {
        guard let pointer = jsti_llama_run_create() else { throw LocalLLMError.inference("Native allocation failed.") }
        self.pointer = pointer
        self.digests = digests
        self.digest = digest
    }
    deinit { jsti_llama_run_destroy(pointer) }
    func cancel() { jsti_llama_run_cancel(pointer) }
    func checkCancellation() throws {
        if jsti_llama_run_is_cancelled(pointer) != 0 { throw CancellationError() }
    }

    func verifyLibrary(_ file: URL, expected: String) throws {
        let hasher = try digests.makeSHA256()
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while true {
            try checkCancellation()
            guard let chunk = try input.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty else { break }
            try chunk.withUnsafeBytes { try hasher.update($0) }
        }
        guard try hasher.finish() == expected else {
            throw LocalLLMError.runtimeUnavailable("The runtime library does not match its package manifest.")
        }
    }

    func complete(library: URL, request: NativeLLMCompletionRequest) throws -> String {
        let model = request.model
        let file = request.file
        let system = request.system
        let user = request.user
        let temperature = request.temperature
        var output: UnsafeMutablePointer<CChar>?
        var error = [CChar](repeating: 0, count: 2_048)
        let errorCapacity = error.count
        let status = library.path.withCString { library in
            file.path.withCString { file in
                system.withCString { system in
                    user.withCString { user in
                        jsti_llama_run_complete(
                            pointer, library, file, model.byteCount, { bytes, count, context in
                                guard let bytes, let context else { return 1 }
                                let run = Unmanaged<NativeLLMRun>.fromOpaque(context).takeUnretainedValue()
                                do {
                                    let hasher = try run.digests.makeSHA256()
                                    var offset = 0
                                    while offset < count {
                                        try run.checkCancellation()
                                        let length = min(4 * 1_024 * 1_024, count - offset)
                                        try hasher.update(UnsafeRawBufferPointer(start: bytes + offset, count: length))
                                        offset += length
                                    }
                                    guard try hasher.finish() == run.digest else {
                                        throw LocalModelInstallError.checksumMismatch
                                    }
                                    return 0
                                } catch { run.verificationError = error; return 1 }
                            }, Unmanaged.passUnretained(self).toOpaque(), system, user, temperature,
                            &output, &error, errorCapacity
                        )
                    }
                }
            }
        }
        defer { if let output { jsti_llama_string_free(output) } }
        try checkCancellation()
        if let verificationError { throw verificationError }
        guard status == 0, let output else {
            throw LocalLLMError.inference(String(cString: error))
        }
        guard let result = String(validatingUTF8: output),
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.contains("<think>"), !result.contains("</think>") else {
            throw LocalLLMError.invalidOutput
        }
        return result
    }
}
