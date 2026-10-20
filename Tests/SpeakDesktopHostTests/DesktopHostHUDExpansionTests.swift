import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostHUDExpansionTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hud-expansion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SettingsWriteEffects())
    }

    override func tearDown() async throws {
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func save(_ preference: String, compact: Bool = false, preview: Bool = true) async throws {
        let preferences = try DesktopConfiguration(values: [
            "hudSizePreference": AnyCodable(.string(preference)),
            "showCompactHUD": AnyCodable(.bool(compact)),
            "showLiveTranscriptInHUD": AnyCodable(.bool(preview))
        ])
        try await controller.saveConfiguration(preferences.entries)
        FakeLog.shared.reset()
    }

    func testAutoExpansionUsesStrictMacThresholdAndStaysExpandedUntilNextRecording() async throws {
        let record = UUID()
        await controller.beginHUD(record, .recording(profile: nil, liveText: String(repeating: "a", count: 100)))
        XCTAssertEqual(FakeLog.shared.huds.last?.expanded, false)
        await controller.hud(record, .recording(profile: nil, liveText: String(repeating: "a", count: 101)))
        XCTAssertEqual(FakeLog.shared.huds.last?.expanded, true)
        await controller.hud(record, .recording(profile: nil, liveText: "Retracted"))
        XCTAssertEqual(FakeLog.shared.huds.last?.expanded, true)
        await controller.hud(record, .transcribing())
        XCTAssertEqual(FakeLog.shared.huds.last?.expanded, true)
        await controller.beginHUD(UUID(), .recording(profile: nil))
        XCTAssertEqual(FakeLog.shared.huds.last?.expanded, false)
        await controller.hud(record, .recording(profile: nil, liveText: String(repeating: "a", count: 200)))
        XCTAssertEqual(FakeLog.shared.huds.last?.expanded, false)
    }

    func testForcedModesProjectRealExpandedOrCompactFullCards() async throws {
        for preference in ["compact", "expanded"] {
            try await save(preference)
            await controller.beginHUD(UUID(), .recording(profile: nil, liveText: String(repeating: "a", count: 200)))
            XCTAssertEqual(FakeLog.shared.huds.last?.expanded, preference == "expanded")
        }
    }

    func testMinimalHUDWinsOverExpansionAndHiddenPreviewCannotTriggerAutoExpansion() async throws {
        try await save("expanded", compact: true)
        await controller.beginHUD(UUID(), .recording(profile: nil))
        XCTAssertEqual(FakeLog.shared.huds.last?.compact, true)
        XCTAssertEqual(FakeLog.shared.huds.last?.expanded, false)
        try await save("autoExpand", preview: false)
        await controller.beginHUD(UUID(), .recording(profile: nil, liveText: String(repeating: "a", count: 200)))
        XCTAssertEqual(FakeLog.shared.huds.last?.liveText, "")
        XCTAssertEqual(FakeLog.shared.huds.last?.expanded, false)
    }

    func testChoicesKeepCanonicalIDsAndSurviveApplyTransferAndReload() throws {
        XCTAssertEqual(HUDExpansionPreference.defaultValue, .autoExpand)
        XCTAssertEqual(HUDExpansionPreference.autoExpandThreshold, 100)
        let field = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == "hudSizePreference" })
        XCTAssertEqual(field.serializedChoices, "compact\tCompact\nexpanded\tAlways Expanded\nautoExpand\tAuto-Expand")
        for preference in HUDExpansionPreference.allCases {
            let original = try DesktopConfiguration(values: [
                field.key: AnyCodable(.string(preference.rawValue)), "future": AnyCodable(.bool(true))
            ])
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(original.applying(original.entries))
            )
            XCTAssertEqual(restored.hudExpansion, preference)
            XCTAssertEqual(restored.values["future"], original.values["future"])
        }
    }
}
