import Foundation
import SpeakCore
import XCTest

/// The iOS Privacy screen once said API keys "never leave your device except
/// when syncing via iCloud Keychain" and listed iCloud sync as "Settings & keys".
/// Keys are sent to providers to authenticate, key sync is passphrase-encrypted
/// CloudKit rather than iCloud Keychain, and History, including transcript text,
/// syncs to CloudKit whenever iCloud is signed in. These tests pin each of those
/// facts to the shared copy so it cannot drift back.
final class PrivacyStorageDisclosureTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SpeakCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private var allDisclosures: [String] {
        [
            PrivacyStorageDisclosure.apiKeyStorage,
            PrivacyStorageDisclosure.apiKeySync,
            PrivacyStorageDisclosure.historySync,
            PrivacyStorageDisclosure.historySyncOff,
            PrivacyStorageDisclosure.historySyncCondition,
            PrivacyStorageDisclosure.apiKeySyncCondition
        ]
    }

    func testAPIKeyStorage_disclosesThatKeysAuthenticateProviderRequests() {
        let copy = PrivacyStorageDisclosure.apiKeyStorage
        XCTAssertTrue(copy.contains("Keychain"), copy)
        XCTAssertTrue(copy.contains("sent to that provider"), copy)
        XCTAssertTrue(copy.contains("authenticate"), copy)
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("never leave"), copy)
    }

    func testAPIKeySync_describesOptInPassphraseEncryptedCloudKit() {
        let copy = PrivacyStorageDisclosure.apiKeySync
        XCTAssertTrue(copy.contains("If you turn on"), copy)
        XCTAssertTrue(copy.contains("supported keys"), copy)
        XCTAssertTrue(copy.contains("encrypted on this device"), copy)
        XCTAssertTrue(copy.contains("passphrase"), copy)
        XCTAssertTrue(copy.contains("private CloudKit database"), copy)
    }

    func testHistorySync_disclosesTranscriptTextAndWhenItSyncs() {
        let copy = PrivacyStorageDisclosure.historySync
        XCTAssertTrue(copy.contains("transcript text"), copy)
        XCTAssertTrue(copy.contains("private CloudKit database"), copy)
        XCTAssertTrue(copy.contains("automatically"), copy)
        XCTAssertTrue(copy.contains("signed in to iCloud"), copy)
        XCTAssertTrue(copy.contains("on by default"), copy)
        XCTAssertTrue(copy.contains("turn it off"), copy)
    }

    /// Off must not read as "deleted from iCloud": the switch stops traffic,
    /// it does not remove what is already there.
    func testHistorySyncOff_saysWhatStaysWhereAndWhatHappensOnReEnable() {
        let copy = PrivacyStorageDisclosure.historySyncOff
        XCTAssertTrue(copy.contains("stays on this device"), copy)
        XCTAssertTrue(copy.contains("already in iCloud stays there"), copy)
        XCTAssertTrue(copy.contains("does not remove it from iCloud"), copy)
        XCTAssertTrue(copy.contains("uploads History saved while it was off"), copy)
    }

    func testDisclosures_neverAttributeKeySyncToICloudKeychain() {
        for copy in allDisclosures {
            XCTAssertFalse(copy.contains("iCloud Keychain"), copy)
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("end-to-end"), copy)
        }
    }

    /// The screens move between files (issue #1115), so scan every iOS source
    /// rather than one path for the retired wording.
    func testIOSSources_doNotCarryTheRetiredPrivacyCopy() throws {
        let iosSources = repositoryRoot.appendingPathComponent("Sources/SpeakiOS")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: iosSources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            XCTAssertFalse(source.contains("syncing via iCloud Keychain"), url.lastPathComponent)
            XCTAssertFalse(source.contains("Settings & keys"), url.lastPathComponent)
            // Settings › Sync once reported iCloud Keychain and iCloud Settings
            // paths that carry no app data, and said settings sync via iCloud.
            XCTAssertFalse(source.contains("\"iCloud Keychain\""), url.lastPathComponent)
            XCTAssertFalse(source.contains("\"iCloud Settings\""), url.lastPathComponent)
            XCTAssertFalse(source.contains("uses iCloud for settings"), url.lastPathComponent)
        }
        XCTAssertGreaterThan(scanned, 0, "Expected to scan the iOS sources at \(iosSources.path)")
    }
}
