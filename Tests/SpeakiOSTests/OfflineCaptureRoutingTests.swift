#if os(iOS)
import SpeakCore
import Network
import XCTest

@testable import SpeakiOSLib

final class OfflineCaptureRoutingTests: XCTestCase {
    private let remoteModel = "deepgram/nova-3-streaming"

    func testKnownOfflineOrdinaryRemoteRouteUsesBoundedStrictLocalFallback() throws {
        let route = try XCTUnwrap(self.route(
            modelID: self.remoteModel,
            connectivity: .unavailable,
            capability: .available
        ))

        XCTAssertEqual(route.modelID, AppleLocalModels.legacySpeechModelID)
        XCTAssertTrue(route.requiresStrictOnDeviceRecognition)
        XCTAssertEqual(route.notice, OfflineCaptureRouting.fallbackNotice)
    }

    func testKnownOfflineRemoteRouteRefusesWhenLocalCapabilityIsNotReady() {
        for capability: AppleLocalRecognitionCapability in [.unavailable, .unknown] {
            XCTAssertEqual(
                self.decision(
                    modelID: self.remoteModel,
                    connectivity: .unavailable,
                    capability: capability
                ),
                .refuse(.localRecognitionUnavailable)
            )
        }
    }

    func testExplicitModelAndKeyboardProfileAreNeverSubstitutedOffline() {
        for binding: OfflineCaptureRequestBinding in [.explicitModel, .keyboardProfile] {
            XCTAssertEqual(
                self.decision(
                    modelID: self.remoteModel,
                    binding: binding,
                    connectivity: .unavailable,
                    capability: .available
                ),
                .refuse(.explicitRemoteModelUnavailable)
            )
        }
    }

    func testUnknownAndAvailablePathsKeepTheRemoteRouteUnchanged() throws {
        for connectivity: CaptureConnectivitySnapshot in [.unknown, .available] {
            let route = try XCTUnwrap(self.route(
                modelID: self.remoteModel,
                connectivity: connectivity,
                capability: .unknown
            ))
            XCTAssertEqual(route.modelID, self.remoteModel)
            XCTAssertFalse(route.requiresStrictOnDeviceRecognition)
            XCTAssertNil(route.notice)
        }
    }

    func testBatchAndInvalidModelsAreOutsideAutomaticFallback() throws {
        let batch = try XCTUnwrap(self.route(
            usesBatch: true,
            modelID: "openai/gpt-4o-mini-transcribe",
            connectivity: .unavailable,
            capability: .available
        ))
        let invalid = try XCTUnwrap(self.route(
            modelID: "not/a-real-model",
            connectivity: .unavailable,
            capability: .available
        ))

        XCTAssertEqual(batch.modelID, "openai/gpt-4o-mini-transcribe")
        XCTAssertFalse(batch.requiresStrictOnDeviceRecognition)
        XCTAssertEqual(invalid.modelID, "not/a-real-model")
        XCTAssertFalse(invalid.requiresStrictOnDeviceRecognition)
    }

    func testCatalogueLocalModelsStayLocalWithoutChangingTheirIdentity() throws {
        let legacy = try XCTUnwrap(self.route(
            modelID: AppleLocalModels.legacySpeechModelID,
            connectivity: .available,
            capability: .available
        ))
        let analyzer = try XCTUnwrap(self.route(
            modelID: AppleLocalModels.speechTranscriberModelID,
            connectivity: .unknown,
            capability: .unknown
        ))

        XCTAssertEqual(legacy.modelID, AppleLocalModels.legacySpeechModelID)
        XCTAssertTrue(legacy.requiresStrictOnDeviceRecognition)
        XCTAssertEqual(analyzer.modelID, AppleLocalModels.speechTranscriberModelID)
        XCTAssertTrue(analyzer.requiresStrictOnDeviceRecognition)
        XCTAssertNil(legacy.notice)
        XCTAssertNil(analyzer.notice)
    }

    func testSelectedLegacyLocalModelRefusesUnsupportedLocaleCapability() {
        XCTAssertEqual(
            self.decision(
                modelID: AppleLocalModels.legacySpeechModelID,
                connectivity: .available,
                capability: .unavailable
            ),
            .refuse(.localRecognitionUnavailable)
        )
    }

