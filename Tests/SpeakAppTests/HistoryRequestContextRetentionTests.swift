import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class HistoryRequestContextRetentionTests: XCTestCase {
    func testAdmissionARemainsFrozenAfterSettingsChangeFailureAndHistoryBuild() throws {
        try self.withSettings { settings in
            settings.transcriptionMode = .liveNative
            settings.liveTranscriptionModel = "deepgram/nova-3-streaming"
            settings.preferredLocaleIdentifier = "en"
            settings.textOutputMethod = .clipboardOnly
            let requested = MainManager.requestedDiagnosticContext(settings: settings)
            let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "local hotkey")
            session.diagnosticContext = self.diagnostic(request: requested)
            session.errors.append(HistoryError(phase: .transcription, message: "private failure"))
            settings.liveTranscriptionModel = "assemblyai/universal-streaming"
            settings.preferredLocaleIdentifier = "fr"
            settings.transcriptionMode = .batchRemote
            var fallbackCalls = 0
            for _ in 0..<2 {
                MainManager.attachFailureDiagnostics(to: session) {
                    fallbackCalls += 1
                    return self.diagnostic(request: MainManager.requestedDiagnosticContext(settings: settings))
                }
            }
            let saved = session.buildHistoryItem(finalText: nil)
            XCTAssertEqual(fallbackCalls, 0, "Failure must not read replacement settings for an admitted request")
            XCTAssertEqual(saved.id, session.id)
            XCTAssertEqual(saved.errors, session.errors)
            XCTAssertEqual(saved.diagnosticContext?.requestContext, requested)
            XCTAssertEqual(saved.diagnosticContext?.requestContext?.mode, .live)
            XCTAssertEqual(saved.diagnosticContext?.requestContext?.destination, .clipboard)
            XCTAssertEqual(saved.diagnosticContext?.requestContext?.model.identifier, "deepgram/nova-3-streaming")
            XCTAssertEqual(session.events.count, 1, "Repeated failure attachment remains idempotent")
            XCTAssertEqual(saved.toSyncable().id, saved.id)
            XCTAssertNil(HistoryItem.fromSyncable(saved.toSyncable()).diagnosticContext,
                         "This local context must not expand the existing CloudKit projection")
        }
    }

    func testLegacyFailureCannotInventRequestContextFromCurrentSettings() {
        let session = ActiveSession(gesture: .uiButton, hotKeyDescription: "local hotkey")
        let legacy = self.diagnostic(request: nil)
        var fallbackCalls = 0
        MainManager.attachFailureDiagnostics(to: session) {
            fallbackCalls += 1
            return legacy
        }
        XCTAssertEqual(fallbackCalls, 1)
        XCTAssertEqual(session.diagnosticContext, legacy)
        XCTAssertNil(session.buildHistoryItem(finalText: nil).diagnosticContext?.requestContext)
        MainManager.attachFailureDiagnostics(to: session) {
            XCTFail("Existing legacy metadata is also immutable at failure")
            return self.diagnostic(request: RequestDiagnosticContext(mode: .batch))
        }
        XCTAssertNil(session.diagnosticContext?.requestContext)
    }

    func testDelayedFailureBuildForACannotAcquireReplacementBContext() async {
        let first = ActiveSession(gesture: .uiButton, hotKeyDescription: "A")
        let second = ActiveSession(gesture: .uiButton, hotKeyDescription: "B")
        let requestA = RequestDiagnosticContext(model: .project("deepgram/nova-3-streaming"), mode: .live)
        let requestB = RequestDiagnosticContext(mode: .batch)
        first.diagnosticContext = self.diagnostic(request: requestA)
        second.diagnosticContext = self.diagnostic(request: requestB)
        let delayedBuild = Task { @MainActor in
            MainManager.attachFailureDiagnostics(to: first) {
                XCTFail("A frozen failed session must not fetch B")
                return self.diagnostic(request: requestB)
            }
            return first.buildHistoryItem(finalText: nil)
        }
        MainManager.attachFailureDiagnostics(to: second) { self.diagnostic(request: nil) }
        let savedA = await delayedBuild.value
        XCTAssertEqual(savedA.id, first.id)
        XCTAssertNotEqual(savedA.id, second.id)
        XCTAssertEqual(savedA.diagnosticContext?.requestContext, requestA)
        XCTAssertEqual(second.buildHistoryItem(finalText: nil).diagnosticContext?.requestContext, requestB)
    }

    func testCustomSettingsAndSecretCanariesNeverEnterSafeAdmissionValue() throws {
        try self.withSettings { settings in
            let canary = "PRIVATE_SECRET_user@example.com_/Users/name_token=secret"
            settings.transcriptionMode = .liveNative
            settings.liveTranscriptionModel = "custom/" + canary
            settings.postProcessingModel = "local/post-processing/" + canary
            settings.transcriptionKeywords = canary
            settings.assemblyAIKeyterms = canary
            let request = MainManager.requestedDiagnosticContext(settings: settings)
            let data = try JSONEncoder().encode(request)
            let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(encoded.contains(canary))
            XCTAssertEqual(request.model.classification, .customOrUnknown)
            XCTAssertNil(request.model.identifier)
            XCTAssertNil(request.postProcessingModel.identifier)
            XCTAssertNil(request.observedProvider)
            XCTAssertEqual(request.provenance, .admission)
            XCTAssertEqual(request.origin, .unknown, "No owner-supplied override receipt is available here")
        }
    }

    func testLocalAndBatchAdmissionDoNotInventLiveBudgetOrSmartOutputHandoff() throws {
        try self.withSettings { settings in
            settings.textOutputMethod = .smart
            settings.transcriptionMode = .localModel
            settings.localTranscriptionMode = .streaming
            let local = MainManager.requestedDiagnosticContext(settings: settings)
            XCTAssertEqual(local.mode, .local)
            XCTAssertNil(local.options.finalizationBudgetMilliseconds)
            XCTAssertEqual(local.destination, .unknown)
            XCTAssertNil(local.observedProvider)
            settings.transcriptionMode = .batchRemote
            let batch = MainManager.requestedDiagnosticContext(settings: settings)
            XCTAssertEqual(batch.mode, .batch)
            XCTAssertEqual(batch.options.streamingEnabled, false)
            XCTAssertNil(batch.options.finalizationBudgetMilliseconds)
            XCTAssertNil(batch.options.diarizationEnabled)
        }
    }

    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let host = try WireUpTestHost()
        defer {
            do { try host.tearDown() } catch { XCTFail("Could not remove owned diagnostic test storage") }
        }
        let settings = host.makeSettings()
        // Prevent the lazy getter from consulting the user's downloaded-model catalogue.
        settings.localStreamingModelSource = "local/streaming/diagnostic-fixture-uninstalled"
        try body(settings)
    }

    private func diagnostic(request: RequestDiagnosticContext?) -> HistoryDiagnosticContext {
        HistoryDiagnosticContext(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1", appBuild: "2", operatingSystem: "private OS", processIdentifier: 1,
            microphonePermission: "granted", inputDeviceName: "private device", providerLabel: "private label",
            latencyTier: "private tier", transcriptionMode: "private mode", transcriptionModel: "private model",
            postProcessingModel: "private polish", speedMode: "private speed", requestContext: request
        )
    }
}
