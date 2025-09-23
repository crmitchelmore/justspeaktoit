import XCTest
@testable import SpeakApp

final class SpeakAppTests: XCTestCase {
    func testContentView_body_isComposable() {
        let view = ContentView()
        _ = view.body
    }
}
