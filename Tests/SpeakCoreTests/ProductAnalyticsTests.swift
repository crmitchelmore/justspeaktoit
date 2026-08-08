import Foundation
@testable import SpeakCore
import XCTest

final class ProductAnalyticsTests: XCTestCase {
    func testUnknownConsentSendsNothingAndDoesNotCreateIdentity() async throws {
        let fixture = try Fixture()
        try await fixture.controller.capture(.appActiveDaily)
        let payloads = await fixture.sink.payloads
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertNil(try fixture.store.loadInstallationID())
    }

    func testOptedOutConsentSendsNothing() async throws {
        let fixture = try Fixture()
        try await fixture.controller.setConsent(.optedOut)
        try await fixture.controller.capture(.appActiveDaily)
        let payloads = await fixture.sink.payloads
        XCTAssertTrue(payloads.isEmpty)
    }

    func testOptInCapturesOnlyTypedAllowlistedProperties() async throws {
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

    func testOptOutPurgesQueueDeletesIdentityAndClosesSink() async throws {
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

    func testForceDisabledKillSwitchOverridesOptIn() async throws {
        let fixture = try Fixture(forceDisabled: true)
        try await fixture.controller.setConsent(.optedIn)
        try await fixture.controller.capture(.appActiveDaily)
        let payloads = await fixture.sink.payloads
        XCTAssertTrue(payloads.isEmpty)
    }

    func testPreviewUsesTheSameAllowlistedPayloadEncoder() async throws {
        let fixture = try Fixture()
        let data = try await fixture.controller.preview(.onboardingStarted(entryPoint: .freshInstall))
        let payload = try JSONDecoder().decode(ProductAnalyticsPayload.self, from: data)
        XCTAssertEqual(payload.event, "onboarding_started")
        XCTAssertEqual(payload.properties["entry_point"], "fresh_install")
    }

    private static let allowedFirstSuccessKeys: Set<String> = [
        "provider_type", "engine_type", "days_since_install_bucket", "platform", "app_version", "build",
        "os_major_minor", "distribution_channel", "locale_language_code", "architecture", "analytics_schema_version"
    ]
}

private extension ProductAnalyticsTests {
    struct Fixture {
        let sink: SpySink
        let store: FileProductAnalyticsStateStore
        let controller: ProductAnalyticsController

        init(forceDisabled: Bool = false) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            store = FileProductAnalyticsStateStore(fileURL: directory.appendingPathComponent("analytics.json"))
            sink = SpySink()
            controller = try ProductAnalyticsController(
                context: ProductAnalyticsContext(
                    platform: .macOS,
                    appVersion: "1.2.3",
                    build: "42",
                    osMajorMinor: "15.6",
                    distributionChannel: .development,
                    localeLanguageCode: "en",
                    architecture: "arm64"
                ),
                sink: sink,
                stateStore: store,
                forceDisabled: { forceDisabled }
            )
        }
    }

    actor SpySink: ProductAnalyticsSink {
        var payloads: [ProductAnalyticsPayload] = []
        var purgeCount = 0
        var closeCount = 0
        func capture(_ payload: ProductAnalyticsPayload) async throws { payloads.append(payload) }
        func purge() async throws { purgeCount += 1; payloads.removeAll() }
        func close() async { closeCount += 1 }
    }
}
