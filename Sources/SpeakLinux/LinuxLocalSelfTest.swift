import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// Local model checks for `--self-test` and `--local-transcription-self-test`.
enum LinuxLocalSelfTest {
    /// Native pieces that need no network, model or runtime: GChecksum
    /// SHA-256 vectors, a download, resume, verification, tamper and removal
    /// cycle of the real installer in private folders with a synthetic
    /// transport, and the runtime loader's refusals.
    static func run() async throws {
        try checkDigestVectors()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jsti-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await checkInstallerCycle(root: root)
        print("Local model download, resume, verification and removal self-test passed.")
        try checkRuntimeRefusals(scratch: root)
        print("Speech runtime loader refusal self-test passed.")
    }

    private static func checkInstallerCycle(root: URL) async throws {
        let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let digest = try LinuxSHA256Hasher.provider.sha256(of: body)
        let item = LocalModelInstaller.Item(
            identifier: "local/whisperkit/tiny", displayName: "Self-test model",
            artifact: LocalModelFileArtifact(
                url: URL(string: "https://huggingface.co/self-test/resolve/0/ggml-self-test.bin")!,
                filename: "ggml-self-test.bin", byteCount: Int64(body.count), sha256: digest, license: "MIT",
                provenance: "synthetic"
            )
        )
        let transport = SelfTestTransport(body: body, dropAfter: 120_000)
        let installer = LocalModelInstaller(
            root: root, digests: LinuxSHA256Hasher.provider, transport: transport,
            prepareDirectory: { url in
                for folder in [root, url] { try LinuxFiles.preparePrivateDirectory(folder) }
            }
        )
        do {
            _ = try await installer.install(item)
            throw failure("an interrupted model download was reported as complete")
        } catch is LocalModelDownloadError {}
        guard case .partial(let received, _) = installer.state(of: item), received >= 120_000 else {
            throw failure("an interrupted model download did not keep its bytes")
        }
        transport.dropAfter = nil
        let file = try await installer.install(item)
        guard try Data(contentsOf: file) == body, transport.offsets == [0, received],
              installer.state(of: item) == .installed else {
            throw failure("a resumed model download did not produce the pinned file")
        }
        for folder in [root, installer.directory(for: item)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard mode & 0o077 == 0 else { throw failure("a model folder is readable by other users") }
        }
        try installer.verify(item)
        var tampered = body
        tampered[1] ^= 1
        try tampered.write(to: file)
        do {
            try installer.verify(item)
            throw failure("a tampered model file passed verification")
        } catch LocalModelInstallError.checksumMismatch {}
        try installer.remove(item)
        guard installer.state(of: item) == .notInstalled else { throw failure("removing a model left files behind") }
    }

