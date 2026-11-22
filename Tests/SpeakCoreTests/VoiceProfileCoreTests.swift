import Foundation
import SpeakCore
import XCTest

final class VoiceProfileCoreTests: XCTestCase {
    #if os(macOS)
    func testVoiceProfileStore_ExcludesContainerAndClipsFromBackups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profile-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = VoiceProfileStore(directory: VoiceProfileStore.defaultDirectory(in: root))
        let count = 16_000 * 6
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let sec = Double(index) / 16_000.0
            let env = sec.truncatingRemainder(dividingBy: 1.5) < 1.2 ? 1.0 : 0.002
            samples[index] = Float(env * 0.35 * sin(2.0 * .pi * 150.0 * sec))
        }
        let clip = VoiceProfileStore.ClipInput(
            pcmBuffer: VoiceProfilePCMBuffer(samples: samples, sampleRate: 16_000),
            targetFormat: .pcm16k,
            transcript: "Reference phrase for backup exclusion.",
            source: .recorded
        )
        let profile = try store.createProfile(
            name: "Private Backup Check",
            language: "en",
            clips: [clip],
            consent: ConsentAttestation()
        )
        let clipURL = try store.clipURL(for: profile.clips[0], in: profile.id)

        XCTAssertEqual(try store.rootDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(
            try store.metadataFileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
        XCTAssertEqual(try clipURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    #endif

    func testSettingsSearchCatalog_IndexesVoiceProfilesOnDesktopOnly() {
        let entries = SettingsSearchCatalog.entries
        let macEntry = entries.first { $0.id == "voiceOutput.voiceProfiles" }
        let desktopEntry = entries.first { $0.id == "desktop.voiceProfiles" }
        XCTAssertEqual(macEntry?.title, "My Voices")
        XCTAssertEqual(macEntry?.platforms, [.macOS])
        XCTAssertEqual(desktopEntry?.title, "My voices")
        XCTAssertEqual(desktopEntry?.platforms, [.windows, .linux])

        let macIndex = SettingsSearchIndex(entries: SettingsSearchCatalog.entries(for: .macOS))
        XCTAssertTrue(macIndex.search("My Voices").contains { $0.entry.id == "voiceOutput.voiceProfiles" })
        XCTAssertTrue(macIndex.search("voice profile").contains { $0.entry.id == "voiceOutput.voiceProfiles" })

        for desktopPlatform in [SettingsPlatform.windows, .linux] {
            let index = SettingsSearchIndex(entries: SettingsSearchCatalog.entries(for: desktopPlatform))
            XCTAssertTrue(index.search("My voices").contains { $0.entry.id == "desktop.voiceProfiles" })
            XCTAssertTrue(index.search("voice profile").contains { $0.entry.id == "desktop.voiceProfiles" })
        }

        // Owner decision (18 Nov 2026): voice creation is desktop-only; iOS & Android are N/A.
        for mobilePlatform in [SettingsPlatform.iOS, .android] {
            let index = SettingsSearchIndex(entries: SettingsSearchCatalog.entries(for: mobilePlatform))
            XCTAssertFalse(index.search("My voices").contains {
                $0.entry.id == "voiceOutput.voiceProfiles" || $0.entry.id == "desktop.voiceProfiles"
            })
            XCTAssertFalse(index.search("voice creation").contains {
                $0.entry.id == "voiceOutput.voiceProfiles" || $0.entry.id == "desktop.voiceProfiles"
            })
        }
    }
}
