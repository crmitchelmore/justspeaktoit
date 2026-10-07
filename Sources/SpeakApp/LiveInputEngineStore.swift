@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Hands live transcription controllers an `AVAudioEngine` whose input node was
/// built *before* the session recorder opened the microphone.
///
/// Every dictation runs two capture clients: the `AVAudioRecorder` that writes
/// the session file and the live controller's `AVAudioEngine` tap. Building the
/// engine's input node while the recorder's capture is coming up makes Core Audio
/// wait for the input route to settle — about three seconds on Bluetooth inputs
/// such as AirPods, measured on the device that reported it. The start cue waits
/// for the stream, so the user heard (and saw) nothing for those three seconds.
///
/// Built before `record()`, the same input node takes ~100–300 ms and the
/// engine then starts beside the running recorder in tens of milliseconds. The
/// start sequencer therefore calls ``prepare()`` before capture, and controllers
/// call ``makeEngine()`` instead of `AVAudioEngine()`.
///
/// A prepared engine is only ever handed out for the input device it was built
/// against and only for a few seconds, so a route change or an abandoned start
/// falls back to a fresh engine — the behaviour before this type existed.
final class LiveInputEngineStore<Engine: AnyObject>: @unchecked Sendable {
  typealias InputDeviceID = UInt32

  static var defaultMaximumAge: TimeInterval { 5 }

  private struct Prepared {
    let engine: Engine
    let preparedAt: TimeInterval
    let inputDeviceID: InputDeviceID?
  }

  private let lock = NSLock()
  private let makeFreshEngine: () -> Engine
  private let primeInput: (Engine) -> Void
  private let currentInputDeviceID: () -> InputDeviceID?
  private let uptime: () -> TimeInterval
  private let maximumAge: TimeInterval
  private var prepared: Prepared?

  init(
    makeEngine: @escaping () -> Engine,
    primeInput: @escaping (Engine) -> Void,
    currentInputDeviceID: @escaping () -> InputDeviceID?,
    uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    maximumAge: TimeInterval = LiveInputEngineStore.defaultMaximumAge
  ) {
    self.makeFreshEngine = makeEngine
    self.primeInput = primeInput
    self.currentInputDeviceID = currentInputDeviceID
    self.uptime = uptime
    self.maximumAge = maximumAge
  }

  /// Builds an engine and its input node now, replacing any earlier one. Never
  /// starts the engine, so the microphone is not opened here.
  func prepare() {
    let engine = makeFreshEngine()
    primeInput(engine)
    let entry = Prepared(engine: engine, preparedAt: uptime(), inputDeviceID: currentInputDeviceID())
    lock.lock()
    prepared = entry
    lock.unlock()
  }

  /// The prepared engine when it still matches the current input device and is
  /// fresh; otherwise a new engine. A prepared engine is handed out once.
  func makeEngine() -> Engine {
    lock.lock()
    let entry = prepared
    prepared = nil
    lock.unlock()

    if let entry,
      uptime() - entry.preparedAt <= maximumAge,
      entry.inputDeviceID == currentInputDeviceID() {
      return entry.engine
    }
    return makeFreshEngine()
  }

  /// Drops a prepared engine no controller claimed.
  func discard() {
    lock.lock()
    prepared = nil
    lock.unlock()
  }

  var hasPreparedEngine: Bool {
    lock.lock()
    defer { lock.unlock() }
    return prepared != nil
  }
}

/// One record-start's use of the shared store.
///
/// The preferred input is selected *before* the engine is prepared, so the
/// prepared input node is bound to the device the recorder and the live
/// controller will both use; that input session is held until the start
/// finishes, by which time both of them have joined it.
@MainActor
final class LiveInputPreparation {
  private let deviceManager: AudioInputDeviceManager
  private let engines: LiveInputEngineStore<AVAudioEngine>
  private var inputSession: AudioInputDeviceManager.SessionContext?

  init(deviceManager: AudioInputDeviceManager, engines: LiveInputEngineStore<AVAudioEngine>) {
    self.deviceManager = deviceManager
    self.engines = engines
  }

  func prepare() async {
    if inputSession == nil {
      inputSession = await deviceManager.beginUsingPreferredInput()
    }
    let engines = self.engines
    // Building the input node blocks for 100–300 ms; keep it off the main
    // thread so the HUD stays responsive.
    await Task.detached(priority: .userInitiated) { engines.prepare() }.value
  }

  /// Releases the input session and any engine no controller claimed. Safe to
  /// call more than once.
  func finish() async {
    engines.discard()
    guard let inputSession else { return }
    self.inputSession = nil
    await deviceManager.endUsingPreferredInput(session: inputSession)
  }
}

enum LiveInputEngines {
  /// Shared by the start sequencer and every macOS live controller.
  static let shared = LiveInputEngineStore<AVAudioEngine>(
    makeEngine: { AVAudioEngine() },
    primeInput: { _ = $0.inputNode },
    currentInputDeviceID: { defaultInputDeviceID() }
  )

  static func defaultInputDeviceID() -> AudioDeviceID? {
    var deviceID = AudioDeviceID()
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )
    return status == noErr ? deviceID : nil
  }
}
