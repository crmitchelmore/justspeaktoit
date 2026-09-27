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
        try checkDigestVectors()
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

    /// Runs `--local-transcription-self-test`, `--local-live-self-test` or
    /// `--local-post-processing-self-test` when requested; false otherwise.
    static func handle(_ arguments: [String]) async throws -> Bool {
        if arguments.contains("--local-live-self-test") {
            try await streamLive(arguments: arguments)
            return true
        }
        if arguments.contains("--local-post-processing-self-test") {
            try await polish(arguments: arguments)
            return true
        }
        guard arguments.contains("--local-transcription-self-test") else { return false }
        try await transcribe(arguments: arguments)
        return true
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    private static func modelInstaller() throws -> LocalModelInstaller {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["JSTI_LOCAL_MODEL_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("jsti-local-models")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LocalModelInstaller(
            root: root, digests: WindowsSHA256Hasher.provider, transport: LocalModelURLSessionTransport()
        )
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// The live qualification. `--local-live-self-test <wav> --expect <phrase>
    /// --model <local/streaming/whispercpp/...>` streams the WAV through the
    /// sliding-window client in 100 ms chunks at real-time pace on the CPU,
    /// requires text while it streams, the phrase in the final transcript and
    /// every decode to finish within the qualification bound.
    static func streamLive(arguments: [String]) async throws {
        guard let audio = value(after: "--local-live-self-test", in: arguments),
              let expected = value(after: "--expect", in: arguments) else {
            throw WindowsNativeError(message: "Usage: --local-live-self-test <wav> --expect <phrase> --model <id>")
        }
        let identifier = value(after: "--model", in: arguments) ?? "local/streaming/whispercpp/tiny"
        guard let spec = DesktopLocalTranscription.liveModel(for: identifier, host: .windows) else {
            throw WindowsNativeError(message: "\(identifier) is not a live-qualified Windows on-device model.")
        }
        let installer = try modelInstaller()
        let file = try await installer.install(.init(spec))
        try installer.verify(.init(spec))
        let allowGPU = ProcessInfo.processInfo.environment["JSTI_WHISPER_CPU_ONLY"] != "1"
        let runtime = try WindowsWhisperRuntime.open(allowGPU: allowGPU)
        let samples = try DesktopLocalAudio.read(URL(fileURLWithPath: audio), maximumBytes: 50_000_000).samples
        let client = DesktopLocalLiveClient(
            model: spec, modelFile: file, language: "en", recognizer: WindowsWhisperRecognizer(runtime: runtime)
        )
        let session = DesktopLiveSession(client: client)
        session.start()
        let started = ContinuousClock.now
        var interim = Set<String>()
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + 1_600)
            let pcm = samples[index..<end].map { Int16(max(-1, min(1, $0)) * 32_767) }
            session.sendAudio(pcm.withUnsafeBufferPointer { Data(buffer: $0) })
            index = end
            let text = session.snapshot().text
            if !text.isEmpty { interim.insert(text) }
            // Real-time pace: chunk n is due n * 100 ms after the start.
            try await Task.sleep(until: started + .milliseconds(index / 16), clock: .continuous)
        }
        let streamed = ContinuousClock.now - started
        let final = await session.finish()
        let finishing = ContinuousClock.now - started - streamed
        print("Runtime: \(runtime.description)")
        print("Hypotheses shown while streaming: \(interim.count)")
        print("Transcript: \(final.text)")
        print(String(format: "Decodes: %d, slowest %.2f s; stop to final transcript %.2f s",
                     client.decodeCount, client.slowestDecode,
                     Double(finishing.components.seconds) + Double(finishing.components.attoseconds) / 1e18))
        if let error = final.error { throw WindowsNativeError(message: "Local live transcription failed: \(error)") }
        guard !interim.isEmpty else { throw WindowsNativeError(message: "No text appeared while streaming.") }
        guard normalised(final.text).contains(normalised(expected)) else {
            throw WindowsNativeError(message: "Local live transcription did not contain the expected phrase.")
        }
        // Qualification bound: a decode slower than three steps means the
        // model cannot keep the displayed text near real time on this CPU.
        guard client.slowestDecode <= 3 else {
            throw WindowsNativeError(message: "A live decode took longer than the 3 s qualification bound.")
        }
        print("Local live transcription self-test passed.")
    }

    /// `--local-post-processing-self-test [--model <local/post-processing/...>]`:
    /// downloads (or reuses) the pinned GGUF model, loads the bundled llama.cpp
    /// beside whisper.cpp and polishes a transcript with a custom prompt as the
    /// system instruction; an empty transcript must stay empty without running
    /// the model, and a cancelled generation must not complete.
    static func polish(arguments: [String]) async throws {
        let identifier = value(after: "--model", in: arguments) ?? "local/post-processing/smollm2-360m-instruct-q4"
        guard let model = DesktopLocalPostProcessing.model(for: identifier, host: .windows) else {
            throw WindowsNativeError(message: "\(identifier) is not a Windows local post-processing model.")
        }
        let item = WindowsLocalModelEntry.language(model).item
        let installer = try modelInstaller()
        let file = try await installer.install(item)
        try installer.verify(item)
        let allowGPU = ProcessInfo.processInfo.environment["JSTI_WHISPER_CPU_ONLY"] != "1"
        // Whisper first, as the app does after a recording, so both share one ggml.
        let speech = try WindowsWhisperRuntime.open(allowGPU: allowGPU)
        let runtime = try WindowsLlamaRuntime.open(allowGPU: allowGPU)
        let generator = WindowsLlamaLanguageModel(runtime: runtime)
        let options = DesktopPostProcessing.Options(
            mode: .local, modelIdentifier: model.identifier,
            customPrompt: "You fix dictated text. Reply with the corrected sentence only.", temperature: 0
        )
        let raw = "um so the meeting is on tuesday at three pm in the main office"
        let started = Date()
        let outcome = try await DesktopPostProcessing.processLocally(
            rawText: raw, options: options, model: model, modelFile: file, languageModel: generator
        )
        let elapsed = Date().timeIntervalSince(started)
        print("Runtimes: \(speech.description) | \(runtime.description)")
        print("Polished: \(outcome.processedText)")
        guard outcome.systemPrompt?.hasPrefix(options.customPrompt ?? "") == true else {
            throw WindowsNativeError(message: "The custom prompt was not the system instruction.")
        }
        guard normalised(outcome.processedText).contains("tuesday") else {
            throw WindowsNativeError(message: "The local model's reply lost the transcript's content.")
        }
        let empty = try await DesktopPostProcessing.processLocally(
            rawText: " [BLANK_AUDIO] ", options: options, model: model, modelFile: file, languageModel: generator
        )
        guard empty.processedText.isEmpty else {
            throw WindowsNativeError(message: "An empty transcript did not stay empty.")
        }
        let cancelled = Task {
            try await runtime.generate(.init(
                systemPrompt: "Count.", userMessage: "Count to one thousand.", temperature: 0, maximumTokens: 512,
                modelFile: file
            ))
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw WindowsNativeError(message: "A cancelled generation completed.")
        } catch is CancellationError {}
        print(String(format: "Local post-processing self-test passed in %.2f s.", elapsed))
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
