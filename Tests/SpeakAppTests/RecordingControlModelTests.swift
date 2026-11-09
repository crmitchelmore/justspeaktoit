import Combine
import XCTest

@testable import SpeakApp

/// The main window's record controls must follow recordings started anywhere
/// (hotkey, menu bar, CLI, Shortcuts) and be able to stop them.
@MainActor
final class RecordingControlModelTests: XCTestCase {
  /// Stands in for `MainManager`: sessions can start outside the view and the
  /// toggle stops whichever session is active.
  private final class FakeSessionOwner {
    @Published var state: MainManager.State = .idle
    private(set) var stopCount = 0

    func startFromHotKey() { state = .recording }

    func toggleFromUI() {
      if state == .recording {
        stopCount += 1
        state = .idle
      } else {
        state = .recording
      }
    }
  }

  private func makeModel(for owner: FakeSessionOwner) -> RecordingControlModel {
    RecordingControlModel(statePublisher: owner.$state) { owner.toggleFromUI() }
  }

  func testRecordingStartedOutsideView_isReportedAndStoppedByToggle() {
    let owner = FakeSessionOwner()
    let model = makeModel(for: owner)
    XCTAssertFalse(model.isRecording)

    owner.startFromHotKey()

    XCTAssertEqual(model.state, .recording)
    XCTAssertTrue(model.isRecording)
    XCTAssertEqual(model.accessibility.label, "Stop recording")
    XCTAssertEqual(model.accessibility.value, "Recording")

    model.toggle()

    XCTAssertEqual(owner.stopCount, 1)
    XCTAssertEqual(model.state, .idle)
    XCTAssertFalse(model.isRecording)
    XCTAssertEqual(model.accessibility.label, "Start recording")
    XCTAssertEqual(model.accessibility.value, "Not recording")
  }

  func testModelCreatedMidRecording_startsInRecordingState() {
    let owner = FakeSessionOwner()
    owner.startFromHotKey()

    let model = makeModel(for: owner)

    XCTAssertTrue(model.isRecording)
    model.toggle()
    XCTAssertEqual(owner.stopCount, 1)
    XCTAssertFalse(model.isRecording)
  }

  func testBusyStates_disableControl() {
    let owner = FakeSessionOwner()
    let model = makeModel(for: owner)
    for state: MainManager.State in [.processing, .delivering] {
      owner.state = state
      XCTAssertTrue(model.isBusy, "for state \(state)")
    }
    owner.state = .failed("Network unavailable")
    XCTAssertFalse(model.isBusy)
  }

  func testAppEnvironmentModel_followsMainManagerStateChangedElsewhere() {
    let environment = WireUp.bootstrap(options: makeWireUpTestOptions())
    let model = environment.recordingControl
    XCTAssertFalse(model.isRecording)

    environment.main.state = .recording
    XCTAssertTrue(model.isRecording)

    environment.main.state = .processing
    XCTAssertTrue(model.isBusy)

    environment.main.state = .idle
    XCTAssertFalse(model.isRecording)
    XCTAssertFalse(model.isBusy)
  }
}
