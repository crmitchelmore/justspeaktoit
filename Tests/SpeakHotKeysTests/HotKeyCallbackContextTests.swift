#if os(macOS)
import XCTest

@testable import SpeakHotKeys

final class HotKeyCallbackContextTests: XCTestCase {
    private final class Owner {}

    func testRetainedPointer_keepsTheContextAliveUntilReleased() {
        let owner = Owner()
        weak var weakContext: HotKeyCallbackContext<Owner>?
        let pointer: UnsafeMutableRawPointer = {
            let context = HotKeyCallbackContext(owner: owner)
            weakContext = context
            return context.retainedPointer()
        }()

        XCTAssertNotNil(weakContext, "The registration's reference keeps the userData valid")
        XCTAssertTrue(HotKeyCallbackContext<Owner>.context(from: pointer).owner === owner)

        HotKeyCallbackContext<Owner>.release(pointer)
        XCTAssertNil(weakContext, "Releasing the registration's reference frees the context")
    }

    func testInvalidate_cutsTheOwnerOffBeforeTheRegistrationIsRemoved() {
        let owner = Owner()
        let context = HotKeyCallbackContext(owner: owner)
        let pointer = context.retainedPointer()
        defer { HotKeyCallbackContext<Owner>.release(pointer) }

        context.invalidate()

        XCTAssertNil(HotKeyCallbackContext<Owner>.context(from: pointer).owner)
    }

    func testOwner_isNotRetainedByTheRegistration() {
        var owner: Owner? = Owner()
        let pointer = HotKeyCallbackContext(owner: owner!).retainedPointer()
        defer { HotKeyCallbackContext<Owner>.release(pointer) }

        owner = nil

        XCTAssertNil(HotKeyCallbackContext<Owner>.context(from: pointer).owner)
    }
}
#endif