    /// GLib's SHA-256 against the FIPS 180-2 vectors.
    private static func checkDigestVectors() throws {
        let vectors = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        ]
        for (input, expected) in vectors {
            guard try LinuxSHA256Hasher.provider.sha256(of: Data(input.utf8)) == expected else {
                throw failure("GLib SHA-256 returned a wrong digest")
            }
        }
    }

    /// The loader opens nothing from a relative, missing, shared-writable or
    /// incomplete directory, and an unloadable library is an error, not a crash.
    private static func checkRuntimeRefusals(scratch: URL) throws {
        let manager = FileManager.default
        let writable = scratch.appendingPathComponent("shared-runtime", isDirectory: true)
        let incomplete = scratch.appendingPathComponent("incomplete-runtime", isDirectory: true)
        let damaged = scratch.appendingPathComponent("damaged-runtime", isDirectory: true)
        for folder in [writable, incomplete, damaged] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try manager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writable.path)
        for folder in [writable, damaged] {
            for name in ["libggml-base.so.0", "libggml.so.0", LinuxWhisperRuntime.libraryName] {
                try Data("not a shared object".utf8).write(to: folder.appendingPathComponent(name))
            }
        }
        // Foundation makes every file URL absolute, so the C boundary is asked directly.
        var error = [CChar](repeating: 0, count: 512)
        guard jsti_whisper_runtime_open("relative-runtime", 0, &error, error.count) == nil,
              String(cString: error).contains("must be an absolute path") else {
            throw failure("the speech runtime accepted a relative directory")
        }
        let cases: [(URL, String)] = [
            (scratch.appendingPathComponent("missing-runtime"), "is not installed"),
            (writable, "writable by other users"),
            (incomplete, "is incomplete"),
            (damaged, "failed")
        ]
        for (directory, reason) in cases {
            do {
                _ = try LinuxWhisperRuntime.open(directory: directory, allowGPU: false)
                throw failure("the speech runtime loaded from \(directory.path)")
            } catch let error as LinuxLocalTranscriptionError where error.message.contains(reason) {}
        }
    }

    /// `--local-transcription-self-test <wav> --expect <phrase> [--model <catalogue id>]`:
    /// downloads (or reuses) the pinned model through the app's own installer
    /// into `JSTI_LOCAL_MODEL_DIRECTORY`, loads the whisper.cpp runtime from
    /// beside the app or `JSTI_WHISPER_RUNTIME_DIRECTORY` and transcribes the
    /// WAV. Needs network on first use.
    static func transcribe(arguments: [String]) async throws {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let audio = value(after: "--local-transcription-self-test"),
              let expected = value(after: "--expect") else {
            throw DesktopHostError(message: "Usage: --local-transcription-self-test <wav> --expect <phrase>")
        }
        let identifier = value(after: "--model") ?? "local/whisperkit/tiny"
        guard let spec = DesktopLocalTranscription.model(for: identifier, host: .linux) else {
            throw DesktopHostError(message: "\(identifier) is not a Linux on-device model.")
        }
        let environment = ProcessInfo.processInfo.environment
        let root = environment["JSTI_LOCAL_MODEL_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("jsti-local-models")
        // Private folders at both levels, as the app's own installer prepares them.
        let installer = LocalModelInstaller(
            root: root, digests: LinuxSHA256Hasher.provider, transport: LocalModelURLSessionTransport(),
            prepareDirectory: { url in
                for folder in [root, url] { try LinuxFiles.preparePrivateDirectory(folder) }
            }
        )
        let file = try await installer.install(.init(spec))
        try installer.verify(.init(spec))
        let runtime = try LinuxWhisperRuntime.open(allowGPU: environment["JSTI_WHISPER_CPU_ONLY"] != "1")
        let recognizer = LinuxWhisperRecognizer(runtime: runtime)
        let started = Date()
        let result = try await DesktopLocalTranscription.transcribe(
            audioURL: URL(fileURLWithPath: audio), model: spec, modelFile: file, language: "en", recognizer: recognizer
        )
        let elapsed = Date().timeIntervalSince(started)
        let normalised = { (text: String) in
            text.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
        }
        print("Runtime: \(runtime.description)")
        print("Transcript: \(result.text)")
        guard normalised(result.text).contains(normalised(expected)) else {
            throw DesktopHostError(message: "Local transcription did not contain the expected phrase.")
        }
        try await checkSilenceAndCancellation(runtime: runtime, spec: spec, file: file)
        let timing = String(format: "%.2f s (audio %.2f s)", elapsed, result.duration)
        print("Local transcription self-test passed in \(timing).")
    }

    /// Silence never reaches the model, so an empty recording stays empty, and
    /// cancelling before recognition starts must not run the model.
    private static func checkSilenceAndCancellation(
        runtime: LinuxWhisperRuntime, spec: WhisperCppModel, file: URL
    ) async throws {
        let silent = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsti-silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: silent) }
        guard let silence = PCMWaveWriter.wavData(pcm: Data(count: 32_000), sampleRate: 16_000) else {
            throw DesktopHostError(message: "Could not write the silent sample.")
        }
        try silence.write(to: silent)
        let quiet = try await DesktopLocalTranscription.transcribe(
            audioURL: silent, model: spec, modelFile: file, language: nil,
            recognizer: LinuxWhisperRecognizer(runtime: runtime)
        )
        guard quiet.text.isEmpty else { throw DesktopHostError(message: "A silent recording produced text.") }
        let samples = [Float](repeating: 0.1, count: 16_000)
        let cancelled = Task {
            try await runtime.transcribe(
                samples: samples, modelFile: file, modelSHA256: spec.artifact.sha256, language: nil
            )
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw DesktopHostError(message: "A cancelled local transcription completed.")
        } catch is CancellationError {}
        // The runtime hashes the bytes it loads: the cached model is not reused
        // for another digest, and bytes that do not match are never used.
        do {
            _ = try await runtime.transcribe(
                samples: samples, modelFile: file, modelSHA256: String(repeating: "0", count: 64), language: nil
            )
            throw DesktopHostError(message: "A model whose bytes do not match the digest was used.")
        } catch DesktopLocalTranscriptionError.modelDoesNotMatchDigest {}
    }

    private static func failure(_ message: String) -> DesktopHostError {
        DesktopHostError(message: "Local model self-test: \(message).")
    }
}

/// Serves `body` like a range-capable HTTP server, optionally dropping the
/// connection after a byte count.
private final class SelfTestTransport: LocalModelDownloadTransport, @unchecked Sendable {
    let body: Data
    private let lock = NSLock()
    private var drop: Int?
    private var requested: [Int64] = []

    var dropAfter: Int? {
        get { lock.withLock { drop } }
        set { lock.withLock { drop = newValue } }
    }

    var offsets: [Int64] { lock.withLock { requested } }

    init(body: Data, dropAfter: Int?) {
        self.body = body
        self.drop = dropAfter
    }

    func download(
        _ request: LocalModelDownloadRequest, start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        let limit = lock.withLock { () -> Int? in
            requested.append(request.resumeOffset)
            return drop
        }
        var position = Int(request.resumeOffset)
        try start(position > 0 ? .resumed(offset: Int64(position)) : .fromBeginning)
        var sent = 0
        while position < body.count {
            if let limit, sent >= limit { throw LocalModelDownloadError.transport("synthetic reset") }
            let end = min(position + 16_384, body.count)
            try sink(body.subdata(in: position..<end))
            sent += end - position
            position = end
        }
    }
}
