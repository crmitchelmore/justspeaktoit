import Foundation
import XCTest

import SpeakCore

/// External-consumer compile fixture (issue #680): code written against the
/// pre-#628 exported `SpeakCore` API must keep compiling through the
/// deprecated shims. This file deliberately uses the plain `import` (no
/// `@testable`) and only the public surface, exactly as an external SwiftPM
/// consumer would.
@available(*, deprecated, message: "Exercises deprecated compatibility shims on purpose")
final class PublicAPICompatibilityFixtureTests: XCTestCase {
    func testSpeakErrorMessage_userMessage_keepsThePre628CallShape() {
        let network = SpeakErrorMessage.userMessage(for: URLError(.notConnectedToInternet))
        XCTAssertFalse(network.title.isEmpty)
        XCTAssertFalse(network.message.isEmpty)
        _ = network.action

        let keychain = SpeakErrorMessage.userMessage(for: SecureStorageError.valueNotFound)
        XCTAssertFalse(keychain.title.isEmpty)
    }

}
