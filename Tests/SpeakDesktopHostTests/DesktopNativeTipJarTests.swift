import SpeakCore
@testable import SpeakDesktopHost
import XCTest

final class DesktopNativeTipJarTests: XCTestCase {
    func testConfigureTipJar_passesCanonicalWebLinksAndThrowsWhenRefused() throws {
        var links: [String] = []
        try DesktopNativeLists.configureTipJar(
            link: { "\(String(cString: $0!)) \(String(cString: $1!))" },
            configure: { links = Array(UnsafeBufferPointer(start: $0, count: $1)); return 0 }
        )
        XCTAssertEqual(links, [
            "GitHub Sponsors https://github.com/sponsors/crmitchelmore", "Ko-fi https://ko-fi.com/crmitchelmore"
        ])
        XCTAssertThrowsError(try DesktopNativeLists.configureTipJar(link: { _, _ in 0 }, configure: { _, _ in 1 }))
    }
}
