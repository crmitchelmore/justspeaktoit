#if os(iOS) && DEBUG && targetEnvironment(simulator)
import SpeakCore
import UIKit
import XCTest
@testable import SpeakiOSLib

@MainActor
final class FocusRecordingServiceTests: XCTestCase {
    func testFocusHistoryOnlySuppressesEveryImmediateExternalLaneAcrossStopSurfaces() async throws {
        for route in 0..<3 {
            let harness = try DependencyHarness()
            defer { harness.cleanUp() }
            harness.focus = FocusCaptureOverride(destinationID: "historyOnly")
            harness.settings.autoPostProcess = true
            harness.defaults.set("Private Focus words", forKey: "simulatorValidationTranscript")
            let service = harness.makeService()
            try await service.startRecording(requiresLiveActivity: false)
            XCTAssertEqual(service.captureDestinationStatus,
                           HardwareTriggerDestination.historyOnly.displayName + " · Focus")
            harness.focus = FocusCaptureOverride(destinationID: "clipboard")
            harness.settings.hardwareTriggerDestination = .clipboardAndPostProcess
            switch route {
            case 0: _ = await service.stopRecording()
            case 1: _ = await service.stopRecording(selection: service.resolvedStopSelection())
            default: await service.finishCaptureAfterDisruption()
            }
            XCTAssertEqual(service.lastCompletedDestination?.origin, .focus)
            XCTAssertEqual(harness.history.items.map(\.transcription), ["Private Focus words"])
            XCTAssertNil(harness.keyboard.pendingOffer())
            XCTAssertTrue(harness.pasteboard.writes.isEmpty)
            XCTAssertTrue(harness.polishRequests.isEmpty)
            XCTAssertFalse(harness.activitySnippets.contains { $0.contains("Private Focus words") })
            XCTAssertEqual(harness.resultPreviews, [""])
            XCTAssertNotEqual(harness.defaults.string(forKey: "lastCompletedTranscript"), "Private Focus words")
            XCTAssertNotEqual(harness.defaults.string(forKey: "currentTranscriptText"), "Private Focus words")
        }
    }

    func testExplicitStopMayIntentionallyRedirectFrozenFocusAndRetainsItsOrigin() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.focus = FocusCaptureOverride(destinationID: "historyOnly")
        harness.defaults.set("Redirected words", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()
        try await service.startRecording(requiresLiveActivity: false)
        _ = await service.stopRecording(selection: service.resolvedStopSelection(explicit: .clipboard))
        XCTAssertEqual(service.lastCompletedDestination?.origin, .explicitStop)
        XCTAssertEqual(harness.pasteboard.writes, ["Redirected words"])
    }

