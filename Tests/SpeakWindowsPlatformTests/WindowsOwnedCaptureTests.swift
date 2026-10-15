import CWindowsSupport
import Foundation
import SpeakDesktop
import XCTest
@testable import SpeakWindowsPlatform

final class WindowsOwnedCaptureTests: XCTestCase {
    func testExistingLegacyFramingRingWriterAndCreationFixtures() {
        var error = [CChar](repeating: 0, count: 1024)
        XCTAssertEqual(jsti_native_self_test(&error, error.count), 0, String(cString: error))
    }

    func testNativeOwnedThreadEventAndFinalTailFixtures() throws {
        var error = [CChar](repeating: 0, count: 1024)
        XCTAssertEqual(jsti_owned_capture_self_test(&error, error.count), 0, String(cString: error))
    }

    func testRealSwiftDriverAndBridgeDeliverFixtureFinal73Samples() async throws {
        let worker = DesktopOwnedCaptureWorker(factory: WindowsOwnedCaptureDriverFactory(fixtureFaults: 0))
        let id = UUID()
        let payload = NativeOwnedPayload()
        addTeardownBlock { try await worker.close(id: id) }
        try await worker.open(
            id: id,
            identity: .init(deviceID: "", routeID: "fixture", profileID: "", sampleRate: 24000, frameMilliseconds: 100),
            receive: { payload.append($0) }, onFailure: { payload.fail($0) }
        )
        try await worker.quiesce(id: id)
        XCTAssertEqual(payload.lock.withLock { payload.data.count }, 146)
        XCTAssertTrue(payload.lock.withLock { payload.errors.isEmpty })
    }
}

private final class NativeOwnedPayload: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    var errors: [String] = []
    func append(_ value: Data) { lock.withLock { data.append(value) } }
    func fail(_ value: String) { lock.withLock { errors.append(value) } }
}
