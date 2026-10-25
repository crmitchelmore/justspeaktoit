#if !APP_STORE
@testable import SpeakApp
import AppKit
import SwiftUI
import SpeakCore
import SpeakTestSupport
import XCTest

@MainActor
final class AnalyticsPrivacyControlsTests: XCTestCase {
    private var fixtures: [PrivacyControlsFixture] = []
    private var captures: [Task<Void, Never>] = []

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() async throws {
        for fixture in fixtures { await fixture.cleanUp() }
        for capture in captures { await capture.value }
        fixtures.removeAll()
        captures.removeAll()
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    func testReadOnlyInspection_CreatesNoIdentityOrTraffic() async throws {
        let fixture = try makeFixture()
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
        let fixture = try makeFixture(recorder: recorder, consent: .optedIn)
        try await fixture.controller.setConsent(.optedIn)
        let capture = Task { _ = try? await fixture.controller.capture(.appActiveDaily) }
        captures.append(capture)
        await fulfillment(of: [started], timeout: 2)
        await fixture.controls.refresh()
        XCTAssertNotNil(fixture.controls.installationID)
        XCTAssertEqual(fixture.controls.snapshot?.records.first?.status, .sending)

        await fixture.controls.setDisabled(true)
        XCTAssertEqual(fixture.controls.collectionLabel, "Disabled by local override")

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
        let fixture = try makeFixture(consent: .optedOut)
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

    func testBuildAndEnvironmentDisable_CannotBeClearedOrMislabelledAsLocalOverride() async throws {
        let sources: [(build: Bool, environment: [String: String])] = [
            (true, [:]), (false, ["POSTHOG_DISABLED": "true"])
        ]
        for source in sources {
            let fixture = try makeFixture(
                consent: .optedIn, buildDisabled: source.build, environment: source.environment
            )
            await fixture.controls.setDisabled(false)
            try await fixture.controller.capture(.appActiveDaily)
            XCTAssertTrue(fixture.controls.policy.isDisabled)
            XCTAssertEqual(fixture.controls.collectionLabel, "Disabled by build or launch policy")
            XCTAssertTrue(fixture.recorder.requests.isEmpty)
            XCTAssertNil(try fixture.store.loadInstallationID())
            await fixture.cleanUp()
        }
    }

    func testResetAndExport_PreserveConsentAndReportLocalWriteOutcomes() async throws {
        let fixture = try makeFixture(consent: .optedIn)
        try await fixture.controller.capture(.appActiveDaily)
        await fixture.controls.refresh()
        let previousID = try XCTUnwrap(fixture.controls.installationID)
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

    func testInspectorNativeVisualFixture_WhenExplicitlyRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["JSTI_ANALYTICS_SMOKE_IMAGE"] else {
            throw XCTSkip("Set JSTI_ANALYTICS_SMOKE_IMAGE to capture the isolated native fixture.")
        }
        let fixture = try makeFixture(consent: .optedIn)
        try await fixture.controller.capture(.appActiveDaily)
        await fixture.controls.refresh()
        try await saveInspectorPreview(fixture.controls, to: path)
        await fixture.cleanUp()
    }

    private func makeFixture(
        recorder: AnalyticsRequestRecorder = AnalyticsRequestRecorder(), consent: AnalyticsConsentState = .unknown,
        buildDisabled: Bool = false, environment: [String: String] = [:]
    ) throws -> PrivacyControlsFixture {
        let fixture = try PrivacyControlsFixture(
            recorder: recorder, consent: consent, buildDisabled: buildDisabled, environment: environment
        )
        fixtures.append(fixture)
        return fixture
    }

    private func saveInspectorPreview(_ controls: AnalyticsPrivacyControls, to path: String) async throws {
        let view = NSHostingView(rootView: AnalyticsInspectorView(
            controls: controls, selection: controls.snapshot?.records.last?.id
        ).frame(width: 780, height: 620).environment(\.colorScheme, .light))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 780, height: 620),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
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
    let session: URLSession
    let controller: ProductAnalyticsController
    let controls: AnalyticsPrivacyControls
    var queueURL: URL { directory.appendingPathComponent("queue.json") }

    init(
        recorder: AnalyticsRequestRecorder = AnalyticsRequestRecorder(), consent: AnalyticsConsentState = .unknown,
        buildDisabled: Bool = false, environment: [String: String] = [:]
    ) throws {
        self.recorder = recorder
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let policy = AnalyticsLocalPolicy(defaults: defaults, buildDisabled: buildDisabled, environment: environment)
        recorder.installAsStubHandler()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        self.session = session
        self.sink = PostHogProductAnalyticsSink(
            queueURL: directory.appendingPathComponent("queue.json"),
            session: session,
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
        recorder.releaseResponses()
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
