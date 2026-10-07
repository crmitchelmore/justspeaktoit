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
/// against, and only while the record-start that prepared it is still the
/// current one. A route change, an unknown device or an abandoned start falls
/// back to a fresh engine — the behaviour before this type existed.
///
/// Freshness is tied to the start, not to a clock: a cold local model load
/// (FluidAudio, sherpa-onnx) can take many seconds between preparation and the
/// controller claiming the engine, and the engine stays valid for all of it.
final class LiveInputEngineStore<Engine: AnyObject>: @unchecked Sendable {
  typealias InputDeviceID = UInt32

  /// Identifies one record-start's preparation. Only the newest token may
  /// install, restore or discard an engine, so a stale start cannot touch the
  /// state of the start that replaced it.
  struct Token: Equatable, Sendable {
    fileprivate let generation: UInt64
  }

  private struct Prepared {
    let engine: Engine
    let inputDeviceID: InputDeviceID
    let generation: UInt64
  }

  private let lock = NSLock()
  private let makeFreshEngine: () -> Engine
  private let primeInput: (Engine) -> Void
  private let currentInputDeviceID: () -> InputDeviceID?
  private var generation: UInt64 = 0
  private var prepared: Prepared?
  /// The prepared engine most recently handed out, kept so a controller whose
  /// start failed can give it back for a fallback controller (see ``restore(_:)``).
  private var claimed: Prepared?

  init(
    makeEngine: @escaping () -> Engine,
    primeInput: @escaping (Engine) -> Void,
    currentInputDeviceID: @escaping () -> InputDeviceID?
  ) {
    self.makeFreshEngine = makeEngine
    self.primeInput = primeInput
    self.currentInputDeviceID = currentInputDeviceID
  }

  /// Starts a new preparation, retiring any earlier one and its engine.
  func beginPreparation() -> Token {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    prepared = nil
    claimed = nil
    return Token(generation: generation)
  }

  /// Builds an engine and its input node now. Never starts the engine, so the
  /// microphone is not opened here. The engine is kept only when `token` is
  /// still the current preparation and the input device is known.
  func prepare(_ token: Token) {
    let engine = makeFreshEngine()
    primeInput(engine)
    guard let inputDeviceID = currentInputDeviceID() else { return }
    lock.lock()
    defer { lock.unlock() }
    guard token.generation == generation else { return }
    prepared = Prepared(engine: engine, inputDeviceID: inputDeviceID, generation: token.generation)
  }

  /// The prepared engine when it still matches the current input device;
  /// otherwise a new engine. A prepared engine is handed out once.
  func makeEngine() -> Engine {
    let deviceID = currentInputDeviceID()
    lock.lock()
    let entry = prepared
    prepared = nil
    let usable = entry.flatMap { entry in
      deviceID == entry.inputDeviceID && entry.generation == generation ? entry : nil
    }
    claimed = usable
    lock.unlock()
    return usable?.engine ?? makeFreshEngine()
  }

  /// Gives back a prepared engine whose controller failed to start, so the
  /// fallback controller of the same start reuses its already-built input node
  /// instead of building one beside the running recorder. Ignored for any other
  /// engine or once the preparation has ended.
  func restore(_ engine: Engine) {
    lock.lock()
    defer { lock.unlock() }
    guard let claimed, claimed.engine === engine, claimed.generation == generation else { return }
    self.claimed = nil
    prepared = claimed
  }

  /// Drops the engine of `token`'s preparation if no controller claimed it. A
  /// stale token leaves the current preparation untouched.
  func discard(_ token: Token) {
    lock.lock()
    defer { lock.unlock() }
    guard token.generation == generation else { return }
    prepared = nil
    claimed = nil
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
/// finishes, by which time both of them have joined it. Input sessions are
/// reference-counted by `AudioInputDeviceManager`, so releasing an abandoned
/// start's session never ends the session of the start that replaced it.
@MainActor
final class LiveInputPreparation {
  private let deviceManager: AudioInputDeviceManager
  private let engines: LiveInputEngineStore<AVAudioEngine>
  private var inputSession: AudioInputDeviceManager.SessionContext?
  private var token: LiveInputEngineStore<AVAudioEngine>.Token?

  init(deviceManager: AudioInputDeviceManager, engines: LiveInputEngineStore<AVAudioEngine>) {
    self.deviceManager = deviceManager
    self.engines = engines
  }

  func prepare() async {
    // Taken before any suspension, so token order is start order: an older
    // start resuming late can never retire a newer start's preparation.
    let token = engines.beginPreparation()
    self.token = token
    if inputSession == nil {
      inputSession = await deviceManager.beginUsingPreferredInput()
    }
    let engines = self.engines
    // Building the input node blocks for 100–300 ms; keep it off the main
    // thread so the HUD stays responsive. The token stops this build from
    // installing its engine if a newer start has begun meanwhile.
    await Task.detached(priority: .userInitiated) { engines.prepare(token) }.value
  }

  /// Releases the input session and any engine no controller claimed. Safe to
  /// call more than once.
  func finish() async {
    if let token {
      engines.discard(token)
      self.token = nil
    }
    guard let inputSession else { return }
    self.inputSession = nil
    await deviceManager.endUsingPreferredInput(session: inputSession)
  }
}

/// Live controllers that capture through `LiveInputEngines.shared.makeEngine()`.
/// Record-start prepares an engine only when the routed controller conforms;
/// any other route (WhisperKit's own `AudioStreamTranscriber`, unsupported
/// local models) would never claim it.
protocol LiveInputEngineConsumer: AnyObject {}

extension NativeOSXLiveTranscriber: LiveInputEngineConsumer {}
extension AppleSpeechAnalyzerLiveController: LiveInputEngineConsumer {}
extension DeepgramLiveController: LiveInputEngineConsumer {}
extension ModulateLiveController: LiveInputEngineConsumer {}
extension AssemblyAILiveController: LiveInputEngineConsumer {}
extension ElevenLabsLiveController: LiveInputEngineConsumer {}
extension SonioxLiveController: LiveInputEngineConsumer {}
extension CartesiaLiveController: LiveInputEngineConsumer {}
extension GladiaLiveController: LiveInputEngineConsumer {}
extension OpenAIRealtimeLiveController: LiveInputEngineConsumer {}
extension SharedClientLiveController: LiveInputEngineConsumer {}
extension FluidAudioParakeetLiveController: LiveInputEngineConsumer {}
#if !APP_STORE
extension SherpaOnnxLiveController: LiveInputEngineConsumer {}
#endif

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
