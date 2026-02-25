import SnapshotTesting
import SwiftUI
import XCTest

@testable import SpeakApp

final class ViewSnapshotTests: XCTestCase {
    func testSnapshotInfrastructure_works() {
        withSnapshotTesting(record: .missing) {
            let view = Text("Snapshot testing works")
                .frame(width: 300, height: 100)

            assertSnapshot(
                of: NSHostingController(rootView: view),
                as: .image(size: CGSize(width: 300, height: 100))
            )
        }
    }
}
