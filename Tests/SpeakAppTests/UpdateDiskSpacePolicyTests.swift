import XCTest

@testable import SpeakApp

/// The free-space guard that runs before a Sparkle update starts.
///
/// A full boot volume used to surface as Sparkle's generic "update error"
/// (2026-09-02): Sparkle stages its download under `~/Library/Caches/...` and
/// fails somewhere inside the pipeline. `UpdaterManager` now refuses the update
/// up front and explains the shortfall; the arithmetic is here.
final class UpdateDiskSpacePolicyTests: XCTestCase {

    private let megabyte: Int64 = 1024 * 1024

    // MARK: - requiredBytes

    func testRequiredBytes_isThreeTimesTheEnclosure_whenAboveTheFloor() {
        let enclosure: UInt64 = 500 * 1024 * 1024
        XCTAssertEqual(
            UpdateDiskSpacePolicy.requiredBytes(for: enclosure),
            1500 * megabyte,
            "Room is needed for the download, the extracted app and the staged copy"
        )
    }

    func testRequiredBytes_fallsBackToTheFloor_forSmallEnclosures() {
        // 3 x 10 MB is well under the 200 MB floor.
        XCTAssertEqual(
            UpdateDiskSpacePolicy.requiredBytes(for: UInt64(10 * megabyte)),
            UpdateDiskSpacePolicy.minimumRequiredBytes
        )
    }

    func testRequiredBytes_usesTheFloor_whenTheAppcastDeclaresNoLength() {
        // contentLength is 0 when the enclosure omits `length`.
        XCTAssertEqual(
            UpdateDiskSpacePolicy.requiredBytes(for: 0),
            UpdateDiskSpacePolicy.minimumRequiredBytes
        )
    }

    func testRequiredBytes_saturatesInsteadOfTrapping_onAbsurdLengths() {
        // A corrupt or hostile appcast must not crash the updater.
        XCTAssertEqual(UpdateDiskSpacePolicy.requiredBytes(for: UInt64.max), Int64.max)
    }

    // MARK: - hasEnoughSpace

    func testHasEnoughSpace_isInclusiveAtTheBoundary() {
        XCTAssertTrue(UpdateDiskSpacePolicy.hasEnoughSpace(available: 100, required: 100))
        XCTAssertTrue(UpdateDiskSpacePolicy.hasEnoughSpace(available: 101, required: 100))
        XCTAssertFalse(UpdateDiskSpacePolicy.hasEnoughSpace(available: 99, required: 100))
    }

    // MARK: - validateFreeSpace

    func testValidateFreeSpace_throws_whenTheVolumeIsTooFull() {
        let enclosure = UInt64(400 * megabyte) // requires 1200 MB
        XCTAssertThrowsError(
            try UpdateDiskSpacePolicy.validateFreeSpace(
                forEnclosureLength: enclosure,
                availableBytes: 300 * megabyte
            )
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, UpdateDiskSpacePolicy.errorDomain)
            XCTAssertEqual(nsError.code, UpdateDiskSpacePolicy.insufficientDiskSpaceCode)
        }
    }

    func testValidateFreeSpace_succeeds_whenThereIsRoom() {
        XCTAssertNoThrow(
            try UpdateDiskSpacePolicy.validateFreeSpace(
                forEnclosureLength: UInt64(400 * megabyte),
                availableBytes: 4 * 1024 * megabyte
            )
        )
    }

    func testValidateFreeSpace_doesNotBlockTheUpdate_whenCapacityIsUnreadable() {
        // A guard that cannot measure must never be the reason an update fails.
        XCTAssertNoThrow(
            try UpdateDiskSpacePolicy.validateFreeSpace(
                forEnclosureLength: UInt64(4 * 1024 * megabyte),
                availableBytes: nil
            )
        )
    }

    // MARK: - The message the user sees

    func testInsufficientSpaceError_saysFreeNeededAndThatNothingStarted() {
        // ByteCountFormatter's .file style is decimal, so these round numbers
        // render exactly as written below.
        let error = UpdateDiskSpacePolicy.insufficientSpaceError(
            available: 300_000_000,
            required: 1_200_000_000
        )
        let description = error.localizedDescription
        XCTAssertTrue(
            description.contains("was not started"),
            "The user must be told the update did not begin: \(description)"
        )
        XCTAssertTrue(
            description.contains("300 MB"),
            "The message must name how much is free: \(description)"
        )
        XCTAssertTrue(
            description.contains("1.2 GB") || description.contains("1,2 GB"),
            "The message must name how much is needed: \(description)"
        )
        XCTAssertTrue(
            description.contains("900 MB"),
            "The message must name the shortfall to free up: \(description)"
        )
        XCTAssertNotNil(error.localizedRecoverySuggestion)
    }

    // MARK: - The real volume

    func testAvailableStagingBytes_readsTheCachesVolume() throws {
        // No fixed expectation about the machine running the tests, only that
        // the capacity is readable and sane — the guard silently disables
        // itself when it is not.
        let available = try XCTUnwrap(
            UpdateDiskSpacePolicy.availableStagingBytes(),
            "The user caches volume should report an important-usage capacity"
        )
        XCTAssertGreaterThanOrEqual(available, 0)
    }
}
