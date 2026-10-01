#if !APP_STORE
import Foundation
import SpeakCore
@testable import SpeakApp
import XCTest

final class PhononRuntimeTests: XCTestCase {
    func testDecodePreservesTextTimingAndLocalIdentity() throws {
        let result = try PhononRuntime.decode("""
        {"text":" Hello, Mac. ","duration_seconds":3.5,"truncated":false,
         "segments":[{"start":0,"end":3.5,"text":"Hello, Mac."}]}
        """)
        XCTAssertEqual(result.text, "Hello, Mac.")
        XCTAssertEqual(result.modelIdentifier, PhononLocalModels.phonon2.id)
        XCTAssertEqual(result.duration, 3.5)
        XCTAssertEqual(result.segments.first?.endTime, 3.5)
    }

    func testSilenceRemainsEmptyAndIncompleteOutputFails() throws {
        XCTAssertTrue(try PhononRuntime.decode("""
        {"text":"","duration_seconds":1,"truncated":false,"segments":[]}
        """).text.isEmpty)
        XCTAssertThrowsError(try PhononRuntime.decode("""
        {"text":"partial","duration_seconds":1,"truncated":true,"segments":[]}
        """))
        XCTAssertThrowsError(try PhononRuntime.decode("not JSON"))
    }

    func testMalformedSegmentTimingFails() {
        for segment in [#"{"start":-0.1,"end":1,"text":"a"}"#, #"{"start":1.5,"end":1,"text":"a"}"#,
                        #"{"start":0,"end":2.5,"text":"a"}"#] {
            XCTAssertThrowsError(try PhononRuntime.decode("""
            {"text":"a","duration_seconds":2,"truncated":false,"segments":[\(segment)]}
            """), segment)
        }
        XCTAssertNoThrow(try PhononRuntime.decode("""
        {"text":"a b","duration_seconds":2,"truncated":false,
         "segments":[{"start":0,"end":1,"text":"a"},{"start":1,"end":2,"text":"b"}]}
        """))
    }

    func testBundledRequirementsPinEveryPackageByHash() throws {
        let url = try XCTUnwrap(PhononRuntime.requirementsURL, "phonon-requirements.txt must be bundled")
        let requirements = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\\\n", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertTrue(requirements.contains { $0.hasPrefix("fermion-research==\(PhononRuntime.version) ") })
        for requirement in requirements {
            XCTAssertTrue(requirement.contains("=="), requirement)
            XCTAssertTrue(requirement.contains("--hash=sha256:"), requirement)
        }
        XCTAssertEqual(PhononRuntime.lockDigest?.count, 64)
    }

    func testPipInstallIsHashLockedAndIgnoresUserConfiguration() {
        let arguments = PhononRuntime.pipInstallArguments(requirements: "/lock.txt")
        for flag in ["--isolated", "--require-hashes", "--no-deps", "--only-binary=:all:"] {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        XCTAssertEqual(arguments.suffix(4), ["--index-url", "https://pypi.org/simple/", "-r", "/lock.txt"])
        XCTAssertEqual(PhononRuntime.pipEnvironment["PIP_CONFIG_FILE"], "/dev/null")
    }

    func testLanguageHintsRejectUnsupportedLanguages() throws {
        for language in [nil, "", "auto", "en", "en-GB", "en_US", "English"] {
            XCTAssertNoThrow(try PhononRuntime.validateLanguage(language))
        }
        XCTAssertThrowsError(try PhononRuntime.validateLanguage("fr"))
    }

    func testMissingOrUnownedModelsCannotBecomeInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = PhononRuntime(root: root)
        XCTAssertFalse(runtime.isInstalled)
        XCTAssertFalse(runtime.hasDownload)
        XCTAssertThrowsError(try runtime.validatedModelPath("/tmp/shared-model"))
        XCTAssertThrowsError(try runtime.validatedModelPath(root.appendingPathComponent("models/missing").path))
    }

    func testDeletionRemovesOwnedDownloadsButRetainsRuntimeAndNeighbours() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Phonon/models", "Phonon/hf", "Phonon/venv", "other-model"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        try Data("partial".utf8).write(to: root.appendingPathComponent("Phonon/models/partial"))
        let runtime = PhononRuntime(root: root.appendingPathComponent("Phonon"))
        XCTAssertTrue(runtime.hasDownload)
        try runtime.deleteModel()
        XCTAssertFalse(runtime.hasDownload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Phonon/venv").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("other-model").path))
        XCTAssertNoThrow(try runtime.deleteModel())
    }

    /// Opt in with an isolated runtime root and a generated fixture; never access the microphone or personal audio.
    func testRealOfflineRuntime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["PHONON_TEST_ROOT"], let audio = environment["PHONON_TEST_AUDIO"] else {
            throw XCTSkip("Set PHONON_TEST_ROOT and PHONON_TEST_AUDIO to verify the real runtime.")
        }
        let runtime = PhononRuntime(root: URL(fileURLWithPath: root))
        try await runtime.install()
        XCTAssertTrue(runtime.isInstalled)
        let result = try await runtime.transcribe(URL(fileURLWithPath: audio), language: "en-GB")
        XCTAssertTrue(result.text.contains("three apples and a cup of tea"), result.text)
        let silence = URL(fileURLWithPath: root).appendingPathComponent("silence.wav")
        let empty = try await runtime.transcribe(silence, language: nil)
        XCTAssertTrue(empty.text.isEmpty, empty.text)
        do {
            _ = try await runtime.transcribe(URL(fileURLWithPath: "/missing/audio.m4a"), language: nil)
            XCTFail("Missing audio must fail")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
}
#endif
