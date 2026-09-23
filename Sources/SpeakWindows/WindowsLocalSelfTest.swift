import Foundation
import SpeakCore
import SpeakDesktop
import SpeakWindowsPlatform

/// Local model checks for `--self-test` and `--local-transcription-self-test`.
enum WindowsLocalSelfTest {
    /// Native pieces that need no network or model: CNG SHA-256 vectors, a
    /// complete download, resume, verification, tamper and removal cycle of
    /// the real installer on NTFS with a synthetic transport, then the
    /// controller's ownership of models it removes.
    static func run() async throws {
        let vectors = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        ]
        for (input, expected) in vectors {
            guard try WindowsSHA256Hasher.provider.sha256(of: Data(input.utf8)) == expected else {
                throw WindowsNativeError(message: "Windows CNG SHA-256 returned a wrong digest.")
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jsti-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let digest = try WindowsSHA256Hasher.provider.sha256(of: body)
        let item = LocalModelInstaller.Item(
            identifier: "local/whisperkit/tiny", displayName: "Self-test model",
            artifact: LocalModelFileArtifact(
                url: URL(string: "https://huggingface.co/self-test/resolve/0/ggml-self-test.bin")!,
                filename: "ggml-self-test.bin", byteCount: Int64(body.count), sha256: digest, license: "MIT",
                provenance: "synthetic"
            )
        )
        let transport = SelfTestTransport(body: body, dropAfter: 120_000)
        let installer = LocalModelInstaller(root: root, digests: WindowsSHA256Hasher.provider, transport: transport)
        do {
            _ = try await installer.install(item)
            throw WindowsNativeError(message: "An interrupted model download was reported as complete.")
        } catch is LocalModelDownloadError {}
        guard case .partial(let received, _) = installer.state(of: item), received >= 120_000 else {
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
        // Cancellation before recognition starts must not run the model.
        let cancelled = Task {
            try await runtime.transcribe(
                samples: [Float](repeating: 0.1, count: 16_000), modelFile: file, language: nil
            )
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw WindowsNativeError(message: "A cancelled local transcription completed.")
        } catch is CancellationError {}
        let timing = String(format: "%.2f s (audio %.2f s)", elapsed, result.duration)
        print("Local transcription self-test passed in \(timing).")
    }
}

/// Serves `body` like a range-capable HTTP server, optionally dropping the
/// connection after a byte count.
private final class SelfTestTransport: LocalModelDownloadTransport, @unchecked Sendable {
    let body: Data
    private let lock = NSLock()
    private var drop: Int?
    private(set) var offsets: [Int64] = []

    var dropAfter: Int? {
        get { lock.withLock { drop } }
        set { lock.withLock { drop = newValue } }
    }

    init(body: Data, dropAfter: Int?) {
        self.body = body
        self.drop = dropAfter
    }

    func download(
        _ request: LocalModelDownloadRequest, start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        let limit = lock.withLock { () -> Int? in
            offsets.append(request.resumeOffset)
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
