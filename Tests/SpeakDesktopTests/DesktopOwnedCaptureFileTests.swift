import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class DesktopOwnedCaptureFileTests: XCTestCase {
    func testPCMUsesOneHeldWriterAtBothRatesAndRetainsRecoveryAudio() throws {
        for rate in [16_000, 24_000] {
            let writer = CaptureTestWriter()
            let owned = try makeFile(writer)
            let file = try PCMRecordingFile(ownedFile: owned, sampleRate: rate)
            let pcm = Data(repeating: 23, count: rate / 5)
            try file.append(pcm)
            XCTAssertEqual(try file.finish(), 0.1, accuracy: 1e-9)
            XCTAssertEqual(writer.data, PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
            XCTAssertEqual(writer.closes, 1)
            XCTAssertEqual(writer.removals, 0)
            XCTAssertThrowsError(try file.append(Data([0, 0])))
            XCTAssertThrowsError(try file.finish())
            XCTAssertThrowsError(try owned.write(Data()))
            try owned.close()
            XCTAssertEqual(writer.closes, 1)
        }
    }

    func testUnfinishedPCMClosesButDoesNotDiscardAudio() throws {
        let writer = CaptureTestWriter()
        var file: PCMRecordingFile? = try PCMRecordingFile(ownedFile: makeFile(writer))
        try file?.append(Data([1, 0]))
        file = nil
        XCTAssertEqual(writer.closes, 1)
        XCTAssertEqual(writer.removals, 0)
        XCTAssertEqual(writer.data.count, 46)
    }

    func testPCMRejectsReusedCapabilityWithoutClosingOriginalAndRejectsInvalidRateBeforeWriting() throws {
        let writer = CaptureTestWriter()
        let owned = try makeFile(writer)
        XCTAssertThrowsError(try PCMRecordingFile(ownedFile: owned, sampleRate: 44_100))
        XCTAssertTrue(writer.data.isEmpty)
        let file = try PCMRecordingFile(ownedFile: owned)
        XCTAssertThrowsError(try PCMRecordingFile(ownedFile: owned))
        XCTAssertEqual(writer.closes, 0)
        try file.append(Data([1, 0]))
        _ = try file.finish()
        XCTAssertEqual(writer.closes, 1)
        let dirty = CaptureTestWriter()
        let used = try makeFile(dirty)
        try used.write(Data([9, 9]))
        XCTAssertThrowsError(try PCMRecordingFile(ownedFile: used))
        XCTAssertEqual(dirty.data, Data([9, 9]))
        try used.discard()
    }

    func testFailedHeaderDiscardsOnlyUnpublishedFileAndClosesOnce() throws {
        let writer = CaptureTestWriter()
        let owned = try makeFile(writer)
        writer.failure = .write
        XCTAssertThrowsError(try PCMRecordingFile(ownedFile: owned))
        XCTAssertEqual(writer.removals, 1)
        XCTAssertEqual(writer.closes, 1)
        XCTAssertThrowsError(try owned.retain())
    }

    func testFailedAppendAndFinalizationKeepAudioAndCloseOnce() throws {
        for failure in [CaptureTestWriter.Failure.write, .seek, .synchronize, .validate] {
            let writer = CaptureTestWriter()
            let file = try PCMRecordingFile(ownedFile: makeFile(writer))
            try file.append(Data([1, 0]))
            writer.failure = failure
            if failure == .write { XCTAssertThrowsError(try file.append(Data([2, 0]))) }
            XCTAssertThrowsError(try file.finish())
            XCTAssertEqual(writer.removals, 0)
            XCTAssertEqual(writer.closes, 1)
        }
    }

    func testFinishReportsCloseOnlyFailureAndRetainsFinalizedWAV() throws {
        let writer = CaptureTestWriter()
        do {
            let owned = try makeFile(writer)
            let file = try PCMRecordingFile(ownedFile: owned, sampleRate: 24_000)
            let pcm = Data([1, 0, 2, 0])
            try file.append(pcm)
            writer.failure = .close
            XCTAssertThrowsError(try file.finish()) {
                XCTAssertEqual($0 as? CaptureTestWriter.Failure, .close)
            }
            XCTAssertEqual(writer.data, PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
            XCTAssertThrowsError(try file.finish()) {
                guard case RecordingFileError.alreadyClosed = $0 else {
                    return XCTFail("Finish must remain closed after teardown failure: \($0)")
                }
            }
            XCTAssertThrowsError(try owned.discard())
            try owned.close()
        }
        XCTAssertEqual(writer.closes, 1)
        XCTAssertEqual(writer.removals, 0)
    }

    func testFinishPreservesPrimaryAndCloseFailuresAndRetainsAudio() throws {
        for primary in [CaptureTestWriter.Failure.write, .seek, .synchronize, .validate] {
            let writer = CaptureTestWriter()
            do {
                let file = try PCMRecordingFile(ownedFile: makeFile(writer))
                let pcm = Data([1, 0, 2, 0])
                try file.append(pcm)
                writer.failure = primary
                writer.failClose = true
                XCTAssertThrowsError(try file.finish()) {
                    guard let failure = $0 as? RecordingFileCloseFailure else {
                        return XCTFail("Expected both typed errors: \($0)")
                    }
                    XCTAssertEqual(failure.original as? CaptureTestWriter.Failure, primary)
                    XCTAssertEqual(failure.cleanup as? CaptureTestWriter.Failure, .close)
                }
                XCTAssertEqual(writer.data.suffix(pcm.count), pcm)
                XCTAssertThrowsError(try file.finish())
            }
            XCTAssertEqual(writer.closes, 1)
            XCTAssertEqual(writer.removals, 0)
        }
    }

    func testFinishPreservesEarlierAppendFailureWhenHeaderSucceedsButCloseFails() throws {
        let writer = CaptureTestWriter()
        let file = try PCMRecordingFile(ownedFile: makeFile(writer))
        writer.failure = .write
        XCTAssertThrowsError(try file.append(Data([1, 0])))
        writer.failure = nil
        writer.failClose = true
        XCTAssertThrowsError(try file.finish()) {
            guard let failure = $0 as? RecordingFileCloseFailure else {
                return XCTFail("Expected append and close errors: \($0)")
            }
            XCTAssertEqual(failure.original as? CaptureTestWriter.Failure, .write)
            XCTAssertEqual(failure.cleanup as? CaptureTestWriter.Failure, .close)
        }
        XCTAssertEqual(writer.data, PCMWaveWriter.wavData(pcm: Data(), sampleRate: 16_000))
        XCTAssertEqual(writer.closes, 1)
        XCTAssertEqual(writer.removals, 0)
    }

    func testCancelledAdmissionNeverCreatesAndCancelledAllocationCleansUp() throws {
        let writer = CaptureTestWriter()
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(
            in: writer.url.deletingLastPathComponent(), using: .init { _, _, _ in
                XCTFail("Cancelled admission must not allocate.")
                return writer
            }, checkCancellation: { throw CancellationError() }
        ))
        var checks = 0
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(
            in: writer.url.deletingLastPathComponent(), using: .init { _, _, _ in writer },
            checkCancellation: {
                checks += 1
                if checks == 2 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(writer.removals, 1)
        XCTAssertEqual(writer.closes, 1)
    }

    func testExplicitCancellationAndAbandonmentCloseOnce() throws {
        let writer = CaptureTestWriter()
        let owned = try makeFile(writer)
        try owned.discard()
        XCTAssertThrowsError(try owned.discard())
        try owned.close()
        XCTAssertEqual(writer.removals, 1)
        XCTAssertEqual(writer.closes, 1)
        let abandoned = CaptureTestWriter()
        _ = try makeFile(abandoned)
        XCTAssertEqual(abandoned.removals, 1)
        XCTAssertEqual(abandoned.closes, 1)
    }

    func testCancelledAllocationReportsCleanupFailureAndCloses() {
        let writer = CaptureTestWriter()
        var checks = 0
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(
            in: writer.url.deletingLastPathComponent(), using: .init { _, _, _ in writer },
            checkCancellation: {
                checks += 1
                if checks == 2 {
                    writer.failure = .remove
                    throw CancellationError()
                }
            }
        )) {
            guard case DesktopOwnedCaptureError.cleanupFailure = $0 else {
                return XCTFail("Cancellation cleanup must not report success: \($0)")
            }
        }
        XCTAssertEqual(writer.removals, 1)
        XCTAssertEqual(writer.closes, 1)
    }

    func testConcurrentCloseAndCancelHaveOneCleanupOwner() async throws {
        let writer = CaptureTestWriter()
        let owned = try makeFile(writer)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    if index.isMultiple(of: 2) { try? owned.close() } else { try? owned.discard() }
                }
            }
        }
        XCTAssertEqual(writer.removals, 1)
        XCTAssertEqual(writer.closes, 1)
    }

    func testRetainedFileCannotBeCancelledAsUnpublished() throws {
        let writer = CaptureTestWriter()
        let owned = try makeFile(writer)
        try owned.retain()
        XCTAssertThrowsError(try owned.discard())
        try owned.close()
        XCTAssertEqual(writer.removals, 0)
        XCTAssertEqual(writer.closes, 1)
    }

    func testValidationAndCleanupFailuresAreExplicitAndStillClose() throws {
        let writer = CaptureTestWriter()
        writer.failure = .validate
        XCTAssertThrowsError(try makeFile(writer))
        XCTAssertEqual(writer.removals, 1)
        XCTAssertEqual(writer.closes, 1)
        let failedCleanup = CaptureTestWriter()
        let owned = try makeFile(failedCleanup)
        failedCleanup.failure = .remove
        XCTAssertThrowsError(try owned.discard())
        XCTAssertEqual(failedCleanup.closes, 1)
        let failedClose = CaptureTestWriter()
        let closing = try makeFile(failedClose)
        failedClose.failure = .close
        XCTAssertThrowsError(try closing.close())
        try closing.close()
        XCTAssertEqual(failedClose.closes, 1)
    }

    func testUnsupportedAdapterDoesNotPretendToAllocate() {
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(
            in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            using: .init { _, _, _ in throw DesktopOwnedCaptureError.unsupportedPlatform }
        )) {
            guard case DesktopOwnedCaptureError.unsupportedPlatform = $0 else {
                return XCTFail("Expected explicit unsupported adapter: \($0)")
            }
        }
    }

    #if !os(Linux)
    func testUnqualifiedNativeAdapterExplicitlyRejectsCreation() {
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(
            in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )) {
            guard case DesktopOwnedCaptureError.unsupportedPlatform = $0 else {
                return XCTFail("Expected unsupported native allocation: \($0)")
            }
        }
    }
    #endif

    private func makeFile(_ writer: CaptureTestWriter) throws -> DesktopOwnedCaptureFile {
        try DesktopOwnedCaptureFile.create(
            in: writer.url.deletingLastPathComponent(), using: .init { _, _, _ in writer }
        )
    }
}

