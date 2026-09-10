import CryptoKit
import XCTest
@testable import SpeakCore

/// Issue #1020. Two rules hold everything here together:
///
/// 1. Every way an import can fail says which one it was, so the Share Sheet
///    never dismisses itself on a recording it did not read.
/// 2. **The user's file is never modified.** Each staging test hashes the
///    source before and after, including on the paths that fail.
final class SharedAudioImportTests: XCTestCase {
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedAudioImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Acceptance

    func testAcceptsASupportedRecording() throws {
        let acceptance = try SharedAudioImport.evaluate(
            SharedAudioCandidate(filename: "New Recording 12.m4a", byteCount: 4_096)
        )
        XCTAssertEqual(acceptance.filename, "New Recording 12.m4a")
        XCTAssertEqual(acceptance.fileExtension, "m4a")
        XCTAssertEqual(acceptance.byteCount, 4_096)
    }

    func testExtensionIsNormalisedSoAnUppercasedNameIsStillAccepted() throws {
        let acceptance = try SharedAudioImport.evaluate(
            SharedAudioCandidate(filename: "MEMO.WAV", byteCount: 12)
        )
        XCTAssertEqual(acceptance.fileExtension, "wav")
    }

    func testEveryFormatTheFileIntentAcceptsIsAlsoAcceptedFromTheShareSheet() throws {
        // One list, so a recording that Shortcuts will transcribe cannot be
        // refused by the Share Sheet or the other way round.
        for fileExtension in AutomationIntentSupport.supportedAudioExtensions {
            XCTAssertNoThrow(
                try SharedAudioImport.evaluate(
                    SharedAudioCandidate(filename: "memo.\(fileExtension)", byteCount: 1)
                ),
                "\(fileExtension) should be accepted"
            )
        }
    }

    // MARK: - Every refusal, and what it says

    func testAFileWithNoExtensionIsRefusedByName() {
        assertRejects(
            SharedAudioCandidate(filename: "voice memo", byteCount: 10),
            with: .missingExtension(filename: "voice memo"),
            saying: ["voice memo", "not changed"]
        )
    }

    func testAnUnsupportedFormatNamesTheFormatAndTheAlternatives() {
        assertRejects(
            SharedAudioCandidate(filename: "clip.mov", byteCount: 10),
            with: .unsupportedType(fileExtension: "mov"),
            saying: [".mov", "m4a", "not changed"]
        )
    }

    func testAnUndownloadedICloudFileIsRefusedBeforeItsSizeOrFormatMatters() {
        // Reported ahead of "empty": an iCloud placeholder has a size the
        // system may report as zero, and telling the user their recording is
        // empty when it is merely elsewhere is the wrong instruction.
        assertRejects(
            SharedAudioCandidate(
                filename: "Walk.m4a",
                byteCount: 0,
                isDownloaded: false,
                isReadable: false
            ),
            with: .notDownloaded(filename: "Walk.m4a"),
            saying: ["not downloaded", "Files app"]
        )
    }

    func testAFileThatCannotBeReadSaysSo() {
        assertRejects(
            SharedAudioCandidate(filename: "Locked.m4a", byteCount: nil, isReadable: false),
            with: .unreadable(filename: "Locked.m4a"),
            saying: ["couldn't be opened"]
        )
    }

    func testAMissingSizeIsUnreadableRatherThanEmpty() {
        assertRejects(
            SharedAudioCandidate(filename: "Odd.m4a", byteCount: nil),
            with: .unreadable(filename: "Odd.m4a")
        )
    }

    func testAZeroByteFileSaysThereIsNoAudioInIt() {
        assertRejects(
            SharedAudioCandidate(filename: "Empty.m4a", byteCount: 0),
            with: .empty(filename: "Empty.m4a"),
            saying: ["empty", "still saving"]
        )
    }

    func testAFileOverTheCapReportsBothSizes() {
        let over = AutomationIntentSupport.maximumAudioFileBytes + 1
        assertRejects(
            SharedAudioCandidate(filename: "Concert.m4a", byteCount: over),
            with: .tooLarge(byteCount: over, limit: AutomationIntentSupport.maximumAudioFileBytes),
            saying: ["limit", "not changed"]
        )
    }

