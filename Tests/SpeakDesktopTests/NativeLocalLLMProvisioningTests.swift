import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

/// No fixture is a DLL/SO or native qualification receipt. Rejections occur
/// before library loading and these tests never execute llama.cpp.
final class NativeLocalLLMProvisioningTests: XCTestCase {
    func testMissingManifestIsAnExplicitRuntimeFailure() throws {
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try NativeLocalLLMProvisioning.read(directory: directory)) {
            guard let error = $0 as? LocalLLMError, case .runtimeUnavailable = error else {
                return XCTFail("Wrong error: \($0)")
            }
        }
    }

    func testWrongPinArchitectureLibraryPathAndMalformedDigestAreRejectedBeforeLoading() throws {
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest: [String: Any] = [
            "schemaVersion": 1, "commit": NativeLocalLLMProvisioning.abiCommit,
            "platform": NativeLocalLLMProvisioning.hostPlatform,
            "architecture": NativeLocalLLMProvisioning.hostArchitecture,
            "library": NativeLocalLLMProvisioning.libraryName, "sha256": String(repeating: "a", count: 64)
        ]
        for (key, value) in [
            ("commit", String(repeating: "0", count: 40)), ("architecture", "foreign"),
            ("library", "../llama.dll"), ("sha256", "not-a-digest")
        ] {
            var changed = manifest
            changed[key] = value
            try JSONSerialization.data(withJSONObject: changed).write(
                to: directory.appendingPathComponent("provisioning.json")
            )
            XCTAssertThrowsError(try NativeLocalLLMProvisioning.read(directory: directory))
        }
    }

    func testManifestBoundsAndSymlinkAreRejected() throws {
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("provisioning.json")
        try Data(repeating: 32, count: 16_385).write(to: manifest)
        XCTAssertThrowsError(try NativeLocalLLMProvisioning.read(directory: directory))
        #if !os(Windows)
        try FileManager.default.removeItem(at: manifest)
        let target = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: target)
        XCTAssertThrowsError(try NativeLocalLLMProvisioning.read(directory: directory))
        #endif
    }

    func testNativeInputAndTemperatureChecksDoNotAttemptToLoadALibrary() async throws {
        let model = try LocalLLMFixture.model()
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = NativeLocalLLMRuntime(directory: directory, digests: TestSHA256.provider)
        for (system, temperature) in [("Bad\0prompt", 0.0), (String(repeating: "x", count: 262_145), 0)] {
            do {
                _ = try await runtime.complete(
                    model: model, file: directory.appendingPathComponent("absent.gguf"),
                    systemPrompt: system, userPrompt: "User", temperature: temperature
                )
                XCTFail("Invalid input accepted")
            } catch let error as LocalLLMError {
                guard case .inference = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
        do {
            _ = try await runtime.complete(
                model: model, file: directory.appendingPathComponent("absent.gguf"),
                systemPrompt: "System", userPrompt: "User", temperature: .nan
            )
            XCTFail("NaN accepted")
        } catch let error as DesktopPostProcessingError {
            guard case .invalidTemperature = error else { return XCTFail("Wrong error") }
        }
    }
}
