import AppKit
import SwiftUI
import XCTest

@testable import SpeakApp

final class SpeakAppTests: XCTestCase {
    @MainActor
    func testMainView_isComposableWithEnvironment() {
        let environment = WireUp.bootstrap()
        let view = MainView().environmentObject(environment)
        let hostingView = NSHostingView(rootView: view)
        XCTAssertNotNil(hostingView)
    }
}
