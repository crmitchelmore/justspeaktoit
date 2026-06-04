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
    // A stale HAL input node reports a 0 Hz format. AVAudioFormat does build
    // such an instance, so the helper must reject it.
    let format = AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)
    XCTAssertNotNil(format)
    XCTAssertFalse(audioInputFormatIsUsable(format!))
  }

  func testUsableFormat_zeroChannels_isNotUsable() {
    // A stale input node can also report 0 channels; build one via an ASBD.
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 0,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    let format = AVAudioFormat(streamDescription: &asbd)
    XCTAssertNotNil(format)
    XCTAssertFalse(audioInputFormatIsUsable(format!))
  }

  func testAudioInputStartError_avfaudioBadDevice_mapsToNoUsableInput() {
    let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: 560_227_702)
    let normalised = normalisedAudioInputStartError(error)

    XCTAssertEqual(normalised as? TranscriptionManagerError, .noUsableAudioInput)
  }

  func testAudioInputStartError_underlyingBadDevice_mapsToNoUsableInput() {
    let underlying = NSError(domain: NSOSStatusErrorDomain, code: 560_227_702)
    let error = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: underlying])
    let normalised = normalisedAudioInputStartError(error)

    XCTAssertEqual(normalised as? TranscriptionManagerError, .noUsableAudioInput)
  }

  func testAudioInputStartError_unrelatedError_isPreserved() {
    let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: -1)
    let normalised = normalisedAudioInputStartError(error) as NSError

    XCTAssertEqual(normalised.domain, error.domain)
    XCTAssertEqual(normalised.code, error.code)
  }
}
