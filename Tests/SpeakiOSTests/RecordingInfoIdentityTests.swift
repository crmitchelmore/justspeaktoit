#if os(iOS)
import Foundation
import XCTest

@testable import SpeakiOSLib

/// Listed recordings must keep a stable identity across refreshes (issue #705
/// review): `RecordingInfo` is `Identifiable`, and SwiftUI diffing as well as
/// selection state keyed on `id` break when the same file changes identity.
final class RecordingInfoIdentityTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/var/mobile/Documents/Recordings", isDirectory: true)

    func testStableRecordingID_isDeterministicForTheSameFile() {
        let url = directory.appendingPathComponent("Recording-2026-08-22T10:00:00Z-1A2B3C4D.m4a")
        let first = AudioRecordingPersistence.stableRecordingID(for: url)
        let second = AudioRecordingPersistence.stableRecordingID(for: url)
        XCTAssertEqual(first, second)
        // Only the file name matters, not the directory it was listed from.
        let moved = URL(fileURLWithPath: "/tmp/elsewhere").appendingPathComponent(url.lastPathComponent)
        XCTAssertEqual(AudioRecordingPersistence.stableRecordingID(for: moved), first)
    }

    func testStableRecordingID_differsBetweenFiles() {
        let one = directory.appendingPathComponent("Recording-2026-08-22T10:00:00Z-1A2B3C4D.m4a")
        let two = directory.appendingPathComponent("Recording-2026-08-22T10:00:00Z-1A2B3C4E.m4a")
        XCTAssertNotEqual(
            AudioRecordingPersistence.stableRecordingID(for: one),
            AudioRecordingPersistence.stableRecordingID(for: two)
        )
    }
}
#endif
