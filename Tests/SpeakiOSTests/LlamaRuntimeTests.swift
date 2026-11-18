import Foundation
import SpeakiOSLlama
import XCTest

/// The compiled-in llama.cpp runtime (issue #1650) reports a missing or
/// corrupt model as a load failure rather than crashing.
final class LlamaRuntimeTests: XCTestCase {
    func testComplete_missingModelFailsToLoad() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID()).gguf")

        XCTAssertThrowsError(
            try LlamaRuntimeRun().complete(modelFile: missing, system: "s", user: "u", timeout: 5)
        ) { error in
            XCTAssertEqual((error as? LlamaRuntimeError)?.stage, .load)
        }
    }

    func testComplete_corruptModelFailsToLoad() throws {
        let corrupt = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID()).gguf")
        try Data("not a gguf file".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        let run = LlamaRuntimeRun()
        XCTAssertThrowsError(try run.complete(modelFile: corrupt, system: "s", user: "u", timeout: 5)) { error in
            XCTAssertEqual((error as? LlamaRuntimeError)?.stage, .load)
        }
    }
}
