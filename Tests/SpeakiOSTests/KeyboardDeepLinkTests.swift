#if os(iOS)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class KeyboardDeepLinkTests: XCTestCase {
    private struct Context {
        let name: String
        let defaults: UserDefaults
        let store: KeyboardHandoffStore
    }

    func testMatchingRequestOpensKeyboardCapture() throws {
        let context = makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.name) }
        let request = try context.store.createRequest()
        let router = DeepLinkRouter(keyboardStore: context.store)
        let url = try XCTUnwrap(
            URL(string: "justspeaktoit://keyboard?request=\(request.requestID.uuidString)")
        )

        XCTAssertTrue(router.handle(url))
        XCTAssertEqual(router.selectedTab, 0)
        XCTAssertEqual(router.keyboardCaptureRequest?.id, request.requestID)
    }

    func testUnknownRequestCannotOpenCapture() throws {
        let context = makeContext()
        defer { context.defaults.removePersistentDomain(forName: context.name) }
        let router = DeepLinkRouter(keyboardStore: context.store)
        let url = try XCTUnwrap(
            URL(string: "justspeaktoit://keyboard?request=\(UUID().uuidString)")
        )

        XCTAssertFalse(router.handle(url))
        XCTAssertNil(router.keyboardCaptureRequest)
    }

    private func makeContext() -> Context {
        let name = "KeyboardDeepLinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Context(
            name: name,
            defaults: defaults,
            store: KeyboardHandoffStore(defaults: defaults)
        )
    }
}
#endif
