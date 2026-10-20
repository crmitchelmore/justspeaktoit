import Foundation
import SpeakDesktopHost
import XCTest

final class DesktopHostAPIKeyCancellationTests: XCTestCase {
    func testCancelledRequests_NeverReadValidateOrReplaceTheSavedKey() async throws {
        FakeLog.shared.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("api-keys-\(UUID())")
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let identifier = "openrouter.apiKey"
        FakeLog.shared.setKey("synthetic-preserved", name: identifier)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Cancelled request read secure storage") }
        FakeLog.shared.installKeyWriteHook { _, _ in XCTFail("Cancelled request wrote secure storage") }
        let messages = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let saved = await controller.saveAPIKey(identifier: identifier, key: "synthetic-new")
            let removed = await controller.removeAPIKey(identifier: identifier)
            let checked = await controller.validateAPIKey(identifier: identifier, typed: "")
            return [saved, removed, checked]
        }.value
        XCTAssertEqual(messages, Array(repeating: "The API key request was cancelled.", count: 3))
        await controller.close()
        FakeLog.shared.reset()
        try FileManager.default.removeItem(at: directory)
    }
}