    func testGlobalsAndFocusAreFrozenBeforeCredentialWait() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.settings.hardwareTriggerDestination = .historyOnly
        harness.settings.preferredLocaleIdentifier = "en_GB"
        harness.defaults.set("Frozen words", forKey: "simulatorValidationTranscript")
        let gate = DependencyKeyLoadGate(entered: expectation(description: "credentials entered"))
        let service = harness.makeService(ensureKeysLoaded: { await gate.wait() })
        let completed = expectation(description: "start completed")
        var failure: Error?
        let task = Task {
            do { try await service.startRecording(requiresLiveActivity: false) } catch { failure = error }
            completed.fulfill()
        }
        defer { gate.release(); task.cancel() }
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2) == .completed else {
            return XCTFail("Credential wait was not entered")
        }
        let frozen = try XCTUnwrap(service.effectiveConfiguration)
        harness.settings.hardwareTriggerDestination = .clipboard
        harness.settings.preferredLocaleIdentifier = "en_US"
        harness.settings.transcriptionMode = .batch
        harness.settings.batchTranscriptionModel = "deleted-model"
        harness.focus = FocusCaptureOverride(destinationID: "clipboard")
        gate.release()
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 2) == .completed else {
            return XCTFail("Start did not settle")
        }
        XCTAssertNil(failure)
        XCTAssertEqual(service.effectiveConfiguration, frozen)
        XCTAssertEqual(frozen.destinationOrigin, .global)
        XCTAssertEqual(frozen.languageIdentifier, "en_GB")
        XCTAssertFalse(frozen.usesBatch)
        XCTAssertEqual(service.resolvedStopDestination(), .historyOnly)
        _ = await service.stopRecording()
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
    }

    func testForegroundContinuationReusesOneSnapshotDespiteFocusChange() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.focus = FocusCaptureOverride(destinationID: "historyOnly")
        harness.defaults.set("Retry words", forKey: "simulatorValidationTranscript")
        harness.applicationState = .background
        harness.activityStartsSuccessfully = false
        let service = harness.makeService()
        let request = CaptureConfigurationRequest()
        do {
            try await service.startRecording(destination: nil, configurationRequest: request)
            XCTFail("First background attempt must need foreground continuation")
        } catch {
            guard case .liveActivityUnavailable = error as? iOSTranscriptionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let frozen = try XCTUnwrap(request.configuration)
        harness.focus = FocusCaptureOverride(destinationID: "clipboard")
        harness.applicationState = .active
        try await service.startRecording(destination: nil, configurationRequest: request)
        XCTAssertEqual(service.effectiveConfiguration, frozen)
        XCTAssertEqual(harness.focusReads, 1)
        _ = await service.stopRecording()
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
    }

    func testInvalidFocusModelIsRefusedButExplicitModelSupersedesOnlyThatField() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.focus = FocusCaptureOverride(destinationID: "historyOnly", modelID: "deleted-model")
        harness.defaults.set("Validated words", forKey: "simulatorValidationTranscript")
        let service = harness.makeService()
        do {
            try await service.startRecording(requiresLiveActivity: false)
            XCTFail("Invalid named Focus model must not fall back")
        } catch { XCTAssertEqual(error as? CaptureParameterFailure, .unknownModel) }
        XCTAssertFalse(service.isActive)
        XCTAssertTrue(harness.activityStarts.isEmpty)
        try await service.startRecording(
            requiresLiveActivity: false, parameters: CaptureRunParameters(modelID: AppleLocalModels.legacySpeechModelID)
        )
        XCTAssertEqual(service.effectiveConfiguration?.modelOrigin, .explicit)
        XCTAssertEqual(service.effectiveDestination?.origin, .focus)
        _ = await service.stopRecording()
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
    }

    func testNamedFocusModelMissingCredentialsAndOfflineLocalUnavailableRefuseWithoutFallback() async throws {
        for offlineLocal in [false, true] {
            let harness = try DependencyHarness()
            defer { harness.cleanUp() }
            harness.focus = FocusCaptureOverride(modelID: offlineLocal
                ? AppleLocalModels.legacySpeechModelID : "deepgram/nova-3-streaming")
            let service = harness.makeService(
                networkSnapshot: { offlineLocal ? .unavailable : .available }, capability: { _ in .unavailable }
            )
            var allocations = 0
            service.makeSession = { allocations += 1; return DependencySession() }
            do {
                try await service.startRecording(requiresLiveActivity: false)
                XCTFail("A named Focus model must not silently fall back")
            } catch {
                if offlineLocal {
                    guard case .offlineLocalRecognitionUnavailable = error as? iOSTranscriptionError else {
                        return XCTFail("Expected strict local recognition refusal")
                    }
                } else {
                    XCTAssertEqual(error as? CaptureParameterFailure, .modelUnavailable)
                }
            }
            XCTAssertEqual(allocations, 0)
            XCTAssertFalse(service.isActive)
        }
    }

    func testKeyboardProfileIgnoresFocusAndExplicitCaptureFieldsCompletely() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.focus = FocusCaptureOverride(destinationID: "invalid", modelID: "deleted-model")
        harness.defaults.set("Keyboard words", forKey: "simulatorValidationTranscript")
        let profile = KeyboardDictationProfileOption(
            id: "owned", displayName: "Owned", chipLabel: "Owned", route: .appHandoff,
            transcriptionMode: .streaming, transcriptionModelIdentifier: AppleLocalModels.legacySpeechModelID,
            languageIdentifier: "en_GB", postProcessingEnabled: false
        )
        let service = harness.makeService()
        try await service.startRecording(
            requiresLiveActivity: false, keyboardProfile: profile,
            parameters: CaptureRunParameters(modelID: "also-invalid"), destination: .historyOnly
        )
        XCTAssertEqual(harness.focusReads, 0)
        XCTAssertEqual(service.effectiveConfiguration?.modelID, profile.transcriptionModelIdentifier)
        XCTAssertEqual(service.effectiveConfiguration?.languageIdentifier, "en_GB")
        XCTAssertEqual(service.effectiveDestination?.origin, .keyboardProfile)
        _ = await service.stopRecording(selection: service.resolvedStopSelection(), keyboardDeliverySource: nil)
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
        XCTAssertNil(harness.keyboard.pendingOffer())
    }

    func testFocusAndGlobalsChangedDuringDrainCannotRedirectOwnedStop() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        harness.focus = FocusCaptureOverride(destinationID: "historyOnly")
        let service = harness.makeService()
        let gate = DependencyKeyLoadGate(entered: expectation(description: "drain entered"))
        let session = DependencySession()
        session.finish = {
            await gate.wait()
            return TranscriptionResult(
                text: "Drained private words", segments: [], confidence: nil, duration: 1,
                modelIdentifier: AppleLocalModels.legacySpeechModelID, cost: nil, rawPayload: nil, debugInfo: nil
            )
        }
        service.makeSession = { session }
        try await service.startRecording(requiresLiveActivity: false)
        let finished = expectation(description: "stop settled")
        let stop = Task { _ = await service.stopRecording(); finished.fulfill() }
        defer { gate.release(); stop.cancel() }
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2) == .completed else {
            return XCTFail("Drain was not entered")
        }
        harness.focus = .none
        harness.settings.hardwareTriggerDestination = .clipboardAndPostProcess
        gate.release()
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 2) == .completed else {
            return XCTFail("Drain did not settle")
        }
        XCTAssertEqual(service.lastCompletedDestination?.origin, .focus)
        XCTAssertTrue(harness.pasteboard.writes.isEmpty)
        XCTAssertNil(harness.keyboard.pendingOffer())
        XCTAssertTrue(harness.polishRequests.isEmpty)
    }

}

