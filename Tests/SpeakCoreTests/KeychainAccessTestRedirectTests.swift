#if os(macOS)
import Foundation
@testable import SpeakCore
import XCTest

/// Native CI must never run credential tests against a build that ignores its
/// private Keychain and falls through to the desktop vault (#1360).
final class KeychainAccessTestRedirectTests: XCTestCase {
    func testNativeCIProductsCompileTheTestRedirect() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JSTI_TEST_KEYCHAIN_PATH"] != nil || environment["RUNNER_ENVIRONMENT"] == "self-hosted" else {
            throw XCTSkip("Only native CI and private-Keychain runs require the test redirect")
        }
        XCTAssertTrue(
            KeychainAccess.isTestRedirectCompiled,
            "Build native CI test products with JSTI_TEST_KEYCHAIN_REDIRECT=1"
        )
    }
}
#endif
