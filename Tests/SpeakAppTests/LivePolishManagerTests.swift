import Foundation
import XCTest

import SpeakCore
@testable import SpeakApp

@MainActor
final class LivePolishManagerTests: XCTestCase {

  /// Regression test: the debounce used to convert milliseconds to a `TimeInterval` and then
  /// truncate it with `UInt64(...)`, so any sub-second interval collapsed to a zero-length sleep
  /// and every partial transcript fired a polish request immediately.
  func testSubSecondDebounceDelaysThePolishRequest() async throws {
    let expectation = expectation(description: "polish requested")
    let client = SpyPolishClient(expectation: expectation)
    let settings = makeSettings()
    settings.livePolishDebounceMs = 200
    settings.livePolishMinDeltaChars = 0
    let manager = LivePolishManager(client: client, settings: settings)

    manager.textDidChange(stableContext: "", tailText: "hello there")

    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(
      client.sendChatCallCount, 0,
      "Polish fired before the 200 ms debounce elapsed"
    )

    await fulfillment(of: [expectation], timeout: 5.0)
    XCTAssertEqual(client.sendChatCallCount, 1)
  }

  func testRapidUpdatesOnlyPolishTheLatestText() async throws {
    let expectation = expectation(description: "polish requested")
    let client = SpyPolishClient(expectation: expectation)
    let settings = makeSettings()
    settings.livePolishDebounceMs = 200
    settings.livePolishMinDeltaChars = 0
    let manager = LivePolishManager(client: client, settings: settings)

    manager.textDidChange(stableContext: "", tailText: "hello")
    try await Task.sleep(for: .milliseconds(50))
    manager.textDidChange(stableContext: "", tailText: "hello there")

    await fulfillment(of: [expectation], timeout: 5.0)
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(client.sendChatCallCount, 1)
    XCTAssertEqual(client.lastUserMessage?.contains("hello there"), true)
  }

  func testZeroDebounceStillPolishes() async throws {
    let expectation = expectation(description: "polish requested")
    let client = SpyPolishClient(expectation: expectation)
    let settings = makeSettings()
    settings.livePolishDebounceMs = 0
    settings.livePolishMinDeltaChars = 0
    let manager = LivePolishManager(client: client, settings: settings)

    manager.textDidChange(stableContext: "", tailText: "hello there")

    await fulfillment(of: [expectation], timeout: 5.0)
    XCTAssertEqual(client.sendChatCallCount, 1)
  }

  private func makeSettings() -> AppSettings {
    let suiteName = "LivePolishManagerTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return AppSettings(defaults: defaults)
  }
}

private final class SpyPolishClient: ChatLLMClient, @unchecked Sendable {
  private let expectation: XCTestExpectation
  private let lock = NSLock()
  private var callCount = 0
  private var userMessage: String?

  var sendChatCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  var lastUserMessage: String? {
    lock.lock()
    defer { lock.unlock() }
    return userMessage
  }

  init(expectation: XCTestExpectation) {
    self.expectation = expectation
  }

  func sendChat(
    systemPrompt: String?,
    messages: [ChatMessage],
    model: String,
    temperature: Double
  ) async throws -> ChatResponse {
    lock.lock()
    callCount += 1
    userMessage = messages.last(where: { $0.role == .user })?.content
    lock.unlock()
    expectation.fulfill()
    return ChatResponse(
      messages: messages + [ChatMessage(role: .assistant, content: "Hello there.")],
      finishReason: "stop",
      cost: nil,
      rawPayload: nil
    )
  }
}