@MainActor
final class FocusCaptureCancellationTests: XCTestCase {
    func testCancelledParentDuringUncooperativeFocusLookupCannotAcceptConfigurationOrAllocate() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let gate = DependencyKeyLoadGate(entered: expectation(description: "Focus lookup entered"))
        harness.focusGate = gate
        harness.focus = FocusCaptureOverride(destinationID: "historyOnly")
        var keyReads = 0
        var allocations = 0
        let service = harness.makeService(ensureKeysLoaded: { keyReads += 1 })
        service.makeSession = { allocations += 1; return DependencySession() }
        let request = CaptureConfigurationRequest()
        let settled = expectation(description: "Cancelled Focus startup settled")
        var failure: Error?
        let task = Task {
            do {
                try await service.startRecording(requiresLiveActivity: false, destination: nil,
                                                 configurationRequest: request)
            } catch { failure = error }
            settled.fulfill()
        }
        defer { gate.release(); task.cancel() }
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2) == .completed else {
            return XCTFail("Focus lookup was not entered")
        }
        task.cancel()
        gate.release() // The injected lookup ignores cancellation until explicitly released.
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 2) == .completed else {
            return XCTFail("Cancelled Focus startup did not settle")
        }
        XCTAssertTrue(failure is CancellationError)
        XCTAssertNil(request.configuration)
        XCTAssertNil(service.effectiveConfiguration)
        XCTAssertEqual(keyReads, 0)
        XCTAssertEqual(allocations, 0)
        XCTAssertTrue(harness.activityStarts.isEmpty)
        XCTAssertFalse(harness.defaults.bool(forKey: "isRecording"))
        XCTAssertFalse(service.isActive)
    }

    func testCancelledParentDuringCredentialsCannotAllocateAfterUncooperativeWait() async throws {
        let harness = try DependencyHarness()
        defer { harness.cleanUp() }
        let gate = DependencyKeyLoadGate(entered: expectation(description: "Credential wait entered"))
        let service = harness.makeService(ensureKeysLoaded: { await gate.wait() })
        var allocations = 0
        service.makeSession = { allocations += 1; return DependencySession() }
        let settled = expectation(description: "Cancelled credential startup settled")
        var failure: Error?
        let task = Task {
            do { try await service.startRecording(requiresLiveActivity: false) } catch { failure = error }
            settled.fulfill()
        }
        defer { gate.release(); task.cancel() }
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2) == .completed else {
            return XCTFail("Credential wait was not entered")
        }
        task.cancel()
        gate.release()
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 2) == .completed else {
            return XCTFail("Cancelled credential startup did not settle")
        }
        XCTAssertTrue(failure is CancellationError)
        XCTAssertNil(service.effectiveConfiguration)
        XCTAssertEqual(allocations, 0)
        XCTAssertTrue(harness.activityStarts.isEmpty)
        XCTAssertFalse(harness.defaults.bool(forKey: "isRecording"))
        XCTAssertFalse(service.isActive)
    }

}
#endif
