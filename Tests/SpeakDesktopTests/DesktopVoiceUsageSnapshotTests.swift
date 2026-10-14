import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopVoiceUsageSnapshotTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-voice-app")

    func testMissingEmptyAndUnreadable_AreDistinctSourcesNotEmptySuccesses() throws {
        let absent = try collect(data: nil)
        XCTAssertEqual(absent.presence, .missing)
        XCTAssertNil(absent.originalBytes)
        XCTAssertNil(absent.digest)
        XCTAssertEqual(try absent.preparedAppend(), Data("[]".utf8))
        let empty = try collect(data: Data(" \n[]".utf8))
        XCTAssertEqual(empty.presence, .accepted)
        XCTAssertEqual(empty.acceptedLedger?.records, [])
        let access = DesktopVoiceUsageReadAccess { _, _ in throw CocoaError(.fileReadNoPermission) }
        let unreadable = try DesktopVoiceUsageSnapshot.collect(
            appDirectory: root, memory: memory(), access: access, digests: TestSHA256.provider)
        XCTAssertEqual(unreadable.presence, .unreadable)
        XCTAssertNil(unreadable.originalBytes)
        XCTAssertThrowsError(try unreadable.preparedAppend())
    }

    func testCorruptOrUnsupported_RetainsOriginalBytesAndDigestWithoutTypedAcceptance() throws {
        let record = try observation()
        let valid = try XCTUnwrap(String(data: JSONEncoder().encode([record]), encoding: .utf8))
        for data in [
            Data("damaged usage".utf8),
            try XCTUnwrap(valid.data(using: .utf16LittleEndian)),
            Data(valid.replacingOccurrences(of: "\"generate\"", with: "\"unknown-operation\"").utf8)
        ] {
            let snapshot = try collect(data: data)
            XCTAssertEqual(snapshot.presence, .invalid)
            XCTAssertEqual(snapshot.originalBytes, data)
            XCTAssertEqual(snapshot.digest, TestSHA256.hex(data))
            XCTAssertNil(snapshot.acceptedLedger)
            XCTAssertThrowsError(try snapshot.preparedAppend())
        }
    }

    func testCompletedUnsavedAndUnfinishedActive_MetadataRemainSeparateFromDisk() throws {
        let completed = try observation()
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .history, historyRecordID: UUID())
        _ = capture.begin(voice: .groq(GroqTTSCatalog.defaultVoice), inputCharacters: 5, usesSSML: false)
        let state = DesktopVoiceUsageSnapshot.Memory(
            loadedRecords: nil, unsavedRecords: [completed],
            activeCaptures: [.init(records: capture.records)], loadFailed: true,
            warning: "Synthetic load failure", omittedUnsavedObservations: 0)
        let snapshot = try collect(data: Data("[]".utf8), state: state)
        XCTAssertEqual(snapshot.acceptedLedger?.records, [])
        XCTAssertEqual(snapshot.memory.unsavedRecords, [completed])
        XCTAssertEqual(snapshot.memory.activeCaptures.first?.records, capture.records)
        XCTAssertNil(snapshot.memory.activeCaptures.first?.records.first?.audioDuration)
        XCTAssertTrue(snapshot.memory.loadFailed)
        XCTAssertTrue(snapshot.completenessLimitation.contains("may already have lost"))
        XCTAssertEqual(try DesktopVoiceUsageLedger(validating: snapshot.preparedAppend()).records, [completed])
    }

    func testRevalidationReplacementOrGrowth_MakesSourceChangedWithoutOverwriteAuthority() throws {
        let data = Data("[]".utf8)
        let snapshot = try collect(data: data, revalidate: { throw DesktopVoiceUsageReadAccess.Failure.changed })
        XCTAssertEqual(snapshot.presence, .changed)
        XCTAssertEqual(snapshot.originalBytes, data)
        XCTAssertEqual(snapshot.digest, TestSHA256.hex(data))
        XCTAssertNil(snapshot.acceptedLedger)
        XCTAssertThrowsError(try snapshot.preparedAppend())
    }

    func testOversizedRead_RejectsBytesEvenIfInjectedReaderIgnoresBudget() throws {
        let bytes = Data(repeating: 0x20, count: DesktopVoiceUsageLedger.maximumBytes + 1)
        let snapshot = try collect(data: bytes)
        XCTAssertEqual(snapshot.presence, .oversized)
        XCTAssertNil(snapshot.originalBytes)
        XCTAssertNil(snapshot.digest)
        XCTAssertThrowsError(try snapshot.preparedAppend())
    }

    func testSourceAppearanceReplacementAndGrowth_AreRefusedAfterCollection() throws {
        for original in [nil, Data("[]".utf8)] {
            let source = SyntheticVoiceUsageSource(original)
            let snapshot = try DesktopVoiceUsageSnapshot.collect(
                appDirectory: root, memory: memory(), access: source.access, digests: TestSHA256.provider)
            XCTAssertEqual(snapshot.presence, original == nil ? .missing : .accepted)
            source.replace(with: Data("[] ".utf8))
            XCTAssertThrowsError(try snapshot.preparedAppend()) {
                XCTAssertEqual($0 as? DesktopVoiceUsageReadAccess.Failure, .changed)
            }
            XCTAssertEqual(snapshot.originalBytes, original)
        }
        let source = SyntheticVoiceUsageSource(Data("[]".utf8))
        let snapshot = try DesktopVoiceUsageSnapshot.collect(
            appDirectory: root, memory: memory(), access: source.access, digests: TestSHA256.provider)
        source.replace(with: Data("[]".utf8))
        XCTAssertThrowsError(try snapshot.preparedAppend())
    }

    func testDigestFailure_PropagatesInsteadOfInventingEmptyEvidence() throws {
        let source = SyntheticVoiceUsageSource(Data("[]".utf8))
        let unavailable = LocalModelDigestProvider(name: "Synthetic unavailable digest") {
            throw LocalModelDigestError.unavailable("Synthetic failure")
        }
        XCTAssertThrowsError(try DesktopVoiceUsageSnapshot.collect(
            appDirectory: root, memory: memory(), access: source.access, digests: unavailable)) {
            XCTAssertEqual($0 as? LocalModelDigestError, .unavailable("Synthetic failure"))
        }
    }

    func testMemoryOverflow_IsExplicitAndNeverPreparedAsComplete() throws {
        let state = DesktopVoiceUsageSnapshot.Memory(
            loadedRecords: [], unsavedRecords: [], activeCaptures: [], loadFailed: false,
            warning: nil, omittedUnsavedObservations: 3, unsavedProblem: "Synthetic overflow")
        let snapshot = try collect(data: nil, state: state)
        XCTAssertEqual(snapshot.memory.omittedUnsavedObservations, 3)
        XCTAssertEqual(snapshot.memory.unsavedProblem, "Synthetic overflow")
        XCTAssertThrowsError(try snapshot.preparedAppend()) {
            XCTAssertEqual($0 as? DesktopVoiceUsageSnapshot.Failure, .incompleteMemory)
        }

    }

    func testMissingSourceDoesNotSilentlyEraseLoadedMemoryDuringPreparation() throws {
        let state = DesktopVoiceUsageSnapshot.Memory(
            loadedRecords: [try observation()], unsavedRecords: [], activeCaptures: [], loadFailed: false,
            warning: nil, omittedUnsavedObservations: 0)
        let snapshot = try collect(data: nil, state: state)
        XCTAssertEqual(snapshot.memory.loadedRecords?.count, 1)
        XCTAssertThrowsError(try snapshot.preparedAppend()) {
            XCTAssertEqual($0 as? DesktopVoiceUsageSnapshot.Failure, .unreconciledMemory)
        }
    }

    func testCancellationDuringReceiptValidation_IsNotReportedAsUnreadableOrChanged() async throws {
        let task = Task {
            try collect(data: Data("[]".utf8), revalidate: {
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            })
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation returned a success-shaped source state")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func collect(
        data: Data?, state: DesktopVoiceUsageSnapshot.Memory? = nil,
        revalidate: @escaping @Sendable () throws -> Void = {}
    ) throws -> DesktopVoiceUsageSnapshot {
        let root = root
        let access = DesktopVoiceUsageReadAccess { suppliedRoot, maximumBytes in
            XCTAssertEqual(suppliedRoot, root)
            XCTAssertEqual(maximumBytes, 2_097_152)
            return .init(data: data, revalidate: revalidate)
        }
        return try DesktopVoiceUsageSnapshot.collect(
            appDirectory: root, memory: state ?? memory(), access: access, digests: TestSHA256.provider)
    }

    private func memory() -> DesktopVoiceUsageSnapshot.Memory {
        .init(loadedRecords: nil, unsavedRecords: [], activeCaptures: [], loadFailed: false,
              warning: nil, omittedUnsavedObservations: 0)
    }

    private func observation() throws -> VoiceSynthesisUsage.Record {
        let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
        let id = capture.begin(voice: .groq(GroqTTSCatalog.defaultVoice), inputCharacters: 12, usesSSML: false)
        capture.finish(id, outcome: .completed, audioDuration: 0.1)
        return try XCTUnwrap(capture.records.first)
    }
}

private final class SyntheticVoiceUsageSource: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var generation = UUID()

    init(_ bytes: Data?) { self.bytes = bytes }

    func replace(with bytes: Data) {
        lock.withLock { self.bytes = bytes; generation = UUID() }
    }

    var access: DesktopVoiceUsageReadAccess {
        .init { [self] _, _ in
            let receipt = lock.withLock { (bytes, generation) }
            return .init(data: receipt.0, revalidate: { [self] in
                guard lock.withLock({ generation == receipt.1 && bytes == receipt.0 }) else {
                    throw DesktopVoiceUsageReadAccess.Failure.changed
                }
            })
        }
    }
}
