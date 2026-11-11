import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

/// The Windows and Linux "System resources in use" glue, over stand-ins for
/// the C structs both window headers declare.
final class DesktopNativeSystemResourcesTests: XCTestCase {
    private struct Row {
        let id, title, reason, caption: String
        let releaseTitle: String?
        let releasing: Int32
    }

    func testShow_HandsTheWindowEveryStringAndFlag() throws {
        let registry = SystemResourceRegistry(now: { Date(timeIntervalSince1970: 1_000) })
        let mic = registry.acquire(
            kind: .microphone, title: "Dictation", reason: "Recording.", owner: "test",
            releaseTitle: "Cancel recording", release: {}
        )
        let presentation = DesktopSystemResources.presentation(
            holds: registry.holds, microphone: .unattributed(since: Date(timeIntervalSince1970: 1_000)),
            osName: "OS", now: Date(timeIntervalSince1970: 1_012)
        )
        var rows: [Row] = []
        var card: [String?] = []
        var flags: [Int32] = []
        DesktopNativeSystemResources.show(
            presentation,
            row: { id, title, reason, caption, release, releasing in
                Row(
                    id: String(cString: id!), title: String(cString: title!), reason: String(cString: reason!),
                    caption: String(cString: caption!), releaseTitle: release.map { String(cString: $0) },
                    releasing: releasing
                )
            },
            view: { headline, warning, empty, microphone, rowPointer, count, releasable in
                (headline, warning, empty, microphone, rowPointer, count, releasable)
            },
            set: { view in
                guard let view = view?.pointee else { return -1 }
                card = [view.0, view.1, view.2, view.3].map { $0.map { String(cString: $0) } }
                rows = Array(UnsafeBufferPointer(start: view.4, count: Int(view.5)))
                flags = [view.5, view.6]
                return 0
            }
        )

        XCTAssertEqual(rows.map(\.title), ["Dictation"])
        XCTAssertEqual(rows.first?.id, registry.holds.first?.id.uuidString)
        XCTAssertEqual(rows.first?.releaseTitle, "Cancel recording")
        XCTAssertEqual(rows.first?.releasing, 0)
        XCTAssertEqual(card, [presentation.headline, presentation.warning, presentation.empty, presentation.microphone])
        XCTAssertNotNil(presentation.warning)
        XCTAssertEqual(flags, [1, 1])
        withExtendedLifetime(mic) {}
    }

    func testMicrophoneProbe_MapsTheNativeAnswer() {
        XCTAssertEqual(DesktopNativeSystemResources.microphoneOpen(1), true)
        XCTAssertEqual(DesktopNativeSystemResources.microphoneOpen(0), false)
        XCTAssertNil(DesktopNativeSystemResources.microphoneOpen(-1))
    }
}
