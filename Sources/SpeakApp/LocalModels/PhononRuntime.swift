#if !APP_STORE
import CryptoKit
import Foundation
import SpeakCore

/// An owned, pinned runtime and model cache. Never uses or removes the user's shared Hugging Face cache.
struct PhononRuntime: Sendable {
    static let version = "0.2.4"
    let root: URL

    private var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    private var python: URL { root.appendingPathComponent("venv/bin/python3") }
    private var cli: URL { root.appendingPathComponent("venv/bin/fermion") }
    /// Digest of the hash-locked requirements this venv was populated from.
    private var runtimeLock: URL { root.appendingPathComponent("venv/speak-runtime-lock.sha256") }
    private var receipt: URL { root.appendingPathComponent("ready.json") }
    private var modelCache: URL { root.appendingPathComponent("models", isDirectory: true) }
    private var hubCache: URL { root.appendingPathComponent("hf", isDirectory: true) }

    private struct Receipt: Codable {
        let runtimeVersion: String
        let modelPath: String
    }

    var isInstalled: Bool { (try? installedModel()) != nil }
    var hasDownload: Bool {
        [receipt, modelCache, hubCache].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func installedModel() throws -> URL {
        let record = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receipt))
        guard record.runtimeVersion == Self.version, hasLockedRuntime else {
            throw LocalModelError.notInstalled("Phonon-2 runtime")
        }
        return try validatedModelPath(record.modelPath)
    }

    /// Only a venv populated from the bundled hash-locked requirements is executed or reused.
    private var hasLockedRuntime: Bool {
        guard let expected = Self.lockDigest,
              FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.isExecutableFile(atPath: cli.path) else { return false }
        return (try? String(contentsOf: runtimeLock, encoding: .utf8)) == expected
    }

    func validatedModelPath(_ path: String) throws -> URL {
        let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let ownedRoot = modelCache.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard folder.path.hasPrefix(ownedRoot),
              ["model.fermion", "config.json", "packed_manifest.json"].allSatisfy({
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
              }) else { throw LocalModelError.missingManagedModelFolder }
        return folder
    }

    func install() async throws {
        guard PhononLocalModels.isSupportedOnCurrentPlatform else {
            throw LocalProcessError.failed("Phonon-2 requires the direct-download app on Apple silicon.")
        }
        if isInstalled { return }
        guard let requirements = Self.requirementsURL, let lockDigest = Self.lockDigest else {
            throw LocalProcessError.failed("The bundled Phonon runtime requirements are missing.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !hasLockedRuntime {
            // pip does not re-check hashes of packages already present, so never reuse an unverified venv.
            if FileManager.default.fileExists(atPath: venv.path) {
                try FileManager.default.removeItem(at: venv)
            }
            let bootstrap = try await bootstrapPython()
            _ = try await LocalProcessRunner.run(
                executableURL: bootstrap, arguments: ["-m", "venv", venv.path],
                timeout: LocalProcessRunner.setupTimeout
            )
            _ = try await LocalProcessRunner.run(
                executableURL: python, arguments: Self.pipInstallArguments(requirements: requirements.path),
                environment: Self.pipEnvironment, timeout: LocalProcessRunner.setupTimeout
            )
            try Task.checkCancellation()
            try Data(lockDigest.utf8).write(to: runtimeLock, options: .atomic)
        }
        // 0.2.4 still requires an audio argument even with --download-only; it does not read this path.
        let path = try await run(
            ["transcribe", PhononLocalModels.phonon2.modelName, "unused.wav", "--download-only"],
            offline: false, timeout: LocalProcessRunner.setupTimeout
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = try validatedModelPath(path)
        // Check the decoder, not just a successful pip install or download. No microphone is accessed.
        let silence = root.appendingPathComponent("install-probe.wav")
        defer { try? FileManager.default.removeItem(at: silence) }
        _ = try await LocalProcessRunner.run(
            executableURL: python,
            arguments: ["-c", "import wave,sys; w=wave.open(sys.argv[1],'wb'); "
                + "w.setparams((1,2,16000,0,'NONE','NONE')); w.writeframes(bytes(32000)); w.close()", silence.path],
            timeout: LocalProcessRunner.probeTimeout
        )
        let output = try await run(
            ["transcribe", folder.path, silence.path, "--json"], offline: true,
            timeout: LocalProcessRunner.inferenceTimeout
        )
        _ = try Self.decode(output)
        try Task.checkCancellation()
        let record = Receipt(runtimeVersion: Self.version, modelPath: folder.path)
        try JSONEncoder().encode(record).write(to: receipt, options: .atomic)
    }

    /// The release app (Tuist/Xcode) ships the pinned list in its main bundle; `swift build` uses the module bundle.
    static var requirementsURL: URL? {
        if let url = Bundle.main.url(forResource: "phonon-requirements", withExtension: "txt") {
            return url
        }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "phonon-requirements", withExtension: "txt")
        #else
        return nil
        #endif
    }

    /// SHA-256 of the bundled lock, recorded beside the venv it produced.
    static let lockDigest: String? = requirementsURL
        .flatMap { try? Data(contentsOf: $0) }
        .map { data in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Every wheel must match a hash in the bundled lock. Dependencies come only from that lock,
    /// only from PyPI, and user, global or environment pip configuration is ignored.
    static func pipInstallArguments(requirements: String) -> [String] {
        ["-m", "pip", "install", "--isolated", "--no-input", "--disable-pip-version-check",
         "--require-hashes", "--no-deps", "--only-binary=:all:",
         "--index-url", "https://pypi.org/simple/", "-r", requirements]
    }

    /// `--isolated` skips user config and PIP_* variables; this also skips global and site config files.
    static let pipEnvironment = ["PIP_CONFIG_FILE": "/dev/null"]

    func deleteModel() throws {
        // Retain the installed runtime for reuse; only these exact owned paths may be removed.
        for url in [receipt, modelCache, hubCache] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func transcribe(_ audio: URL, language: String?) async throws -> TranscriptionResult {
        try Self.validateLanguage(language)
        let folder = try installedModel()
        let converted = FileManager.default.temporaryDirectory.appendingPathComponent("phonon-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: converted) }
        // libsndfile cannot read the app's AAC/M4A recordings. Core Audio decodes them locally first.
        _ = try await LocalProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: ["-f", "WAVE", "-d", "LEI16", "-r", "16000", "-c", "1", audio.path, converted.path],
            timeout: LocalProcessRunner.inferenceTimeout
        )
        let output = try await run(
            ["transcribe", folder.path, converted.path, "--json"], offline: true,
            timeout: LocalProcessRunner.inferenceTimeout
        )
        try Task.checkCancellation()
        return try Self.decode(output)
    }

    private func run(_ arguments: [String], offline: Bool, timeout: TimeInterval) async throws -> String {
        var environment = [
            "FERMION_CACHE_DIR": modelCache.path, "HF_HOME": hubCache.path,
            "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1"
        ]
        if offline {
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
        }
        return try await LocalProcessRunner.run(
            executableURL: cli, arguments: arguments, environment: environment, timeout: timeout
        )
    }

    private func bootstrapPython() async throws -> URL {
        let names = ["python3.13", "python3.12", "python3.11", "python3"]
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin",
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        for path in prefixes.flatMap({ prefix in names.map { "\(prefix)/\($0)" } }) {
            let candidate = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let probe = try? await LocalProcessRunner.run(
                executableURL: candidate,
                arguments: ["-c", "import sys; assert (3,11) <= sys.version_info[:2] <= (3,13)"],
                timeout: LocalProcessRunner.probeTimeout
            )
            try Task.checkCancellation()
            if probe != nil { return candidate }
        }
        throw LocalProcessError.failed("Install Python 3.11–3.13, then download Phonon-2 again.")
    }

    static func validateLanguage(_ language: String?) throws {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard value.isEmpty || value == "auto" || value == "english" || value == "en"
            || value.hasPrefix("en-") || value.hasPrefix("en_") else {
            throw LocalProcessError.failed("Phonon-2 supports English. Choose WhisperKit for other languages.")
        }
    }

    static func decode(_ output: String) throws -> TranscriptionResult {
        let response = try JSONDecoder().decode(Response.self, from: Data(output.utf8))
        guard !response.truncated else {
            throw LocalProcessError.failed("Phonon-2 returned an incomplete transcript. Try a shorter recording.")
        }
        let duration = response.duration_seconds
        guard duration.isFinite, duration >= 0 else {
            throw LocalProcessError.failed("Phonon-2 returned an invalid audio duration.")
        }
        // The pinned CLI derives both from window sample offsets with the same rounding, so valid
        // output always satisfies 0 <= start <= end <= duration.
        guard response.segments.allSatisfy({ segment in
            segment.start.isFinite && segment.end.isFinite
                && segment.start >= 0 && segment.start <= segment.end && segment.end <= duration
        }) else {
            throw LocalProcessError.failed("Phonon-2 returned invalid segment timing.")
        }
        return TranscriptionResult(
            text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: response.segments.map {
                TranscriptionSegment(startTime: $0.start, endTime: $0.end, text: $0.text)
            },
            confidence: nil, duration: response.duration_seconds, modelIdentifier: PhononLocalModels.phonon2.id,
            cost: nil, rawPayload: nil, debugInfo: nil
        )
    }

    private struct Response: Decodable {
        let text: String
        // Match the pinned CLI's JSON schema.
        // swiftlint:disable:next identifier_name
        let duration_seconds: Double
        let truncated: Bool
        let segments: [Segment]
    }

    private struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }
}
#endif
