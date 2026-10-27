import Foundation
import SpeakCore
import XCTest
@testable import SpeakApp

@MainActor
final class GladiaStartupOptionsTests: XCTestCase {
    func testSuspendedConstructionUsesLanguageAndSettingsCapturedBeforeItsFirstAwait() async throws {
        let suite = "gladia-startup-options.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.liveTranscriptionModel = "gladia/solaria-1-streaming"
        settings.liveStopGracePeriod = 0.4
        let permissions = PermissionsManager(statusProvider: { _ in .granted }, grantHistory: defaults)
        let controller = SharedClientLiveController(
            permissionsManager: permissions, audioDeviceManager: AudioInputDeviceManager(appSettings: settings),
            secureStorage: SecureAppStorage(
                permissionsManager: permissions, appSettings: settings,
                keychainService: "com.justspeaktoit.tests.gladia-startup.\(UUID().uuidString)"
            ), appSettings: settings
        )
        let gate = GladiaStartupGate()
        let fixture = GladiaHostClientFixture()
        var made: GladiaLiveClient?
        controller.configuredClientFactory = { route, language, options in
            XCTAssertEqual(route.provider, .gladia)
            await gate.wait()
            let client = fixture.make(language: language, options: options)
            made = client
            return client
        }
        controller.startCaptureAudio = {}
        controller.configure(language: "en_GB", model: "gladia/solaria-1-streaming")
        let done = XCTestExpectation(description: "owned startup completed")
        let exited = XCTestExpectation(description: "owned startup exited")
        let start = Task { @MainActor in
            defer { done.fulfill(); exited.fulfill() }
            try await controller.start()
        }
        addTeardownBlock { @MainActor in
            start.cancel(); gate.release(); made?.cancel()
            let outcome = await XCTWaiter.fulfillment(of: [exited], timeout: 2)
            XCTAssertEqual(outcome, .completed)
            await controller.stop()
        }
        try await wait(gate.entered)
        settings.liveStopGracePeriod = 1.7
        controller.configure(language: "fr_FR", model: "gladia/solaria-1-streaming")
        gate.release()
        try await wait(done)
        try await start.value
        let client = try XCTUnwrap(made)
        XCTAssertEqual(try XCTUnwrap(client.finalisationBudget), 4.9, accuracy: 0.000_001)
        try assertCapturedLanguage(fixture)
        XCTAssertEqual(controller.stopCompletionTimeout, 10)
        client.cancel()
        await controller.stop()
    }

    func testOriginalClientFactoryStillTakesPrecedenceOverConfiguredConstructionSeam() async throws {
        let fixture = try GladiaControllerBoundaryFixture()
        defer { fixture.cleanup() }
        fixture.controller.configuredClientFactory = { _, _, _ in
            XCTFail("Existing no-argument clientFactory must keep precedence")
            throw CancellationError()
        }
        try await fixture.controller.start()
        fixture.client.cancel()
        await fixture.controller.stop()
    }

    private func assertCapturedLanguage(_ fixture: GladiaHostClientFixture) throws {
        let request = try XCTUnwrap(fixture.requests.all.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((object["language_config"] as? [String: Any])?["languages"] as? [String], ["en"])
    }

    private func wait(_ signal: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [signal], timeout: 2) == .completed else {
            XCTFail("Owned startup stage did not settle")
            throw GladiaStartupTimeout()
        }
    }
}

@MainActor
private final class GladiaStartupGate {
    let entered = XCTestExpectation(description: "startup construction suspended")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}
private struct GladiaStartupTimeout: Error {}
