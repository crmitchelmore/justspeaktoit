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

  func testAudioInputStartError_avfaudioBadDevice_mapsToNoUsableInput() {
    let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: 560_227_702)
    let normalised = normalisedAudioInputStartError(error)

    guard case TranscriptionManagerError.noUsableAudioInput = normalised else {
      return XCTFail("Expected noUsableAudioInput, got \(normalised)")
    }
  }

  func testAudioInputStartError_underlyingBadDevice_mapsToNoUsableInput() {
    let underlying = NSError(domain: NSOSStatusErrorDomain, code: 560_227_702)
    let error = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: underlying])
    let normalised = normalisedAudioInputStartError(error)

    guard case TranscriptionManagerError.noUsableAudioInput = normalised else {
      return XCTFail("Expected noUsableAudioInput, got \(normalised)")
    }
  }

  func testAudioInputStartError_unrelatedError_isPreserved() {
    let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: -1)
    let normalised = normalisedAudioInputStartError(error) as NSError

    XCTAssertEqual(normalised.domain, error.domain)
    XCTAssertEqual(normalised.code, error.code)
  }
}
