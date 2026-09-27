import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakLinuxPlatform
import XCTest

/// Start at login outside Flatpak, the Read aloud staging folder and the
/// model hasher and runtime lookup.
final class LinuxServicesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-services-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Start at login

    func testTheAutostartEntryStartsTheAppHiddenAndIsRemovedOnlyWhenOurs() throws {
        let url = LinuxAutostart.entryURL(applicationID: "com.example.App", environment: ["XDG_CONFIG_HOME": root.path])
        XCTAssertEqual(url.path, root.appendingPathComponent("autostart/com.example.App.desktop").path)
        XCTAssertFalse(LinuxAutostart.entryEnabled(at: url))
        try LinuxAutostart.setEntry(true, at: url, applicationID: "com.example.App", executable: "/opt/My App/app")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#"Exec="/opt/My App/app" --hidden"#), text)
        XCTAssertTrue(LinuxAutostart.entryEnabled(at: url))
        try LinuxAutostart.setEntry(false, at: url, applicationID: "com.example.App", executable: "/opt/My App/app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try Data("[Desktop Entry]\nExec=something-else\n".utf8).write(to: url)
        XCTAssertThrowsError(
            try LinuxAutostart.setEntry(false, at: url, applicationID: "com.example.App", executable: "/app")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "A user's own entry is never deleted")
        try Data("[Desktop Entry]\nHidden=true\n".utf8).write(to: url)
        XCTAssertFalse(LinuxAutostart.entryEnabled(at: url))
    }

    func testTheHomeFallbackIsDotConfig() {
        let url = LinuxAutostart.entryURL(applicationID: "a.b", environment: ["HOME": "/home/someone"])
        XCTAssertEqual(url.path, "/home/someone/.config/autostart/a.b.desktop")
    }

    // MARK: Read aloud staging

    func testSpeechFilesArePrivateExclusiveAndOnlyOurOwnAreRemoved() throws {
        let staging = try LinuxVoiceOutputStaging(directory: root.appendingPathComponent("VoiceOutput"))
        let file = try staging.store(Data("RIFF".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try Data(contentsOf: file), Data("RIFF".utf8))
        XCTAssertEqual(staging.ownedCount, 1)

        let stranger = root.appendingPathComponent("VoiceOutput/other.wav")
        try Data().write(to: stranger)
        XCTAssertThrowsError(try staging.discard(stranger))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))

        try staging.discard(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(staging.ownedCount, 0)
    }

    func testLeftoverSpeechIsBoundedRatherThanUnbounded() throws {
        let staging = try LinuxVoiceOutputStaging(directory: root.appendingPathComponent("VoiceOutput"))
        for _ in 0..<LinuxVoiceOutputStaging.maximumOwnedFiles { _ = try staging.store(Data([1])) }
        XCTAssertThrowsError(try staging.store(Data([1])))
    }

    // MARK: On-device models

    func testTheHasherMatchesAKnownDigest() throws {
        let hasher = try LinuxSHA256Hasher()
        try Data("abc".utf8).withUnsafeBytes { try hasher.update($0) }
        XCTAssertEqual(try hasher.finish(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertThrowsError(try hasher.finish(), "A finished hasher cannot be reused")
    }

    func testTheRuntimeIsLookedUpBesideTheAppAndReportsWhenMissing() throws {
        let override = LinuxWhisperRuntime.defaultDirectory(environment: ["JSTI_WHISPER_LIBRARY_DIR": root.path])
        XCTAssertEqual(override.path, root.path)
        XCTAssertTrue(LinuxWhisperRuntime.defaultDirectory(environment: [:]).path.hasSuffix("/lib/justspeaktoit"))
        XCTAssertFalse(LinuxWhisperRuntime.isInstalled(in: root))
        XCTAssertThrowsError(try LinuxWhisperRuntime.open(directory: root, allowGPU: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not installed"), error.localizedDescription)
        }
    }

    func testTheLinuxHostOffersTheCatalogueWhisperModels() {
        let linux = DesktopLocalTranscription.models(host: .linux).map(\.catalogueID)
        let windows = DesktopLocalTranscription.models(host: .windows).map(\.catalogueID)
        XCTAssertFalse(linux.isEmpty)
        XCTAssertEqual(linux, windows, "Both hosts project the same shared catalogue")
    }
}
