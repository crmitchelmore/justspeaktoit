import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform

extension LinuxProfileSessionProbe {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw DesktopHostError(message: "Recorded profile check: " + message) }
    }

    static func signal(_ name: String, in directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
    }

    static func wait(
        _ stage: String, seconds: Double = 45, condition: @Sendable () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int64(seconds * 1_000))
        while true {
            if try await condition() { return }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DesktopHostError(message: "Recorded profile stage timed out: " + stage)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func waitFor(_ name: String, in directory: URL) async throws {
        try await wait("parent signal " + name) {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    static func capture(_ expected: Target) throws -> LinuxInsertionTarget {
        guard let target = try LinuxX11.captureTargetChecked() else {
            throw DesktopHostError(message: "The recorded profile probe has no actual X11 target.")
        }
        try require(target.kind == .x11Window(expected.window) && target.processID == expected.processID
            && target.executablePath == expected.executable && target.processIdentity != nil,
            "the focused executable is not the exact owned fixture process")
        return target
    }

    static func copyModel(controller: LinuxAppController, fixture: Fixture) async throws {
        guard let spec = DesktopLocalTranscription.model(for: modelID, host: .linux) else {
            throw DesktopHostError(message: "The recorded profile probe's pinned tiny model is unavailable.")
        }
        let item = LocalModelInstaller.Item(spec)
        let source = LocalModelInstaller(
            root: URL(fileURLWithPath: fixture.modelRoot, isDirectory: true),
            digests: LinuxSHA256Hasher.provider, transport: LocalModelURLSessionTransport()
        )
        // The original cache is read-only. Only the isolated copy is handed to
        // verify(), whose documented mismatch cleanup may delete its own files.
        let file = try source.verifiedFile(for: item)
        try require(try source.digests.sha256(ofFileAt: file) == item.artifact.sha256,
                    "the existing tiny payload does not match its canonical pinned digest")
        let destination = await controller.localInstaller
        try LinuxFiles.preparePrivateDirectory(destination.root)
        try LinuxFiles.preparePrivateDirectory(destination.directory(for: item))
        for name in [item.artifact.filename, "install-receipt.json"] {
            let original = source.directory(for: item).appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
            try require(attributes[.type] as? FileAttributeType == .typeRegular,
                        "the model/receipt must be regular files, not symlinks")
            try FileManager.default.copyItem(at: original, to: destination.directory(for: item)
                .appendingPathComponent(name))
        }
        try destination.verify(item)
        await controller.setLocalUseGPU(false)
    }

    static func arm(
        _ controller: LinuxAppController, index: Int, fixture: Fixture, target: LinuxInsertionTarget
    ) async {
        await controller.shortcut(.init(
            input: .press, style: .pressToToggle, recognisedAt: ProcessInfo.processInfo.systemUptime,
            target: target, targetExecutablePath: target.executablePath, textOutput: Task { clipboard },
            modelIndex: index, deviceID: fixture.deviceID
        ))
    }

    static func verifyRecords(controller: LinuxAppController, count: Int) async throws {
        let records = try await controller.store.records()
        try require(records.count == count, "unexpected History record count")
        for record in records {
            try require(record.modelIdentifier == modelID && record.profileName == profileName
                && record.languageIdentifier == "en" && record.result != nil && record.failure == nil
                && record.postProcessingFailure == nil
                && record.postProcessingModelIdentifier == LocalPostProcessingModel.builtInRulesModelID,
                "History did not retain the actual local model/language/polish result")
            let text = (record.result?.text ?? "").lowercased().map { $0.isLetter ? $0 : " " }
            let words = String(text).split(separator: " ").joined(separator: " ")
            try require(words.contains("ask not what your country can do for you"),
                        "the actual local recognizer did not retain the pinned JFK phrase")
            let file = try await controller.store.audioURL(for: record)
            let duration = try NativePCM16WAVReader.canonicalDuration(at: file)
            try require(duration > 5 && duration < 30, "History did not retain the real recorded fixture PCM")
        }
        if let newest = records.max(by: { $0.createdAt < $1.createdAt }) {
            try await wait("native copied transcript") {
                try LinuxClipboard.read() == newest.displayText
            }
        }
    }
}
