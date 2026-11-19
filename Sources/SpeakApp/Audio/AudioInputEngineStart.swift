@preconcurrency import AVFoundation
import Foundation

/// Returns `true` when an `AVAudioEngine` input format describes a usable capture
/// device. A stale or disconnected input device reports zero channels or a zero
/// sample rate, which would otherwise surface as `kAudioHardwareBadDeviceError`
/// (`com.apple.coreaudio.avfaudio error 560227702`) when starting the engine.
func audioInputFormatIsUsable(_ format: AVAudioFormat) -> Bool {
  format.channelCount > 0 && format.sampleRate > 0
}

/// Returns `true` when a tap in `tapFormat` can be installed on an input node
/// whose hardware currently delivers `hardwareFormat`. AVFAudio raises an
/// Objective-C exception, which Swift cannot catch, when the tap's sample rate
/// differs from the hardware's.
func audioInputTapFormatMatchesHardware(_ tapFormat: AVAudioFormat, hardwareFormat: AVAudioFormat) -> Bool {
  audioInputFormatIsUsable(hardwareFormat)
    && tapFormat.sampleRate == hardwareFormat.sampleRate
    && tapFormat.channelCount == hardwareFormat.channelCount
}

private let coreAudioBadDeviceErrorCode = 560_227_702
private let avfaudioErrorDomain = "com.apple.coreaudio.avfaudio"
private let staleInputDeviceRetryDelay: Duration = .milliseconds(200)

func startAudioEngineAfterInputDeviceSettles(_ audioEngine: AVAudioEngine) async throws {
  do {
    audioEngine.prepare()
    try audioEngine.start()
  } catch {
    guard audioInputStartErrorIsBadDevice(error) else {
      throw error
    }

    audioEngine.stop()
    try await Task.sleep(for: staleInputDeviceRetryDelay)

    do {
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      throw normalisedAudioInputStartError(error)
    }
  }
}

func normalisedAudioInputStartError(_ error: Error) -> Error {
  audioInputStartErrorIsBadDevice(error)
    ? TranscriptionManagerError.noUsableAudioInput
    : error
}

func audioInputStartErrorIsBadDevice(_ error: Error) -> Bool {
  let nsError = error as NSError
  if nsError.code == coreAudioBadDeviceErrorCode,
    nsError.domain == avfaudioErrorDomain || nsError.domain == NSOSStatusErrorDomain {
    return true
  }
  if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
    return audioInputStartErrorIsBadDevice(underlying)
  }
  return false
}
