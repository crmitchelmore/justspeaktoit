import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

/// Local model checks for `--self-test` and `--local-transcription-self-test`.
enum WindowsLocalSelfTest {
    /// Native pieces that need no network or model: CNG SHA-256 vectors, a
    /// complete download, resume, verification, tamper and removal cycle of
    /// the real installer on NTFS with a synthetic transport, then the
    /// controller's ownership of models it removes.
    static func run() async throws {
        try checkDigestVectors()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jsti-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try DesktopHostLocalModelSelfTest(digests: WindowsSHA256Hasher.provider)
        let (body, item, transport) = (fixture.body, fixture.item, fixture.transport)
        let installer = LocalModelInstaller(root: root, digests: WindowsSHA256Hasher.provider, transport: transport)
        do {
            _ = try await installer.install(item)
            throw WindowsNativeError(message: "An interrupted model download was reported as complete.")
        } catch is LocalModelDownloadError {}
        guard case .partial(let received, _) = installer.state(of: item),
              received >= DesktopHostLocalModelSelfTest.interruptedAfter else {
            throw WindowsNativeError(message: "An interrupted model download did not keep its bytes.")
        }
        transport.dropAfter = nil
        let file = try await installer.install(item)
        guard try Data(contentsOf: file) == body, transport.offsets == [0, received],
              installer.state(of: item) == .installed else {
            throw WindowsNativeError(message: "A resumed model download did not produce the pinned file.")
        }
        try installer.verify(item)
        var tampered = body
        tampered[1] ^= 1
        try tampered.write(to: file)
        do {
            try installer.verify(item)
            throw WindowsNativeError(message: "A tampered model file passed verification.")
        } catch LocalModelInstallError.checksumMismatch {}
        try installer.remove(item)
        guard installer.state(of: item) == .notInstalled else {
            throw WindowsNativeError(message: "Removing a model left files behind.")
        }
        print("Local model download, resume, verification and removal self-test passed.")
        try await WindowsLocalRemovalSelfTest.run()
    }

    /// Windows CNG SHA-256 against the published test vectors.
    private static func checkDigestVectors() throws {
        let vectors = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        ]
        for (input, expected) in vectors {
            guard try WindowsSHA256Hasher.provider.sha256(of: Data(input.utf8)) == expected else {
                throw WindowsNativeError(message: "Windows CNG SHA-256 returned a wrong digest.")
            }
        }
    }

    /// Runs `--local-transcription-self-test` when requested; false otherwise.
    static func handle(_ arguments: [String]) async throws -> Bool {
        guard arguments.contains("--local-transcription-self-test") else { return false }
        try await transcribe(arguments: arguments)
        return true
    }

    /// `--local-transcription-self-test <wav> --expect <phrase> [--model <catalogue id>]`:
    /// downloads (or reuses) the pinned model through the app's own installer
    /// into `JSTI_LOCAL_MODEL_DIRECTORY`, loads the bundled whisper.cpp runtime
    /// and transcribes the WAV. Needs network on first use.
    static func transcribe(arguments: [String]) async throws {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let audio = value(after: "--local-transcription-self-test"),
              let expected = value(after: "--expect") else {
            throw WindowsNativeError(message: "Usage: --local-transcription-self-test <wav> --expect <phrase>")
        }
        let identifier = value(after: "--model") ?? "local/whisperkit/tiny"
        guard let spec = DesktopLocalTranscription.model(for: identifier, host: .windows) else {
            throw WindowsNativeError(message: "\(identifier) is not a Windows on-device model.")
        }
        let environment = ProcessInfo.processInfo.environment
        let root = environment["JSTI_LOCAL_MODEL_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("jsti-local-models")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installer = LocalModelInstaller(
            root: root, digests: WindowsSHA256Hasher.provider, transport: LocalModelURLSessionTransport()
        )
        let file = try await installer.install(.init(spec))
        try installer.verify(.init(spec))
        let allowGPU = environment["JSTI_WHISPER_CPU_ONLY"] != "1"
        let runtime = try WindowsWhisperRuntime.open(allowGPU: allowGPU)
        let started = Date()
        let result = try await DesktopLocalTranscription.transcribe(
            audioURL: URL(fileURLWithPath: audio), model: spec, modelFile: file, language: "en",
            recognizer: WindowsWhisperRecognizer(runtime: runtime)
        )
        let elapsed = Date().timeIntervalSince(started)
        let normalised = { (text: String) in
            text.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
        }
        print("Runtime: \(runtime.description)")
        print("Transcript: \(result.text)")
        guard normalised(result.text).contains(normalised(expected)) else {
            throw WindowsNativeError(message: "Local transcription did not contain the expected phrase.")
        }
        try await checkCancellationAndDigest(runtime: runtime, spec: spec, file: file)
        let timing = String(format: "%.2f s (audio %.2f s)", elapsed, result.duration)
        print("Local transcription self-test passed in \(timing).")
    }

    /// Cancelling before recognition starts must not run the model, and the
    /// runtime uses only bytes whose digest matches the one it is given.
    private static func checkCancellationAndDigest(
        runtime: WindowsWhisperRuntime, spec: WhisperCppModel, file: URL
    ) async throws {
        let samples = [Float](repeating: 0.1, count: 16_000)
        let cancelled = Task {
            try await runtime.transcribe(
                samples: samples, modelFile: file, modelSHA256: spec.artifact.sha256, language: nil
            )
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw WindowsNativeError(message: "A cancelled local transcription completed.")
        } catch is CancellationError {}
        // The runtime hashes the bytes it loads: the cached model is not reused
        // for another digest, and bytes that do not match are never used.
        do {
            _ = try await runtime.transcribe(
                samples: samples, modelFile: file, modelSHA256: String(repeating: "0", count: 64), language: nil
            )
            throw WindowsNativeError(message: "A model whose bytes do not match the digest was used.")
        } catch DesktopLocalTranscriptionError.modelDoesNotMatchDigest {}
    }
}
