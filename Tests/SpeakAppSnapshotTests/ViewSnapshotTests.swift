import SnapshotTesting
import SwiftUI
import XCTest

@testable import SpeakApp

final class ViewSnapshotTests: XCTestCase {

    /// CI renders fonts/colours differently to local machines, so always
    /// re-record there. Locally we compare against the committed reference.
    private var recordMode: SnapshotTestingConfiguration.Record {
        ProcessInfo.processInfo.environment["CI"] != nil ? .all : .missing
    }

    func testSnapshotInfrastructure_works() {
        withSnapshotTesting(record: recordMode) {
            let view = Text("Snapshot testing works")
                .frame(width: 300, height: 100)

            assertSnapshot(
                of: NSHostingController(rootView: view),
                as: .image(size: CGSize(width: 300, height: 100))
            )
        }
    }
}