    func testAFileExactlyAtTheCapIsStillAccepted() throws {
        let acceptance = try SharedAudioImport.evaluate(
            SharedAudioCandidate(
                filename: "Long.m4a",
                byteCount: AutomationIntentSupport.maximumAudioFileBytes
            )
        )
        XCTAssertEqual(acceptance.byteCount, AutomationIntentSupport.maximumAudioFileBytes)
    }

    func testCancellationSaysNothingWasTranscribedOrChanged() {
        let message = SharedAudioImportRejection.cancelled.errorDescription ?? ""
        XCTAssertTrue(message.contains("cancelled"), message)
        XCTAssertTrue(message.contains("not changed"), message)
    }

    // MARK: - Staging: streamed, and read-only on the source

    func testStagingCopiesEveryByteWithoutTouchingTheSource() throws {
        // Deliberately several chunks long, so the loop runs more than once.
        let source = try writeRecording(byteCount: SharedAudioImport.stagingChunkBytes * 3 + 17)
        let before = try digest(of: source)
        let destination = directory.appendingPathComponent("staged.m4a")

        let written = try SharedAudioImport.stage(from: source, to: destination)

        XCTAssertEqual(written, SharedAudioImport.stagingChunkBytes * 3 + 17)
        XCTAssertEqual(try digest(of: destination), before)
        XCTAssertEqual(try digest(of: source), before, "the shared recording must be untouched")
    }