    func testAChangedPathDoesNotMutateTheAlreadySelectedRunRoute() throws {
        let selected = try XCTUnwrap(self.route(
            modelID: self.remoteModel,
            connectivity: .unavailable,
            capability: .available
        ))
        let later = try XCTUnwrap(self.route(
            modelID: self.remoteModel,
            connectivity: .available,
            capability: .available
        ))

        XCTAssertEqual(selected.modelID, AppleLocalModels.legacySpeechModelID)
        XCTAssertEqual(selected.notice, OfflineCaptureRouting.fallbackNotice)
        XCTAssertEqual(later.modelID, self.remoteModel)
    }
}

extension OfflineCaptureRoutingTests {
    @MainActor
    func testNetworkSnapshotStartsUnknownAndRejectsCancelledGenerationUpdates() {
        let state = CaptureNetworkSnapshotState()
        XCTAssertEqual(state.snapshot, .unknown)
        let first = state.restart()
        state.receive(.available, generation: first)
        XCTAssertEqual(state.snapshot, .available)

        let second = state.restart()
        XCTAssertEqual(state.snapshot, .unknown)
        state.receive(.unavailable, generation: first)
        XCTAssertEqual(state.snapshot, .unknown)
        state.receive(.unavailable, generation: second)
        XCTAssertEqual(state.snapshot, .unavailable)

        state.cancel()
        state.receive(.available, generation: second)
        XCTAssertEqual(state.snapshot, .unknown)
    }

    func testNetworkStatusMappingOnlyTreatsUnsatisfiedAsOffline() {
        XCTAssertEqual(CaptureNetworkPathMonitor.snapshot(for: .satisfied), .available)
        XCTAssertEqual(CaptureNetworkPathMonitor.snapshot(for: .unsatisfied), .unavailable)
        XCTAssertEqual(CaptureNetworkPathMonitor.snapshot(for: .requiresConnection), .unknown)
    }

    func testCapabilityIsOnlyProbedForLocalOrKnownOfflineLiveRoutes() {
        XCTAssertFalse(OfflineCaptureRouting.needsLocalCapability(
            usesBatch: false,
            requestedModelID: self.remoteModel,
            connectivity: .unknown
        ))
        XCTAssertTrue(OfflineCaptureRouting.needsLocalCapability(
            usesBatch: false,
            requestedModelID: self.remoteModel,
            connectivity: .unavailable
        ))
        XCTAssertTrue(OfflineCaptureRouting.needsLocalCapability(
            usesBatch: false,
            requestedModelID: AppleLocalModels.legacySpeechModelID,
            connectivity: .available
        ))
        XCTAssertFalse(OfflineCaptureRouting.needsLocalCapability(
            usesBatch: true,
            requestedModelID: self.remoteModel,
            connectivity: .unavailable
        ))
    }

    func testStrictRequestPolicyNeverFallsThroughToServerRecognition() throws {
        XCTAssertTrue(try AppleLegacyRecognitionRequestPolicy.requiresOnDeviceRecognition(
            strict: true,
            preferred: false,
            capability: .available
        ))
        for capability: AppleLocalRecognitionCapability in [.unavailable, .unknown] {
            XCTAssertThrowsError(try AppleLegacyRecognitionRequestPolicy.requiresOnDeviceRecognition(
                strict: true,
                preferred: true,
                capability: capability
            )) { error in
                guard case iOSTranscriptionError.offlineLocalRecognitionUnavailable = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        XCTAssertFalse(try AppleLegacyRecognitionRequestPolicy.requiresOnDeviceRecognition(
            strict: false,
            preferred: true,
            capability: .unavailable
        ))
    }

    private func decision(
        usesBatch: Bool = false,
        modelID: String,
        binding: OfflineCaptureRequestBinding = .ordinary,
        connectivity: CaptureConnectivitySnapshot,
        capability: AppleLocalRecognitionCapability
    ) -> OfflineCaptureRoutingDecision {
        OfflineCaptureRouting.decide(
            usesBatch: usesBatch,
            requestedModelID: modelID,
            binding: binding,
            connectivity: connectivity,
            localCapability: capability
        )
    }

    private func route(
        usesBatch: Bool = false,
        modelID: String,
        binding: OfflineCaptureRequestBinding = .ordinary,
        connectivity: CaptureConnectivitySnapshot,
        capability: AppleLocalRecognitionCapability
    ) -> OfflineCaptureRoute? {
        guard case .use(let route) = self.decision(
            usesBatch: usesBatch,
            modelID: modelID,
            binding: binding,
            connectivity: connectivity,
            capability: capability
        ) else { return nil }
        return route
    }
}
#endif
