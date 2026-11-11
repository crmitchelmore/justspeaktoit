import Foundation
import XCTest
@testable import SpeakDesktop

final class NativeCallbackContextTests: XCTestCase {
    private final class Target {}

    func testRegistrationRetainsValueUntilUnregisterThenCallbacksAreNoOps() {
        weak var weakTarget: Target?
        let context: NativeCallbackContext<Target> = {
            let target = Target()
            weakTarget = target
            return NativeCallbackContext(target)
        }()
        let pointer = context.pointer
        XCTAssertNotNil(weakTarget, "the native registration keeps its target alive")
        XCTAssertTrue(NativeCallbackContext<Target>.resolve(pointer) === weakTarget)
        XCTAssertNil(NativeCallbackContext<Target>.resolve(nil))

        context.unregister()
        XCTAssertNil(weakTarget, "unregistering releases the target")
        XCTAssertNil(NativeCallbackContext<Target>.resolve(pointer), "a late callback finds nothing")
        context.unregister()
        context.release()
        context.release()
    }

    func testReleaseFreesTheBoxOnce() {
        weak var weakBox: NativeCallbackContext<Target>?
        do {
            let context = NativeCallbackContext(Target())
            weakBox = context
            context.release()
        }
        XCTAssertNil(weakBox, "release balances the native retain")
    }

    func testScopedContextLivesOnlyForTheSynchronousCall() {
        weak var weakTarget: Target?
        weak var weakBox: NativeCallbackContext<Target>?
        let resolved: Bool = {
            let target = Target()
            weakTarget = target
            return NativeCallbackContext.withScoped(target) { pointer in
                weakBox = Unmanaged<NativeCallbackContext<Target>>.fromOpaque(pointer).takeUnretainedValue()
                return NativeCallbackContext<Target>.resolve(pointer) === target
            }
        }()
        XCTAssertTrue(resolved)
        XCTAssertNil(weakTarget)
        XCTAssertNil(weakBox)
    }

    func testSlotReplacesDetachesAndRejectsRefusedRegistrations() {
        let attached = AttachLog()
        let slot = NativeCallbackSlot<Target> { attached.record($0) }
        let first = Target()
        let second = Target()
        let registration = slot.begin(first)
        XCTAssertNotNil(registration)
        let pointer = registration?.pointer
        let replacement = slot.begin(second)
        XCTAssertNil(NativeCallbackContext<Target>.resolve(pointer), "replacing detaches the previous registration")
        XCTAssertTrue(NativeCallbackContext<Target>.resolve(replacement?.pointer) === second)
        if let registration { XCTAssertTrue(slot.end(registration), "a stale registration is already detached") }
        XCTAssertEqual(attached.calls, [true, false, true])

        attached.refuse = true
        XCTAssertEqual(replacement.map { slot.end($0) }, false, "a refused detach keeps the registration")
        XCTAssertTrue(NativeCallbackContext<Target>.resolve(replacement?.pointer) === second)
        attached.refuse = false
        if let replacement { XCTAssertTrue(slot.end(replacement)) }
        XCTAssertNil(NativeCallbackContext<Target>.resolve(replacement?.pointer))
        attached.refuse = true
        XCTAssertNil(slot.begin(first), "a refused attach registers nothing")
    }
}

private final class AttachLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var refuse = false
    var calls: [Bool] { lock.withLock { recorded } }

    func record(_ context: UnsafeMutableRawPointer?) -> Bool {
        lock.withLock { recorded.append(context != nil) }
        return !refuse
    }
}
