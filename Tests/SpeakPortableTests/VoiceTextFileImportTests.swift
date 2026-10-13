import Foundation
import XCTest
import SpeakCore

final class VoiceTextFileImportTests: XCTestCase {
    func testUTF8AndBOM_RespectExactScalarLimitAndHaveNoHistoryOwner() throws {
        let text = String(repeating: "\u{1F600}", count: VoiceOutputSourceSnapshot.maximumCharacters)
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        XCTAssertEqual(bytes.count, VoiceTextFileImport.maximumBytes)
        XCTAssertEqual(try VoiceTextFileImport.decode(bytes), text)
        let snapshot = try VoiceOutputSourceSnapshot(source: .textFile, text: text, recordID: UUID())
        XCTAssertNil(snapshot.recordID)
        XCTAssertEqual(VoiceOutputSource.textFile.rawValue, 4)
        XCTAssertEqual(VoiceOutputSource.externalSelection.rawValue, 3)
    }

    func testInvalidEmptyAndOversizedFiles_AreRejected() {
        for bytes in [
            Data(), Data(" \n\t".utf8), Data("null\0text".utf8), Data([0xFF]),
            Data(String(repeating: "x", count: 100_001).utf8),
            Data(repeating: 0x61, count: VoiceTextFileImport.maximumBytes + 1)
        ] {
            XCTAssertThrowsError(try VoiceTextFileImport.decode(bytes))
        }
    }

    func testRead_CapturesFileAndDoesNotFollowLaterChanges() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-text-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Synthetic imported text".utf8).write(to: file)
        let snapshot = try await VoiceTextFileImport.read(file)
        try Data("Later file text".utf8).write(to: file)
        XCTAssertEqual(snapshot, "Synthetic imported text")
        let later = try await VoiceTextFileImport.read(file)
        XCTAssertEqual(later, "Later file text")
    }

    func testDirectoryRemoteMissingAndCancelledReads_AreRejected() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/text"))
        for url in [missing, FileManager.default.temporaryDirectory, remote] {
            do {
                _ = try await VoiceTextFileImport.read(url)
                XCTFail("Invalid input was read")
            } catch {
                XCTAssertTrue(error is VoiceTextFileImport.Failure)
            }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VoiceTextFileImport.read(missing)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled input was read")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
