import Foundation
@testable import SpeakCore
import XCTest

final class ProductAnalyticsTests: XCTestCase {
    func testUnknownConsent_SendsNothingAndDoesNotCreateIdentity() async throws {
        let fixture = try Fixture()
        try await fixture.controller.capture(.appActiveDaily)
        let payloads = await fixture.sink.payloads
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertNil(try fixture.store.loadInstallationID())
    }

    func testOptedOutConsent_SendsNothing() async throws {
        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedOut)
        try await fixture.controller.capture(.appActiveDaily)
        let payloads = await fixture.sink.payloads
        XCTAssertTrue(payloads.isEmpty)
    }

    func testOptIn_CapturesOnlyTypedAllowlistedProperties() async throws {
        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedIn)
        try await fixture.controller.capture(.firstTranscriptionSucceeded(
            provider: .deepgram,
            engine: .cloud,
            daysSinceInstall: .twoToSeven
        ))
        let payloads = await fixture.sink.payloads
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.event, "first_transcription_succeeded")
        XCTAssertEqual(payload.properties["provider_type"], "deepgram")
        XCTAssertEqual(payload.properties["engine_type"], "cloud")
        XCTAssertEqual(payload.properties["days_since_install_bucket"], "2-7")
        XCTAssertEqual(Set(payload.properties.keys), Self.allowedFirstSuccessKeys)
    }

    func testOptOut_PurgesQueueDeletesIdentityAndClosesSink() async throws {
        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedIn)
        try await fixture.controller.capture(.appActiveDaily)
        XCTAssertNotNil(try fixture.store.loadInstallationID())
        try await fixture.controller.setConsent(.optedOut)
        XCTAssertNil(try fixture.store.loadInstallationID())
        let purgeCount = await fixture.sink.purgeCount
        let closeCount = await fixture.sink.closeCount
        XCTAssertEqual(purgeCount, 1)
        XCTAssertEqual(closeCount, 1)
    }

    func testForceDisabledKillSwitch_OverridesOptIn() async throws {
        let fixture = try Fixture(forceDisabled: true)
        try await fixture.controller.setConsent(.optedIn)
        try await fixture.controller.capture(.appActiveDaily)
        let payloads = await fixture.sink.payloads
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertNil(try fixture.store.loadInstallationID())
    }

    func testPreview_UsesTheSameAllowlistedPayloadEncoder() async throws {
        let fixture = try Fixture()
        let data = try await fixture.controller.preview(.onboardingStarted(entryPoint: .freshInstall))
        let payload = try JSONDecoder().decode(ProductAnalyticsPayload.self, from: data)
        XCTAssertEqual(payload.event, "onboarding_started")
        XCTAssertEqual(payload.properties["entry_point"], "fresh_install")
    }

    func testDetailedTranscriptionEvent_BucketsRawMeasurementsLocally() async throws {
        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedIn)
        let dimensions = AnalyticsTranscriptionDimensions(
            mode: .live,
            engine: .cloud,
            provider: .deepgram,
            modelFamily: "nova-3",
            languageCode: "en-GB",
            trigger: .hotkey
        )
        try await fixture.controller.capture(.transcriptionCompleted(
            dimensions,
            duration: .fifteenToSixtySeconds,
            wordCount: .fiftyOneToTwoHundred,
            latency: .milliseconds250ToOneSecond,
            output: .paste
        ))

        let payloads = await fixture.sink.payloads
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.properties["duration_bucket"], "15-60s")
        XCTAssertEqual(payload.properties["word_count_bucket"], "51-200")
        XCTAssertEqual(payload.properties["latency_bucket"], "250ms-1s")
        XCTAssertNil(payload.properties["transcript"])
        XCTAssertNil(payload.properties["duration_ms"])
        XCTAssertNil(payload.properties["word_count"])
    }

    func testAnonymousCounter_NeverReceivesInstallationIdentity() async throws {
        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedIn)
        try await fixture.controller.capture(.correctionApplied(rulesMatched: .twoToFive))

        let payloads = await fixture.sink.payloads
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.privacyClass, .anonymousCounter)
        XCTAssertNil(payload.distinctID)
        XCTAssertNil(try fixture.store.loadInstallationID())
    }

    func testUnboundedModelFamily_FallsBackWithoutLeakingContent() {
        let dimensions = AnalyticsTranscriptionDimensions(
            mode: .batch,
            engine: .onDevice,
            provider: .local,
            modelFamily: "private model name with spaces /Users/chris/model",
            languageCode: "not a language code 123",
            trigger: .menuBar
        )
        XCTAssertEqual(dimensions.modelFamily, "other")
        XCTAssertEqual(dimensions.languageCode, "other")
    }

    func testOptInPersistenceFailure_LeavesCollectionDisabled() async throws {
        let store = StubStore()
        store.saveConsentError = StubError()
        let sink = SpySink()
        let controller = try Self.makeController(sink: sink, store: store)

        do {
            try await controller.setConsent(.optedIn)
            XCTFail("Expected the failed consent write to propagate")
        } catch is StubError {}

        let state = await controller.consentState()
        XCTAssertEqual(state, .unknown)
        try await controller.capture(.appActiveDaily)
        let payloads = await sink.payloads
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertNil(store.installationID)
    }

    func testOptOutPurgeFailure_StillDeletesIdentityAndClosesSink() async throws {
        let store = StubStore()
        store.consent = .optedIn
        store.installationID = UUID()
        let sink = SpySink(purgeError: StubError())
        let controller = try Self.makeController(sink: sink, store: store)

        do {
            try await controller.setConsent(.optedOut)
            XCTFail("Expected the failed purge to propagate")
        } catch is StubError {}

        let state = await controller.consentState()
        XCTAssertEqual(state, .optedOut)
        XCTAssertEqual(store.consent, .optedOut)
        XCTAssertNil(store.installationID)
        let closeCount = await sink.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testOptOutIdentityDeletionFailure_StillPurgesAndClosesSink() async throws {
        let store = StubStore()
        store.consent = .optedIn
        store.deleteInstallationIDError = StubError()
        let sink = SpySink()
        let controller = try Self.makeController(sink: sink, store: store)

        do {
            try await controller.setConsent(.optedOut)
            XCTFail("Expected the failed identity deletion to propagate")
        } catch is StubError {}

        let state = await controller.consentState()
        XCTAssertEqual(state, .optedOut)
        let purgeCount = await sink.purgeCount
        let closeCount = await sink.closeCount
        XCTAssertEqual(purgeCount, 1)
        XCTAssertEqual(closeCount, 1)
        try await controller.capture(.appActiveDaily)
        let payloads = await sink.payloads
        XCTAssertTrue(payloads.isEmpty)
    }

    private static let allowedFirstSuccessKeys: Set<String> = [
        "provider_type", "engine_type", "days_since_install_bucket", "platform", "app_version", "build",
        "os_major_minor", "distribution_channel", "locale_language_code", "architecture", "analytics_schema_version"
    ]
}

