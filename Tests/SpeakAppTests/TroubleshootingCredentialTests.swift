import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class TroubleshootingCredentialTests: XCTestCase {
    func testPresentCredential_IsAvailable() async {
        let state = await ConfigurationTroubleshootingCheck.credentialState { "synthetic-test-value" }
        XCTAssertEqual(state, .available)
    }

    func testEmptyCredential_IsMissing() async {
        let state = await ConfigurationTroubleshootingCheck.credentialState { " \n\t" }
        XCTAssertEqual(state, .missing)
    }

    func testAbsentCredential_IsMissing() async {
        let state = await ConfigurationTroubleshootingCheck.credentialState {
            throw SecureAppStorageError.valueNotFound
        }
        XCTAssertEqual(state, .missing)
    }

    func testUnreadableCredential_DoesNotOfferDisableCleanup() async {
        for error in [SecureAppStorageError.permissionDenied, .unexpectedStatus(-1), .emptyIdentifier] {
            let state = await ConfigurationTroubleshootingCheck.credentialState { throw error }
            XCTAssertEqual(state, .unavailable)
            let findings = DesktopTroubleshooting.findings(.init(
                postProcessing: .init(enabled: true, model: "openrouter/test", credential: state),
                shortcutName: "Test shortcut", shortcutInstructions: "Test instructions", restoreClipboard: false
            ))
            let finding = findings.first { $0.id == DesktopTroubleshooting.Check.postProcessing.rawValue }
            XCTAssertEqual(finding?.severity, .warning)
            XCTAssertNil(finding?.fix)
        }
    }

    func testChangedModelDuringCredentialRead_IsNotDisabled() async throws {
        try await withSettings { settings, input in
            await self.requireFailure("Post-processing changed. Check again before applying this fix.") {
                try await ConfigurationTroubleshootingCheck().apply(
                    .disablePostProcessing, settings: settings, input: input
                ) {
                    settings.postProcessingModel = LocalPostProcessingModel.builtInRulesModelID
                    return ""
                }
            }
            XCTAssertTrue(settings.postProcessingEnabled)
            XCTAssertEqual(settings.postProcessingModel, LocalPostProcessingModel.builtInRulesModelID)
        }
    }

    func testNewCredential_IsNotDisabled() async throws {
        try await withSettings { settings, input in
            await self.requireFailure("A key is now available. Check again before disabling cleanup.") {
                try await ConfigurationTroubleshootingCheck().apply(
                    .disablePostProcessing, settings: settings, input: input
                ) { "new-synthetic-test-value" }
            }
            XCTAssertTrue(settings.postProcessingEnabled)
        }
    }

    func testUnreadableCredentialDuringFix_IsNotDisabled() async throws {
        try await withSettings { settings, input in
            await self.requireFailure("The saved credential could not be read. No setting was changed.") {
                try await ConfigurationTroubleshootingCheck().apply(
                    .disablePostProcessing, settings: settings, input: input
                ) { throw SecureAppStorageError.permissionDenied }
            }
            XCTAssertTrue(settings.postProcessingEnabled)
        }
    }

    func testMissingCredential_DisablesCleanupWithoutChangingModelOrPrompt() async throws {
        try await withSettings { settings, input in
            let model = settings.postProcessingModel
            let prompt = settings.postProcessingSystemPrompt
            try await ConfigurationTroubleshootingCheck().apply(
                .disablePostProcessing, settings: settings, input: input
            ) { throw SecureAppStorageError.valueNotFound }
            XCTAssertFalse(settings.postProcessingEnabled)
            XCTAssertEqual(settings.postProcessingModel, model)
            XCTAssertEqual(settings.postProcessingSystemPrompt, prompt)
        }
    }

    private func withSettings(
        _ operation: @MainActor (AppSettings, DesktopTroubleshooting.Input) async throws -> Void
    ) async throws {
        let name = "TroubleshootingCredentialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.postProcessingEnabled = true
        settings.postProcessingModel = "openai/gpt-4o-mini"
        settings.postProcessingSystemPrompt = "Synthetic formatting instruction."
        let input = DesktopTroubleshooting.Input(
            postProcessing: .init(
                enabled: true, model: ModelCatalog.resolvedPostProcessingModel(settings.postProcessingModel),
                credential: .missing
            ),
            shortcutName: "Test shortcut", shortcutInstructions: "Test instructions", restoreClipboard: false
        )
        try await operation(settings, input)
    }

    private func requireFailure(
        _ message: String, operation: @MainActor () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("The stale or unsafe fix should have been rejected.")
        } catch {
            XCTAssertEqual(error.localizedDescription, message)
        }
    }
}
