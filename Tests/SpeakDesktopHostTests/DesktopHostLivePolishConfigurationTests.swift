import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopHostLivePolishConfigurationTests: XCTestCase {
    func testCapturedProfile_UsesResolvedModelAndImmutableConfigurationDespiteLaterEdits() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let alternate = try XCTUnwrap(DesktopPostProcessing.remoteModels.first {
            $0.id != ModelCatalog.defaultFastTextModel
        }).id
        let configuration = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("livePolish")), "livePolishModel": AnyCodable(.string("")),
            "livePolishDebounceMs": AnyCodable(.int(123)), "livePolishMinDeltaChars": AnyCodable(.int(7)),
            "skipPostProcessingWithLivePolish": AnyCodable(.bool(false))
        ])
        let profile = DesktopProfileSessionResolver.resolve(
            profile: DictationProfile(name: "Selected", polishEnabled: true, polishModelID: alternate),
            defaultModel: fixture.model, defaultPostProcessing: .init(),
            capabilities: .shared
        ).capturingLivePolish(.init(configuration: configuration, approved: true))
        let later = try DesktopConfiguration(values: ["speedMode": AnyCodable(.string("instant"))])
        await fixture.host.autoCleanFixtureSettings(configuration: later, approved: false)
        let captured = await fixture.host.captureLivePolish(profile)
        let input = try XCTUnwrap(captured)
        XCTAssertEqual(input.model, alternate)
        XCTAssertEqual(input.preferences.debounceMilliseconds, 123)
        XCTAssertEqual(input.preferences.minimumDeltaCharacters, 7)
        XCTAssertFalse(input.preferences.skipPostProcessing)
        XCTAssertEqual(input.key, "cleanup-key-at-start")
        XCTAssertNil(input.failure)
        XCTAssertEqual(profile.profileName, "Selected")
        let preserved = try await fixture.host.configuration()
        XCTAssertEqual(preserved.text("speedMode"), "instant")
    }

    func testImportExportAndRestart_PreservePreferencesButRequireDeviceLocalApplyBeforeRequests() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let preferences = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("livePolish")),
            "livePolishModel": AnyCodable(.string(ModelCatalog.defaultFastTextModel)),
            "livePolishDebounceMs": AnyCodable(.int(250)),
            "livePolishMinDeltaChars": AnyCodable(.int(3)),
            "skipPostProcessingWithLivePolish": AnyCodable(.bool(false)),
            "livePolishTailWindowChars": AnyCodable(.int(321)),
            "futurePreference": AnyCodable(.string("retained"))
        ])
        let incoming = fixture.directory.appendingPathComponent("incoming.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: incoming)
        try await fixture.host.importConfiguration(path: incoming.path)
        let profile = await fixture.host.captureProfile(modelIndex: fixture.modelIndex, executablePath: nil)
        let dormant = await fixture.host.captureLivePolish(profile)
        XCTAssertTrue(dormant?.failure?.contains("not authorized") == true)
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
        let exported = fixture.directory.appendingPathComponent("exported.json")
        try await fixture.host.exportConfiguration(path: exported.path)
        let data = try Data(contentsOf: exported)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: data)
        for key in preferences.values.keys { XCTAssertEqual(document.preferences.values[key], preferences.values[key]) }
        let encoded = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("livePolishApproved"))
        XCTAssertFalse(encoded.contains("cleanup-key-at-start"))
        let entries = try await fixture.host.configurationForNativeEditor().entries
        try await fixture.host.saveConfiguration(entries)
        await fixture.host.close()
        let restarted = try DesktopHostController<FakePlatform>(directory: fixture.directory, effects: fixture.effects)
        let restored = try await restarted.configuration()
        XCTAssertEqual(try restored.livePolishPreferences.debounceMilliseconds, 250)
        XCTAssertEqual(restored.values["livePolishTailWindowChars"], AnyCodable(.int(321)))
        let next = await restarted.captureProfile(modelIndex: fixture.modelIndex, executablePath: nil)
        let active = await restarted.captureLivePolish(next)
        XCTAssertNil(active?.failure)
        XCTAssertEqual(active?.key, "cleanup-key-at-start")
        XCTAssertEqual(fixture.effects.keyReads, ["openrouter.apiKey"])
        await restarted.close()
    }

    func testUnknownSpeedModeAndUnavailableProfileModel_AreExplicitAndDoNotReadCleanupKeys() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let unknown = try DesktopConfiguration(values: ["speedMode": AnyCodable(.string("future-mode"))])
        await fixture.host.autoCleanFixtureSettings(configuration: unknown)
        let captured = await fixture.host.captureProfile(modelIndex: fixture.modelIndex, executablePath: nil)
        let invalid = await fixture.host.captureLivePolish(captured)
        XCTAssertTrue(invalid?.failure?.contains("invalid") == true)
        let active = try DesktopConfiguration(values: ["speedMode": AnyCodable(.string("livePolish"))])
        let unavailable = DesktopProfileSessionResolver.resolve(
            profile: DictationProfile(name: "Unavailable", polishEnabled: true, polishModelID: "future/model"),
            defaultModel: fixture.model, defaultPostProcessing: .init(), capabilities: .shared
        ).capturingLivePolish(.init(configuration: active, approved: true))
        let refused = await fixture.host.captureLivePolish(unavailable)
        XCTAssertTrue(refused?.failure?.contains("not available") == true)
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
    }
}