private extension ProductAnalyticsTests {
    static let context = ProductAnalyticsContext(
        platform: .macOS,
        appVersion: "1.2.3",
        build: "42",
        osMajorMinor: "15.6",
        distributionChannel: .development,
        localeLanguageCode: "en",
        architecture: "arm64"
    )

    static func makeController(
        sink: any ProductAnalyticsSink,
        store: any ProductAnalyticsStateStore,
        forceDisabled: Bool = false
    ) throws -> ProductAnalyticsController {
        try ProductAnalyticsController(
            context: context,
            sink: sink,
            stateStore: store,
            forceDisabled: { forceDisabled }
        )
    }

    struct StubError: Error {}

    final class StubStore: ProductAnalyticsStateStore, @unchecked Sendable {
        var consent: AnalyticsConsentState = .unknown
        var installationID: UUID?
        var saveConsentError: Error?
        var deleteInstallationIDError: Error?

        func loadConsent() throws -> AnalyticsConsentState { consent }

        func saveConsent(_ consent: AnalyticsConsentState) throws {
            if let saveConsentError { throw saveConsentError }
            self.consent = consent
        }

        func loadInstallationID() throws -> UUID? { installationID }
        func saveInstallationID(_ id: UUID) throws { installationID = id }

        func deleteInstallationID() throws {
            if let deleteInstallationIDError { throw deleteInstallationIDError }
            installationID = nil
        }
    }

    struct Fixture {
        let sink: SpySink
        let store: FileProductAnalyticsStateStore
        let controller: ProductAnalyticsController

        init(forceDisabled: Bool = false) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            store = FileProductAnalyticsStateStore(fileURL: directory.appendingPathComponent("analytics.json"))
            sink = SpySink()
            controller = try ProductAnalyticsTests.makeController(
                sink: sink,
                store: store,
                forceDisabled: forceDisabled
            )
        }
    }

    actor SpySink: ProductAnalyticsSink {
        var payloads: [ProductAnalyticsPayload] = []
        var purgeCount = 0
        var closeCount = 0
        private let purgeError: Error?

        init(purgeError: Error? = nil) { self.purgeError = purgeError }

        func capture(_ payload: ProductAnalyticsPayload) async throws { payloads.append(payload) }

        func purge() async throws {
            purgeCount += 1
            payloads.removeAll()
            if let purgeError { throw purgeError }
        }

        func close() async { closeCount += 1 }
    }
}
