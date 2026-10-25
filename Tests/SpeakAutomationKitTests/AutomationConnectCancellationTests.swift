#if canImport(Darwin)
import Darwin
import Foundation
import SpeakCore
import XCTest
@testable import SpeakAutomationKit

final class AutomationConnectCancellationTests: XCTestCase {
    func testCancellationDuringRealFullBacklogConnect_DoesNotWaitForRequestDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ac-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("c.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return XCTFail("Fixture socket failed") }
        var fillers: [Int32] = []
        defer {
            for descriptor in fillers { close(descriptor) }
            close(listener)
            try? FileManager.default.removeItem(at: root)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw XCTSkip("Temporary socket path exceeds platform limit")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        for _ in 0..<64 {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { break }
            fillers.append(descriptor)
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, size) }
            }
            if result != 0, [EAGAIN, EINPROGRESS].contains(errno) { break }
        }
        let waiting = expectation(description: "owned connect reached actual backlog wait")
        let returned = expectation(description: "owned connect cancelled promptly")
        let token = AutomationRequestCancellation()
        let client = UnixSocketAutomationClient(socketPath: path, onConnectWait: { waiting.fulfill() })
        let request = AutomationRequest(command: .awaitTranscript, timeout: 600, captureID: UUID().uuidString)
        let operation = Task.detached {
            defer { returned.fulfill() }
            do {
                _ = try client.send(request, cancellation: token)
                XCTFail("No app should answer this fixture")
            } catch { XCTAssertEqual((error as? AutomationError)?.code, .appUnavailable) }
        }
        await fulfillment(of: [waiting], timeout: 2)
        token.cancel()
        await fulfillment(of: [returned], timeout: 2)
        // Cleanup never awaits an unbounded connect; only consume value after its completion receipt.
        _ = operation
    }
}
#endif
