import Foundation
import SpeakDesktop
import XCTest

final class DesktopFilePublicationCopyTests: XCTestCase {
    func testInvalidRemoteNULAndSameURLs_AreRejectedBeforeNativePublication() throws {
        let source = URL(fileURLWithPath: "/synthetic/source.zip")
        let target = URL(fileURLWithPath: "/synthetic/destination.zip")
        let invalid = try XCTUnwrap(URL(string: "https://example.invalid/export.zip"))
        let remoteFile = try XCTUnwrap(URL(string: "file://remote.invalid/export.zip"))
        let nul = URL(fileURLWithPath: "/synthetic/export\u{0000}.zip")
        let directory = URL(fileURLWithPath: "/synthetic/chosen", isDirectory: true)
        let operation = DesktopFilePublication.Copy { _, _ in XCTFail("Invalid input reached native publication.") }
        for pair in [(invalid, target), (source, invalid), (remoteFile, target), (source, remoteFile),
                     (nul, target), (source, nul), (directory, target), (source, directory), (source, source)] {
            XCTAssertThrowsError(try DesktopFilePublication.copy(
                source: pair.0, destination: pair.1, using: operation
            ))
        }
    }

    func testDifferentParentDirectories_AreDelegatedWithoutDeletingSource() throws {
        let source = URL(fileURLWithPath: "/synthetic/private/export.zip")
        let target = URL(fileURLWithPath: "/synthetic/chosen/backup.zip")
        let operation = DesktopFilePublication.Copy {
            XCTAssertEqual($0, source)
            XCTAssertEqual($1, target)
        }
        try DesktopFilePublication.copy(source: source, destination: target, using: operation)
    }

    func testNativeErrors_ArePreservedWithoutRetryOrSuccessFallback() throws {
        let source = URL(fileURLWithPath: "/synthetic/private/export.zip")
        let target = URL(fileURLWithPath: "/synthetic/chosen/backup.zip")
        let operation = DesktopFilePublication.Copy { _, _ in throw PublicationFailure.refused }
        XCTAssertThrowsError(try DesktopFilePublication.copy(source: source, destination: target, using: operation)) {
            XCTAssertEqual($0 as? PublicationFailure, .refused)
        }
    }

    func testCommittedCleanupFailure_RetainsPublishedDestinationIdentity() throws {
        let source = URL(fileURLWithPath: "/synthetic/private/export.zip")
        let target = URL(fileURLWithPath: "/synthetic/chosen/backup.zip")
        let operation = DesktopFilePublication.Copy { _, destination in
            throw DesktopFilePublication.CopyCompletionFailure(
                destination: destination, detail: "Synthetic close error"
            )
        }
        XCTAssertThrowsError(try DesktopFilePublication.copy(source: source, destination: target, using: operation)) {
            let failure = $0 as? DesktopFilePublication.CopyCompletionFailure
            XCTAssertEqual(failure?.destination, target)
            XCTAssertEqual(failure?.detail, "Synthetic close error")
            XCTAssertTrue(failure?.localizedDescription.contains("published file was kept") == true)
        }
    }

    func testPreCancelledCopy_DoesNotInvokeNativePublication() async throws {
        let operation = DesktopFilePublication.Copy { _, _ in XCTFail("Cancelled copy reached native code.") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try DesktopFilePublication.copy(
                source: URL(fileURLWithPath: "/synthetic/source.zip"),
                destination: URL(fileURLWithPath: "/synthetic/target.zip"), using: operation
            )
        }
        do {
            try await task.value
            XCTFail("Cancelled publication succeeded.")
        } catch is CancellationError {}
    }

    func testCancellationAtSuccessfulCommit_DoesNotRelabelPublishedFileAsCancelled() async throws {
        let operation = DesktopFilePublication.Copy { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task {
            try DesktopFilePublication.copy(
                source: URL(fileURLWithPath: "/synthetic/source.zip"),
                destination: URL(fileURLWithPath: "/synthetic/target.zip"), using: operation
            )
        }
        try await task.value
    }
}

private enum PublicationFailure: Error { case refused }
