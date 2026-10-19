import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopVoiceUsageLedgerTests: XCTestCase {
    func testAppending_PreservesUnknownMemberBytesSpellingAndArrayOrder() throws {
        let first = try observation()
        let second = try observation()
        let firstBytes = try extendedBytes(first)
        let secondBytes = try extendedBytes(second)
        let original = Data(" \n[".utf8) + firstBytes + Data(", \n".utf8) + secondBytes + Data("]\n".utf8)
        let document = try DesktopVoiceUsageLedger(validating: original)
        XCTAssertEqual(document.originalBytes, original)
        XCTAssertEqual(document.records, [first, second])
        let added = try observation()
        let bytes = try document.appending([added])
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(text.contains(try XCTUnwrap(String(data: firstBytes, encoding: .utf8))))
        XCTAssertTrue(text.contains(try XCTUnwrap(String(data: secondBytes, encoding: .utf8))))
        XCTAssertEqual(try DesktopVoiceUsageLedger(validating: bytes).records, [first, second, added])
    }

    func testRetry_DoesNotDuplicateUUIDOrDiscardPriorRawMembers() throws {
        let record = try observation()
        let raw = try extendedBytes(record)
        let document = try DesktopVoiceUsageLedger(validating: Data([0x5B]) + raw + Data([0x5D]))
        let bytes = try document.appending([record, record])
        XCTAssertEqual(bytes, Data([0x5B]) + raw + Data([0x5D]))
        XCTAssertEqual(try DesktopVoiceUsageLedger(validating: bytes).records.count, 1)
        var conflicting = record
        conflicting.outcome = .cancelled
        XCTAssertThrowsError(try document.appending([conflicting])) { error in
            XCTAssertEqual(error as? DesktopVoiceUsageLedger.Failure, .conflictingIdentity)
        }
        let ambiguous = try DesktopVoiceUsageLedger(validating: JSONEncoder().encode([record, conflicting]))
        XCTAssertThrowsError(try ambiguous.appending([record])) { error in
            XCTAssertEqual(error as? DesktopVoiceUsageLedger.Failure, .conflictingIdentity)
        }
    }

    func testRetention_OnlyDropsOldestElementsAtTheExistingThousandRecordLimit() throws {
        let first = try observation()
        let firstBytes = try extendedBytes(first)
        let originals = try (0..<999).map { _ in try observation() }
        let tail = try JSONEncoder().encode(originals)
        let input = Data([0x5B]) + firstBytes + Data([0x2C]) + tail.dropFirst()
        let document = try DesktopVoiceUsageLedger(validating: input)
        let next = try observation()
        let bytes = try document.appending([next])
        let restored = try DesktopVoiceUsageLedger(validating: bytes)
        XCTAssertEqual(restored.records.count, 1_000)
        XCTAssertEqual(restored.records.first, originals.first)
        XCTAssertEqual(restored.records.last, next)
        XCTAssertFalse(restored.records.contains { $0.id == first.id })
    }

    func testInvalidUnsupportedAndOversizedDocuments_AreNeverAcceptedAsEmpty() throws {
        let record = try observation()
        let json = try XCTUnwrap(String(data: JSONEncoder().encode([record]), encoding: .utf8))
        let utf16 = try XCTUnwrap(json.data(using: .utf16LittleEndian))
        XCTAssertEqual(try JSONDecoder().decode([VoiceSynthesisUsage.Record].self, from: utf16), [record])
        for bytes in [
            Data("not JSON".utf8), Data("{}".utf8), Data("[null]".utf8),
            Data(json.replacingOccurrences(of: "\"generate\"", with: "\"future-operation\"").utf8),
            utf16,
            try XCTUnwrap(json.data(using: .utf16BigEndian)),
            try XCTUnwrap(json.data(using: .utf32LittleEndian)),
            Data(repeating: 0x20, count: DesktopVoiceUsageLedger.maximumBytes + 1)
        ] {
            XCTAssertThrowsError(try DesktopVoiceUsageLedger(validating: bytes))
        }
        let empty = try DesktopVoiceUsageLedger(validating: Data("[]".utf8))
        XCTAssertTrue(empty.records.isEmpty)
        XCTAssertEqual(try empty.appending([]), Data("[]".utf8))
    }

    func testCancelledWork_DoesNotProduceAnArchiveDocument() async throws {
        let bytes = try JSONEncoder().encode([observation()])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DesktopVoiceUsageLedger(validating: bytes)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled decoding returned a document")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func extendedBytes(_ record: VoiceSynthesisUsage.Record) throws -> Data {
        let bytes = try JSONEncoder().encode(record)
        return Data(bytes.dropLast()) + Data(
            #", "future" : { "z":1.2300e+02, "a":["escaped \" quote", {"nested":"],}"}] }}"#.utf8
        )
    }

    private func observation() throws -> VoiceSynthesisUsage.Record {
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        let id = capture.begin(voice: .groq(GroqTTSCatalog.defaultVoice), inputCharacters: 12, usesSSML: false)
        capture.finish(id, outcome: .completed, audioDuration: 0.1)
        return try XCTUnwrap(capture.records.first)
    }
}
