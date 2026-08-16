// Consent, lifecycle and payload privacy flows share fixtures whose behaviour is easier to audit in one file.
// swiftlint:disable file_length
import Foundation
@testable import SpeakCore
import XCTest

// swiftlint:disable:next type_body_length
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
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(payload["properties"] as? [String: String])
        XCTAssertEqual(payload["event"] as? String, "onboarding_started")
        XCTAssertEqual(properties["entry_point"], "fresh_install")
    }

    func testDetailedTranscriptionEvent_BucketsRawMeasurementsLocally() async throws {
        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedIn)
        let dimensions = AnalyticsTranscriptionDimensions(
            mode: .live,
            engine: .cloud,
            provider: .deepgram,
            modelFamily: .nova,
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

    func testUnboundedLanguageCode_FallsBackWithoutLeakingContent() {
        let dimensions = AnalyticsTranscriptionDimensions(
            mode: .batch,
            engine: .onDevice,
            provider: .local,
            modelFamily: .other,
            languageCode: "not a language code 123",
            trigger: .menuBar
        )
        XCTAssertEqual(dimensions.modelFamily, .other)
        XCTAssertEqual(dimensions.languageCode, "other")

        let shortASCII = AnalyticsTranscriptionDimensions(
            mode: .batch,
            engine: .onDevice,
            provider: .local,
            modelFamily: .other,
            languageCode: "mypassword",
            trigger: .menuBar
        )
        XCTAssertEqual(shortASCII.languageCode, "other")
    }

    func testGlobalContext_RejectsArbitraryShortASCII() {
        let input = "mypassword"
        let context = ProductAnalyticsContext(
            platform: .macOS,
            appVersion: input,
            build: input,
            osMajorMinor: input,
            distributionChannel: .development,
            localeLanguageCode: input,
            architecture: input
        )
        let payload = ProductAnalyticsPayload(event: .appActiveDaily, context: context, distinctID: UUID())

        XCTAssertEqual(context.appVersion, "other")
        XCTAssertEqual(context.build, "other")
        XCTAssertEqual(context.osMajorMinor, "other")
        XCTAssertEqual(context.localeLanguageCode, "other")
        XCTAssertEqual(context.architecture, "other")
        XCTAssertFalse(payload.properties.values.contains(input))
    }

    func testAnonymousPreview_DropsCallerSuppliedIdentity() async throws {
        let fixture = try Fixture()
        let data = try await fixture.controller.preview(.correctionApplied(rulesMatched: .one))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(payload["distinctID"])
        XCTAssertEqual(payload["privacyClass"] as? String, AnalyticsPrivacyClass.anonymousCounter.rawValue)
    }

    func testOptOutThenOptIn_ReopensTerminalSinkBeforeCapture() async throws {
        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedIn)
        try await fixture.controller.setConsent(.optedOut)
        try await fixture.controller.setConsent(.optedIn)
        try await fixture.controller.capture(.appActiveDaily)

        let payloads = await fixture.sink.payloads
        let reopenCount = await fixture.sink.reopenCount
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(reopenCount, 2)
    }

    func testKillSwitchAfterCapture_PurgesClosesAndDeletesIdentity() async throws {
        let store = StubStore()
        let sink = SpySink()
        let forceDisabled = LockedFlag(false)
        let controller = try Self.makeController(sink: sink, store: store) { forceDisabled.value }
        try await controller.setConsent(.optedIn)
        try await controller.capture(.appActiveDaily)
        XCTAssertNotNil(store.installationID)

        forceDisabled.value = true
        try await controller.capture(.appActiveDaily)

        let payloads = await sink.payloads
        let closeCount = await sink.closeCount
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertNil(store.installationID)
        XCTAssertEqual(closeCount, 1)
    }

    func testCurrentWatchAndXAIModels_HaveTypedAnalyticsDimensions() {
        let dimensions = AnalyticsTranscriptionDimensions(
            mode: .live,
            engine: .cloud,
            provider: .xAI,
            modelFamily: .grok,
            languageCode: "en_GB",
            trigger: .watch
        )

        XCTAssertEqual(dimensions.properties["provider_type"], "xai")
        XCTAssertEqual(dimensions.properties["model_family"], "grok")
        XCTAssertEqual(dimensions.properties["language_code"], "en-gb")
        XCTAssertEqual(dimensions.properties["trigger"], "watch")
    }

    func testLiveProviderCatalogue_MapsEveryProviderToTypedAnalytics() {
        let mapped = LiveTranscriptionProviderID.allCases.map { AnalyticsProviderType(liveProvider: $0) }

        XCTAssertEqual(mapped.count, LiveTranscriptionProviderID.allCases.count)
        XCTAssertFalse(mapped.contains(.other))
    }

    /// A transcript is not representable as a model family: the type is a closed enum, and the only
    /// way a caller can turn arbitrary text into one is `init(rawValue:)`, which rejects it. This is
    /// the regression guard for the previous `String` + `CharacterSet.alphanumerics` design, which
    /// passed non-Latin sentences through verbatim because that character set is Unicode-wide.
    func testNonLatinScript_CannotReachModelFamilyOrLanguageCode() async throws {
        let transcript = "我的密码是秘密"
        XCTAssertNil(AnalyticsModelFamily(rawValue: transcript))

        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedIn)
        let dimensions = AnalyticsTranscriptionDimensions(
            mode: .batch,
            engine: .onDevice,
            provider: .local,
            modelFamily: AnalyticsModelFamily(rawValue: transcript) ?? .other,
            languageCode: transcript,
            trigger: .menuBar
        )
        try await fixture.controller.capture(.transcriptionStarted(dimensions))
        try await fixture.controller.capture(.modelDownloadCompleted(
            modelFamily: AnalyticsModelFamily(rawValue: transcript) ?? .other,
            size: .oneToFiveGB,
            success: true
        ))

        let payloads = await fixture.sink.payloads
        XCTAssertEqual(payloads.count, 2)
        for payload in payloads {
            XCTAssertEqual(payload.properties["model_family"], AnalyticsModelFamily.other.rawValue)
            XCTAssertFalse(payload.properties.values.contains { $0.contains(transcript) })
        }
        XCTAssertEqual(payloads.first?.properties["language_code"], "other")
    }

    /// A damaged state file must not wedge start-up, and must not be read as consent.
    func testCorruptStateFile_StartsWithUnknownConsentAndRecovers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("analytics.json")
        try Data("{\"consent\": not-json-at-all".utf8).write(to: fileURL)

        let store = FileProductAnalyticsStateStore(fileURL: fileURL)
        let sink = SpySink()
        let controller = try Self.makeController(sink: sink, store: store)

        let state = await controller.consentState()
        XCTAssertEqual(state, .unknown)
        XCTAssertNil(try store.loadInstallationID())

        try await controller.capture(.appActiveDaily)
        let payloads = await sink.payloads
        XCTAssertTrue(payloads.isEmpty)

        try await controller.setConsent(.optedIn)
        XCTAssertEqual(try store.loadConsent(), .optedIn)
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

    func testOptOutPersistenceFailure_ResetsDurableStateAndClosesSink() async throws {
        let store = StubStore()
        store.consent = .optedIn
        store.installationID = UUID()
        store.saveConsentError = StubError()
        let sink = SpySink()
        let controller = try Self.makeController(sink: sink, store: store)

        do {
            try await controller.setConsent(.optedOut)
            XCTFail("Expected the failed consent write to propagate")
        } catch is StubError {}

        let state = await controller.consentState()
        let closeCount = await sink.closeCount
        XCTAssertEqual(state, .optedOut)
        XCTAssertEqual(store.consent, .unknown)
        XCTAssertNil(store.installationID)
        XCTAssertEqual(closeCount, 1)
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
        forceDisabled: @escaping @Sendable () -> Bool = { false }
    ) throws -> ProductAnalyticsController {
        try ProductAnalyticsController(
            context: context,
            sink: sink,
            stateStore: store,
            forceDisabled: forceDisabled
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

        func resetState() throws {
            consent = .unknown
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
                forceDisabled: { forceDisabled }
            )
        }
    }

    actor SpySink: ProductAnalyticsSink {
        var payloads: [ProductAnalyticsPayload] = []
        var purgeCount = 0
        var closeCount = 0
        var reopenCount = 0
        private var isClosed = false
        private let purgeError: Error?

        init(purgeError: Error? = nil) { self.purgeError = purgeError }

        func reopen() async throws {
            reopenCount += 1
            isClosed = false
        }

        func capture(_ payload: ProductAnalyticsPayload) async throws {
            guard !isClosed else { throw StubError() }
            payloads.append(payload)
        }

        func purge() async throws {
            purgeCount += 1
            payloads.removeAll()
            if let purgeError { throw purgeError }
        }

        func close() async {
            closeCount += 1
            isClosed = true
        }
    }

    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Bool

        init(_ value: Bool) { storedValue = value }

        var value: Bool {
            get { lock.withLock { storedValue } }
            set { lock.withLock { storedValue = newValue } }
        }
    }
}
