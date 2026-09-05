import Foundation
import XCTest
@testable import SpeakApp

final class ProcessOutputAccumulatorTests: XCTestCase {
  func testCapturePreservesCompleteUTF8ResponseAtLimit() throws {
    let response = Data("{\"text\":\"Café 🎤\"}".utf8)
    let output = ProcessOutputAccumulator(byteLimit: response.count)
    output.captureStdout(from: try inputHandle(containing: response))

    XCTAssertEqual(output.stdout, try XCTUnwrap(String(bytes: response, encoding: .utf8)))
    XCTAssertNil(output.captureError)
  }

  func testCaptureRejectsTruncatedStdout() throws {
    let output = ProcessOutputAccumulator(byteLimit: 8)
    output.captureStdout(from: try inputHandle(containing: Data("123456789".utf8)))

    XCTAssertEqual(output.stdout, "12345678")
    XCTAssertEqual(output.captureError, "Local process output exceeded the 8-byte limit.")
  }

  func testStderrKeepsFailureTailAcrossMultipleReadChunks() throws {
    var data = Data(repeating: 0x61, count: 192 * 1024)
    let failure = "fatal: compilation failed"
    data.append(contentsOf: failure.utf8)
    let output = ProcessOutputAccumulator(byteLimit: failure.utf8.count)
    output.captureStderr(from: try inputHandle(containing: data))

    XCTAssertEqual(output.stderr, "[Earlier process diagnostics omitted]\n" + failure)
    XCTAssertNil(output.captureError)
  }

  func testTruncatedUTF8DiagnosticsRemainReadable() throws {
    let output = ProcessOutputAccumulator(byteLimit: 5)
    output.captureStderr(from: try inputHandle(containing: Data("🎤done".utf8)))

    XCTAssertTrue(output.stderr.hasSuffix("done"))
    XCTAssertTrue(output.stderr.hasPrefix("[Earlier process diagnostics omitted]"))
  }

  func testReadFailureIsReportedInsteadOfSuccessfulEmptyResponse() throws {
    let handle = try inputHandle(containing: Data())
    try handle.close()
    let output = ProcessOutputAccumulator()
    output.captureStdout(from: handle)

    XCTAssertNotNil(output.captureError)
  }

  func testDrainConsumesOutputBeyondLimitSoChildCanExit() throws {
    let process = Process()
    let pipe = Pipe()
    let output = ProcessOutputAccumulator(byteLimit: 1024)
    let exited = expectation(description: "child exits after writing more than pipe capacity")
    let drained = expectation(description: "pipe drains through EOF")
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "head -c 2097152 /dev/zero"]
    process.standardOutput = pipe
    process.terminationHandler = { _ in exited.fulfill() }
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    DispatchQueue.global(qos: .utility).async {
      output.captureStdout(from: pipe.fileHandleForReading)
      drained.fulfill()
    }

    wait(for: [exited, drained], timeout: 10)
    if !process.isRunning { XCTAssertEqual(process.terminationStatus, 0) }
    XCTAssertEqual(output.stdout.utf8.count, 1024)
    XCTAssertNotNil(output.captureError)
  }

  private func inputHandle(containing data: Data) throws -> FileHandle {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return try FileHandle(forReadingFrom: url)
  }
}