    func testStagingAnEmptyFileProducesAnEmptyCopyRatherThanFailing() throws {
        // Emptiness is `evaluate`'s call to make and it has its own message;
        // the copy loop must not also decide, or the two could disagree.
        let source = try writeRecording(byteCount: 0)
        let destination = directory.appendingPathComponent("staged-empty.m4a")
        XCTAssertEqual(try SharedAudioImport.stage(from: source, to: destination), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancellingMidImportRemovesThePartialCopyAndLeavesTheSourceAlone() throws {
        let source = try writeRecording(byteCount: SharedAudioImport.stagingChunkBytes * 4)
        let before = try digest(of: source)
        let destination = directory.appendingPathComponent("staged-cancelled.m4a")

        var chunksSeen = 0
        XCTAssertThrowsError(
            try SharedAudioImport.stage(from: source, to: destination, isCancelled: {
                chunksSeen += 1
                return chunksSeen > 2
            })
        ) { error in
            XCTAssertEqual(error as? SharedAudioImportRejection, .cancelled)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a half-copied recording must not be left where the app would transcribe it"
        )
        XCTAssertEqual(try digest(of: source), before, "the shared recording must be untouched")
    }

    func testStagingAMissingSourceIsUnreadableRatherThanACrash() throws {
        let missing = directory.appendingPathComponent("gone.m4a")
        let destination = directory.appendingPathComponent("staged-missing.m4a")
        XCTAssertThrowsError(try SharedAudioImport.stage(from: missing, to: destination)) { error in
            XCTAssertEqual(error as? SharedAudioImportRejection, .unreadable(filename: "gone.m4a"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Inspection

    func testInspectingAnOrdinaryFileReportsItReadableDownloadedAndSized() throws {
        let source = try writeRecording(byteCount: 128)
        let candidate = SharedAudioImport.inspect(fileURL: source)
        XCTAssertEqual(candidate.byteCount, 128)
        XCTAssertTrue(candidate.isDownloaded)
        XCTAssertTrue(candidate.isReadable)
        XCTAssertEqual(candidate.filename, source.lastPathComponent)
    }

    func testInspectingAMissingFileReportsItUnreadable() {
        let candidate = SharedAudioImport.inspect(
            fileURL: directory.appendingPathComponent("nothing.m4a")
        )
        XCTAssertFalse(candidate.isReadable)
        XCTAssertNil(candidate.byteCount)
        XCTAssertThrowsError(try SharedAudioImport.evaluate(candidate))
    }

    // MARK: - Helpers

    private func assertRejects(
        _ candidate: SharedAudioCandidate,
        with expected: SharedAudioImportRejection,
        saying fragments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try SharedAudioImport.evaluate(candidate), file: file, line: line) {
            XCTAssertEqual($0 as? SharedAudioImportRejection, expected, file: file, line: line)
            let message = ($0 as? LocalizedError)?.errorDescription ?? ""
            for fragment in fragments {
                XCTAssertTrue(
                    message.localizedCaseInsensitiveContains(fragment),
                    "\"\(message)\" should mention \"\(fragment)\"",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func writeRecording(byteCount: Int) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        var bytes = Data(count: byteCount)
        for index in stride(from: 0, to: byteCount, by: 7) {
            bytes[index] = UInt8(index % 251)
        }
        try bytes.write(to: url)
        return url
    }

    private func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The size a file was when it was inspected is a snapshot. Staging must hold
/// the copy to it rather than trust it, or a file that grows in between is
/// copied past the limit and advertised at the wrong length.
final class SharedAudioStagingBoundsTests: XCTestCase {
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSource(bytes: Int, named name: String = "memo.m4a") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func testAnUnchangedFileStagesExactly() throws {
        let source = try makeSource(bytes: 200_000)
        let destination = directory.appendingPathComponent("copy.m4a")
        let written = try SharedAudioImport.stage(
            from: source,
            to: destination,
            expectedByteCount: 200_000
        )
        XCTAssertEqual(written, 200_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    /// The snapshot said 100 bytes; the file is a megabyte by the time it is
    /// copied. The copy must stop, not run to EOF.
    func testAFileThatGrewAfterInspectionIsRefusedAndNotLeftStaged() throws {
        let source = try makeSource(bytes: 1_000_000)
        let destination = directory.appendingPathComponent("copy.m4a")
        XCTAssertThrowsError(
            try SharedAudioImport.stage(from: source, to: destination, expectedByteCount: 100)
        ) { error in
            XCTAssertEqual(
                error as? SharedAudioImportRejection,
                .changedWhileCopying(filename: "memo.m4a")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "an invalid partial copy must not remain staged"
        )
    }

    func testAFileThatShrankAfterInspectionIsRefused() throws {
        let source = try makeSource(bytes: 1_000)
        let destination = directory.appendingPathComponent("copy.m4a")
        XCTAssertThrowsError(
            try SharedAudioImport.stage(from: source, to: destination, expectedByteCount: 5_000)
        ) { error in
            XCTAssertEqual(
                error as? SharedAudioImportRejection,
                .changedWhileCopying(filename: "memo.m4a")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Even with no accepted size, the hard cap still bounds the copy.
    func testTheHardCapBoundsACopyWithNoAcceptedSize() throws {
        let source = try makeSource(bytes: 300_000)
        let destination = directory.appendingPathComponent("copy.m4a")
        XCTAssertThrowsError(
            try SharedAudioImport.stage(
                from: source,
                to: destination,
                expectedByteCount: nil,
                maximumByteCount: 100_000
            )
        ) { error in
            guard case .tooLarge(_, let limit) = error as? SharedAudioImportRejection else {
                return XCTFail("expected tooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 100_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// The source is read-only on every path, including the refused ones.
    func testARefusedCopyLeavesTheSourceUntouched() throws {
        let source = try makeSource(bytes: 50_000)
        let before = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent("copy.m4a")
        _ = try? SharedAudioImport.stage(from: source, to: destination, expectedByteCount: 10)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testEveryRejectionHasAUserFacingMessage() {
        let rejections: [SharedAudioImportRejection] = [
            .missingExtension(filename: "a"),
            .unsupportedType(fileExtension: "zip"),
            .tooLarge(byteCount: 1, limit: 2),
            .notDownloaded(filename: "a"),
            .unreadable(filename: "a"),
            .empty(filename: "a"),
            .cancelled,
            .changedWhileCopying(filename: "a")
        ]
        for rejection in rejections {
            XCTAssertFalse(rejection.errorDescription?.isEmpty ?? true, "\(rejection) has no message")
        }
    }
}