extension DesktopOwnedCaptureFileTests {
    func testChangedLocationDuringHeaderAdmissionDiscardsOnlyUnpublishedAndDestroysOnce() throws {
        let writer = CaptureTestWriter()
        let owned = try makeFile(writer)
        writer.failValidationAfterWrite = true
        XCTAssertThrowsError(try PCMRecordingFile(ownedFile: owned)) {
            XCTAssertEqual($0 as? CaptureTestWriter.Failure, .validate)
        }
        XCTAssertEqual(writer.removals, 1)
        XCTAssertEqual(writer.closes, 1)
        try owned.close()
        XCTAssertEqual(writer.closes, 1)
    }

    func testNativeCreateFailureDoesNotProduceAnOwnedCapability() {
        XCTAssertThrowsError(try DesktopOwnedCaptureFile.create(
            in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            using: .init { _, _, _ in throw CaptureTestWriter.Failure.create }
        )) { XCTAssertEqual($0 as? CaptureTestWriter.Failure, .create) }
    }
}

private final class CaptureTestWriter: DesktopOwnedCaptureWriter, @unchecked Sendable {
    enum Failure: Error { case create, write, seek, synchronize, validate, remove, close }
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("fake.wav")
    var data = Data()
    var offset = 0
    var closes = 0
    var removals = 0
    var failure: Failure?
    var failClose = false
    var failValidationAfterWrite = false

    func write(_ bytes: Data) throws {
        if failure == .write { throw Failure.write }
        let end = offset + bytes.count
        if data.count < end { data.append(Data(repeating: 0, count: end - data.count)) }
        data.replaceSubrange(offset..<end, with: bytes)
        offset = end
    }

    func seek(toOffset offset: UInt64) throws {
        if failure == .seek { throw Failure.seek }
        self.offset = Int(offset)
    }

    func synchronize() throws {
        if failure == .synchronize { throw Failure.synchronize }
    }

    func validateLocation() throws {
        if failure == .validate || (failValidationAfterWrite && !data.isEmpty) { throw Failure.validate }
    }

    func removeUnpublished() throws {
        removals += 1
        if failure == .remove { throw Failure.remove }
    }

    func close() throws {
        closes += 1
        if failure == .close || failClose { throw Failure.close }
    }
}
