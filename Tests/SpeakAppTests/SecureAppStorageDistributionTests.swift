import SpeakCore
import XCTest

@testable import SpeakApp

final class SecureAppStorageDistributionTests: XCTestCase {
    func testDistributionChannels_useSeparateKeychainNamespaces() {
        let directService = SecureAppStorage.defaultKeychainService(for: .direct)
        let appStoreService = SecureAppStorage.defaultKeychainService(for: .appStore)

        XCTAssertEqual(directService, "com.justspeaktoit.credentials")
        XCTAssertEqual(appStoreService, "com.justspeaktoit.appstore.credentials")
        XCTAssertNotEqual(directService, appStoreService)
    }
}
