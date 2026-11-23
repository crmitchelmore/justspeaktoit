import Foundation
import XCTest

@testable import SpeakCore

final class VoiceStudioSettingsSearchTests: XCTestCase {
    func testMacOSAndDesktopSearchIndexLocalVoiceStudioAndKeys() {
        let macEntry = SettingsSearchCatalog.entry(title: "Local Voice Studio", platform: .macOS)
        XCTAssertNotNil(macEntry)
        XCTAssertEqual(macEntry?.id, "voiceOutput.voiceStudio")
        XCTAssertEqual(Set(macEntry?.settingKeys ?? []), Set(VoiceStudioPreference.allSettingKeys))

        for platform in [SettingsSearchPlatforms.windows, SettingsSearchPlatforms.linux] {
            let desktopEntry = SettingsSearchCatalog.entry(title: "Local Voice Studio", platform: platform)
            XCTAssertNotNil(desktopEntry)
            XCTAssertEqual(desktopEntry?.id, "desktop.voiceStudio")
            XCTAssertEqual(Set(desktopEntry?.settingKeys ?? []), Set(VoiceStudioPreference.allSettingKeys))

            let session = DesktopSettingsSearchSession(platform: platform)
            XCTAssertFalse(session.results(for: "voicebox").isEmpty)
            XCTAssertFalse(session.results(for: "voicestudio").isEmpty)
            XCTAssertFalse(session.results(for: "gpt-sovits").isEmpty)
        }

        let fieldEntry = DesktopSettingsSearch.entries(for: .linux).first {
            $0.id == DesktopSettingsSearch.fieldEntryPrefix + VoiceStudioPreference.enabledKey
        }
        XCTAssertNotNil(fieldEntry)
        if let fieldEntry {
            XCTAssertEqual(DesktopSettingsSearch.target(for: fieldEntry).destination, .voiceOutput)
        }
    }

    func testMobilePlatformsExcludeLocalVoiceStudioByOwnerDecision() throws {
        XCTAssertNil(SettingsSearchCatalog.entry(title: "Local Voice Studio", platform: .iOS))
        XCTAssertFalse(SettingsSearchCatalog.entries(for: .iOS).contains { $0.id.contains("voiceStudio") })
        XCTAssertEqual(VoiceAccountProvider.all, [.xai, .mistral, .soniox])
        XCTAssertEqual(VoiceAccountProvider.studioProviders, [.voicebox, .voiceStudio, .gptSoVITS])

        let androidVoices = try VoiceCatalogAndroidExport.voices()
        XCTAssertFalse(androidVoices.contains { $0.id.hasPrefix("studio/") || $0.provider.contains("studio") })
        let androidAccounts = try VoiceCatalogAndroidExport.accountProviders()
        XCTAssertEqual(androidAccounts.map(\.provider), ["mistral", "xai", "soniox"])
    }
}
