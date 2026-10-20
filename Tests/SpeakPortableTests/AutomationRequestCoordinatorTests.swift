import Foundation
@testable import SpeakCore
import XCTest

final class AutomationRequestCoordinatorTests: XCTestCase {
    func testDeactivationRejectsLateSuccessBeforeStoppedReplyIsPublished() async {
        let coordinator = AutomationRequestCoordinator()
        let entered = expectation(description: "handler entered")
        coordinator.activate { request in
            entered.fulfill()
            try? await Task.sleep(for: .seconds(3_600))
            return .success(id: request.id, command: request.command, result: .init(text: "retired"))
        }
        let request = AutomationRequest(id: "reused", command: .status, timeout: 10)
        let waiter = Task { await coordinator.respond(to: request) }
        await fulfillment(of: [entered], timeout: 2)
        let completed = AutomationCommandCompletionGate()
        coordinator.deactivate { commands in
            XCTAssertEqual(commands.count, 1)
            Task.detached {
                for command in commands { _ = await command.value }
                completed.release()
            }
            XCTAssertTrue(completed.wait(), "The cancelled handler must finish before the stopped reply is published")
        }
        let response = await waiter.value
        XCTAssertEqual(response.error?.code, .appUnavailable)
        XCTAssertNil(response.result)
        coordinator.activate { .success(id: $0.id, command: $0.command, result: .init(text: "current")) }
        let fresh = await coordinator.respond(to: request)
        XCTAssertEqual(fresh.result?.text, "current")
        coordinator.deactivate()
    }
}

private final class AutomationCommandCompletionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var completed = false

    func release() {
        self.condition.lock()
        self.completed = true
        self.condition.broadcast()
        self.condition.unlock()
    }

    func wait() -> Bool {
        self.condition.lock()
        defer { self.condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !self.completed {
            if !self.condition.wait(until: deadline) { return self.completed }
        }
        return true
    }
}
