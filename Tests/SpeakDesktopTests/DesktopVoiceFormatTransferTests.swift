import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopVoiceFormatTransferTests: XCTestCase {
    func testNativeWire_LegacyGenerationAndExplicitCapturedFormatPreserveSourceAndFlags() throws {
        let owner = UUID()
        let legacy = try DesktopVoiceSourceMessage(action: 115, source: 0, text: "Synthetic History.",
            record: owner.uuidString, path: "2")
        let captured = try DesktopVoiceSourceMessage(action: 115, source: 0, text: "Synthetic History.",
            record: owner.uuidString, path: "2|m4a")
        guard case .event(.voiceGenerate(let oldSource, let oldOptions)) = legacy,
              case .event(.voiceGenerate(let newSource, let newOptions)) = captured else {
            return XCTFail("Expected actual generation events.")
        }
        XCTAssertEqual(oldSource, newSource)
        XCTAssertEqual(newSource.recordID, owner)
        XCTAssertEqual(oldOptions.nativeFlags, 2)
        XCTAssertNil(oldOptions.format)
        XCTAssertEqual(newOptions.nativeFlags, 2)
        XCTAssertEqual(newOptions.format, .m4a)
        for invalid in ["2|future", "4|mp3", "2|", "2|mp3|wav"] {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 115, source: 1,
                text: "Synthetic.", record: "", path: invalid))
        }
    }

    func testNativeFormatSave_IsExplicitTaggedPreferenceNotHistoryOrClipboardAccess() throws {
        let message = try DesktopVoiceSourceMessage(action: 118, source: -1, text: "mp3",
            record: "format", path: "audio-format")
        XCTAssertEqual(message, .audioFormat("mp3"))
        XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: 0, text: "mp3",
            record: "format", path: "audio-format"))
        XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "future",
            record: "format", path: "audio-format"))
    }

    func testPublication_ReplacesWholeChosenFileAndFailureKeepsPriorBytesWithoutStagingLeak() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("format-publish-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("synthetic.mp3")
        try Data("prior synthetic bytes".utf8).write(to: destination)
        let replacement = Data([0xFF, 0xF3, 0x90, 0, 1, 2, 3, 4])
        try DesktopVoiceExportPublication.write(replacement, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        let blocked = directory.appendingPathComponent("blocked.m4a")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        XCTAssertThrowsError(try DesktopVoiceExportPublication.write(replacement, to: blocked))
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["synthetic.mp3", "blocked.m4a"])
    }

    func testPublication_PreCommitCancellationKeepsWholePriorBytesAndNoStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-publish-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("synthetic.m4a")
        let prior = Data("prior complete synthetic file".utf8); try prior.write(to: destination)
        let gate = PublicationGate()
        let task = Task {
            await gate.wait()
            try DesktopVoiceExportPublication.write(Data("synthetic replacement".utf8), to: destination)
        }
        task.cancel(); await gate.release()
        do { try await task.value; XCTFail("Cancelled export was committed.") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["synthetic.m4a"])
    }
}

private actor PublicationGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !open { await withCheckedContinuation { waiter = $0 } } }
    func release() { open = true; waiter?.resume(); waiter = nil }
}
