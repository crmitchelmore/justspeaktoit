import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class DesktopDictationProfileStoreTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testMissingFileMeansNoProfiles_AndSaveRoundTripsOrderAndIdentifiers() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopDictationProfileStore(directory: root.appendingPathComponent("Profiles"))
        XCTAssertEqual(try store.load(), [])

        let profiles = [
            DictationProfile(
                name: "Code",
                matchers: [.bundleID("com.microsoft.VSCode"), .windowsExecutablePath(#"C:\Apps\Code.exe"#)],
                transcriptionModelID: "openai/whisper-1",
                polishEnabled: false,
                transcriptionRouting: .remoteBatch
            ),
            DictationProfile(name: "Notes", matchers: [.windowsExecutablePath(#"C:\Windows\notepad.exe"#)])
        ]
        try store.save(profiles)
        XCTAssertEqual(try store.load(), profiles)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), try DictationProfile.encodeList(profiles))

        try store.save(profiles.reversed())
        XCTAssertEqual(try store.load().map(\.id), profiles.reversed().map(\.id))
        try store.save([])
        XCTAssertEqual(try store.load(), [])
    }

    func testFileUsesTheCanonicalCrossPlatformEncoding() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopDictationProfileStore(directory: root)
        let json = """
        [{"id":"6F1E32F9-31A5-4C1E-9E32-9E4CB25B7A4C","name":"Mail","matchers":[
        {"kind":"bundleID","value":"com.apple.mail"},{"kind":"windowTitle","value":"Inbox"}],
        "transcriptionRouting":"quantum","polishEnabled":true}]
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.fileURL)

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].matchers, [.bundleID("com.apple.mail")])
        XCTAssertNil(loaded[0].transcriptionRouting)
        XCTAssertEqual(loaded[0].polishEnabled, true)
    }

    func testUnreadableFileIsReportedAndCanBePreservedBeforeSaving() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopDictationProfileStore(directory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("{not a list".utf8)
        try corrupt.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
        let preserved = try XCTUnwrap(try store.preserveUnreadableFile(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertTrue(preserved.lastPathComponent.hasPrefix("profiles.json.unreadable-1700000000-"))
        XCTAssertEqual(try Data(contentsOf: preserved), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertNil(try store.preserveUnreadableFile())

        try store.save([DictationProfile(name: "Fresh")])
        XCTAssertEqual(try store.load().map(\.name), ["Fresh"])
        XCTAssertEqual(try Data(contentsOf: preserved), corrupt, "Preserved data is never touched by a later save")
    }
}
