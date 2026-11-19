import XCTest

@testable import SpeakApp

#if !APP_STORE
final class SherpaOnnxSidecarOutputTests: XCTestCase {
  func testEventStream_holdsAPartialLineUntilItsNewlineArrives() {
    var stream = SherpaOnnxSidecarEventStream()

    XCTAssertEqual(stream.append(Data(#"{"type":"partial","te"#.utf8)), [])
    let events = stream.append(Data((#"xt":"hello"}"# + "\n").utf8))

    XCTAssertEqual(events, [SherpaOnnxSidecarEvent(type: "partial", text: "hello", message: nil)])
    XCTAssertNil(stream.flush())
  }

  func testEventStream_dropsNonEventLinesAndKeepsOrder() {
    var stream = SherpaOnnxSidecarEventStream()
    let output = """
    loading model…
    {"type":"partial","text":"a"}

    {"type":"error","message":"boom"}

    """

    let events = stream.append(Data(output.utf8))

    XCTAssertEqual(events.map(\.type), ["partial", "error"])
    XCTAssertEqual(events.last?.message, "boom")
  }

  func testEventStream_flushDecodesTheUnterminatedFinalLineOnce() {
    var stream = SherpaOnnxSidecarEventStream()
    _ = stream.append(Data(#"  {"type":"session_final","text":"done"}  "#.utf8))

    XCTAssertEqual(stream.flush(), SherpaOnnxSidecarEvent(type: "session_final", text: "done", message: nil))
    XCTAssertNil(stream.flush())
  }

  func testErrorSink_keepsTheNewestBytesWithoutAnOrphanedContinuation() {
    let sink = SherpaOnnxSidecarErrorSink(maxByteCount: 3)
    sink.append(Data("ab".utf8))
    // "é" is two bytes; the cap cuts between them, leaving a continuation byte.
    sink.append(Data("é12".utf8))

    XCTAssertEqual(sink.drainText(), "12")
    XCTAssertEqual(sink.drainText(), "")
  }
}
#endif
