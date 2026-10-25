#if !APP_STORE
@testable import SpeakApp
import AppKit
import SwiftUI
import SpeakCore
import SpeakTestSupport
import XCTest

@MainActor
final class AnalyticsPrivacyControlsTests: XCTestCase {
    func testReadOnlyInspection_CreatesNoIdentityOrTraffic() async throws {
        let fixture = try PrivacyControlsFixture()
        await fixture.controls.refresh()
        XCTAssertNil(fixture.controls.installationID)
        XCTAssertNil(try fixture.store.loadInstallationID())
        XCTAssertEqual(fixture.controls.consent, .unknown)
        XCTAssertTrue(fixture.controls.snapshot?.records.isEmpty == true)
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        await fixture.cleanUp()
    }

    func testDisableDuringRequest_PurgesQueueIdentityAndInspectionWithoutChangingConsent() async throws {
        let started = expectation(description: "Request started")
        let recorder = AnalyticsRequestRecorder(holdResponses: true) { _ in started.fulfill() }
        let fixture = try PrivacyControlsFixture(recorder: recorder, consent: .optedIn)
        try await fixture.controller.setConsent(.optedIn)
        let capture = Task { try? await fixture.controller.capture(.appActiveDaily) }
        await fulfillment(of: [started], timeout: 2)
        await fixture.controls.refresh()
        XCTAssertNotNil(fixture.controls.installationID)
        XCTAssertEqual(fixture.controls.snapshot?.records.first?.status, .sending)

        await fixture.controls.setDisabled(true)

        XCTAssertEqual(fixture.controls.consent, .optedIn)
        XCTAssertNil(try fixture.store.loadInstallationID())
        XCTAssertTrue(fixture.controls.snapshot?.isDisabled == true)
        XCTAssertTrue(fixture.controls.snapshot?.records.isEmpty == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.queueURL.path))
        recorder.releaseResponses()
        await capture.value
        await fixture.controls.refresh()
        XCTAssertTrue(fixture.controls.snapshot?.records.isEmpty == true, "A late response cannot revive old events")
        XCTAssertEqual(recorder.requests.count, 1)
        await fixture.cleanUp()
    }

    func testLocalOverride_PersistsAndClearingItWithoutConsentRemainsSilent() async throws {
        let fixture = try PrivacyControlsFixture(consent: .optedOut)
        await fixture.controls.setDisabled(true)
        let restarted = AnalyticsLocalPolicy(defaults: fixture.defaults, buildDisabled: false, environment: [:])
        XCTAssertTrue(restarted.isDisabled)
        await fixture.controls.setDisabled(false)
        try await fixture.controller.capture(.appActiveDaily)
        XCTAssertEqual(fixture.controls.consent, .optedOut)
        XCTAssertNil(try fixture.store.loadInstallationID())
        XCTAssertTrue(fixture.recorder.requests.isEmpty)
        await fixture.cleanUp()
    }

    func testBuildAndEnvironmentDisable_CannotBeClearedByLocalOverride() throws {
        let suite = "AnalyticsLocalPolicy.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let build = AnalyticsLocalPolicy(defaults: defaults, buildDisabled: true, environment: [:])
        build.setLocallyDisabled(false)
        XCTAssertTrue(build.isDisabled)
        let environment = AnalyticsLocalPolicy(defaults: defaults, buildDisabled: false,
                                               environment: ["POSTHOG_DISABLED": "true"])
        environment.setLocallyDisabled(false)
        XCTAssertTrue(environment.isDisabled)
    }

    func testResetAndExport_PreserveConsentAndReportLocalWriteOutcomes() async throws {
        let fixture = try PrivacyControlsFixture(consent: .optedIn)
        try await fixture.controller.capture(.appActiveDaily)
        await fixture.controls.refresh()
        let previousID = try XCTUnwrap(fixture.controls.installationID)
        try saveInspectorPreviewIfRequested(fixture.controls)
        var exported: Data?
        await fixture.controls.export(to: fixture.directory.appendingPathComponent("export.json")) { data, _ in
            exported = data
        }
        let json = try XCTUnwrap(String(data: try XCTUnwrap(exported), encoding: .utf8))
        XCTAssertFalse(json.contains("INGESTION_KEY_SENTINEL"))
        XCTAssertTrue(json.contains(previousID.uuidString))
        XCTAssertEqual(fixture.recorder.requests.count, 1, "Export creates no event")
        let feedback = fixture.controls.feedback
        await fixture.controls.export(to: nil) { _, _ in XCTFail("Cancellation must not write") }
        XCTAssertEqual(fixture.controls.feedback, feedback)
        await fixture.controls.export(to: fixture.directory.appendingPathComponent("failure.json")) { _, _ in
            throw NSError(domain: "export", code: 1, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_WRITE_SENTINEL"])
        }
        XCTAssertTrue(fixture.controls.feedback?.contains("could not be saved") == true)
        XCTAssertFalse(fixture.controls.feedback?.contains("PRIVATE_WRITE_SENTINEL") == true)
        await fixture.controls.resetIdentity()
        XCTAssertEqual(fixture.controls.consent, .optedIn)
        XCTAssertNil(fixture.controls.installationID)
        XCTAssertTrue(fixture.controls.snapshot?.records.isEmpty == true)
        XCTAssertEqual(fixture.recorder.requests.count, 1)
        try await fixture.controller.capture(.appActiveDaily)
        XCTAssertNotEqual(try fixture.store.loadInstallationID(), previousID)
        await fixture.cleanUp()
    }
    private func saveInspectorPreviewIfRequested(_ controls: AnalyticsPrivacyControls) throws {
        guard let path = ProcessInfo.processInfo.environment["JSTI_ANALYTICS_SMOKE_IMAGE"] else { return }
        let renderer = ImageRenderer(content: AnalyticsInspectorView(
            controls: controls, selection: controls.snapshot?.records.last?.id
        ).frame(width: 780, height: 620).environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

@MainActor
private final class PrivacyControlsFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "AnalyticsPrivacyControls.\(UUID())"
    let defaults: UserDefaults
    let recorder: AnalyticsRequestRecorder
    let store: FileProductAnalyticsStateStore
    let sink: PostHogProductAnalyticsSink
    let controller: ProductAnalyticsController
    let controls: AnalyticsPrivacyControls
    var queueURL: URL { directory.appendingPathComponent("queue.json") }

    init(
        recorder: AnalyticsRequestRecorder = AnalyticsRequestRecorder(), consent: AnalyticsConsentState = .unknown
    ) throws {
        self.recorder = recorder
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let policy = AnalyticsLocalPolicy(defaults: defaults, buildDisabled: false, environment: [:])
        recorder.installAsStubHandler()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        self.sink = PostHogProductAnalyticsSink(
            queueURL: directory.appendingPathComponent("queue.json"),
            session: URLSession(configuration: configuration),
            configuration: (
                projectKey: "INGESTION_KEY_SENTINEL", endpoint: URL(string: "https://eu.i.posthog.com/capture")!
            ),
            retryDelays: [],
            forceDisabled: { policy.isDisabled }
        )
        self.store = FileProductAnalyticsStateStore(fileURL: directory.appendingPathComponent("state.json"))
        try store.saveConsent(consent)
        self.controller = try ProductAnalyticsController(
            context: ProductAnalyticsContext(
                platform: .macOS, appVersion: "1.0", build: "1", osMajorMinor: "26.2",
                distributionChannel: .direct, localeLanguageCode: "en", architecture: "arm64"
            ),
            sink: sink,
            stateStore: store,
            forceDisabled: { policy.isDisabled }
        )
        self.controls = AnalyticsPrivacyControls(controller: controller, sink: sink, policy: policy)
    }

    func cleanUp() async {
        await sink.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
