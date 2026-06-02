import AVFoundation
import XCTest

@testable import SpeakApp

final class AudioInputFormatTests: XCTestCase {

  func testUsableFormat_standardMic_isUsable() {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    XCTAssertNotNil(format)
    XCTAssertTrue(audioInputFormatIsUsable(format!))
  }

  func testUsableFormat_stereo_isUsable() {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
    XCTAssertNotNil(format)
    XCTAssertTrue(audioInputFormatIsUsable(format!))
  }

  func testUsableFormat_zeroSampleRate_isNotUsable() {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 0,
        channels: 1,
        interleaved: false
      )
    else {
      // A zero sample rate is itself rejected by AVAudioFormat, which already
      // protects the engine start path, so there is nothing further to assert.
      return
    }
    XCTAssertFalse(audioInputFormatIsUsable(format))
  }
}
