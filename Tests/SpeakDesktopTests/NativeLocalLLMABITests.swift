import Foundation
import XCTest
import CLlamaCpp

final class NativeLocalLLMABITests: XCTestCase {
    func testCancelledRunNeverOpensALibraryOrModelAndReturnsNoText() throws {
        let run = try XCTUnwrap(jsti_llama_run_create())
        defer { jsti_llama_run_destroy(run) }
        jsti_llama_run_cancel(run)
        XCTAssertEqual(jsti_llama_run_is_cancelled(run), 1)
        var output: UnsafeMutablePointer<CChar>?
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        let result = jsti_llama_run_complete(
            run, "must-not-open-library", "must-not-open-model", 96,
            { _, _, _ in XCTFail("Cancelled run verified a model"); return 1 }, nil,
            "Exact system", "Exact user", 0, &output, &error, capacity
        )
        defer { if let output { jsti_llama_string_free(output) } }
        XCTAssertEqual(result, 2)
        XCTAssertNil(output)
        XCTAssertTrue(String(cString: error).contains("cancelled"))
    }

    func testInvalidNativeRequestFailsBeforeAnyProviderOrFileAccess() {
        var output: UnsafeMutablePointer<CChar>?
        var error = [CChar](repeating: 0, count: 128)
        let capacity = error.count
        let result = jsti_llama_run_complete(
            nil, nil, nil, 0, nil, nil, nil, nil, .nan, &output, &error, capacity
        )
        XCTAssertEqual(result, 1)
        XCTAssertNil(output)
        XCTAssertEqual(String(cString: error), "Invalid local cleanup request.")
    }
}
