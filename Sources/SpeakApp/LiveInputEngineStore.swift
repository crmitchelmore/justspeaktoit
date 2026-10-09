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

  /// Lifecycle callbacks for an engine the store adopted instead of building
  /// (the key-down primer's already-running engine, see `PrimedLiveInput`).
  struct AdoptionHooks {
    /// Runs before the engine reaches a controller, so the controller's own tap
    /// never meets the primer's (a second `installTap` on a bus throws).
    let willHandOut: (Engine) -> Void
    /// Runs when the store drops the engine without handing it out. It must
    /// stop the engine: a running engine holds the microphone open, and a fresh
    /// input node built beside it stalls for seconds on Bluetooth inputs.
    let release: (Engine) -> Void
  }

  private struct Prepared {
    let engine: Engine
    let inputDeviceID: InputDeviceID
    let generation: UInt64
    var hooks: AdoptionHooks?
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
    generation &+= 1
    let retired = prepared
    prepared = nil
    claimed = nil
    let token = Token(generation: generation)
    lock.unlock()
    Self.release(retired)
    return token
  }

  /// Builds an engine and its input node now. Never starts the engine, so the
  /// microphone is not opened here. The engine is kept only when `token` is
  /// still the current preparation and the input device is known.
  func prepare(_ token: Token) {
    let engine = makeFreshEngine()
    primeInput(engine)
    guard let inputDeviceID = currentInputDeviceID() else { return }
    lock.lock()
    guard token.generation == generation else {
      lock.unlock()
      return
    }
    let replaced = prepared
    prepared = Prepared(engine: engine, inputDeviceID: inputDeviceID, generation: token.generation)
    lock.unlock()
    Self.release(replaced)
  }

  /// Installs an engine built (and possibly already started) elsewhere as
  /// `token`'s prepared engine. Returns false — leaving the engine with the
  /// caller, who must release it — when `token` is no longer current.
  @discardableResult
  func adopt(
    _ engine: Engine,
    inputDeviceID: InputDeviceID,
    token: Token,
    hooks: AdoptionHooks
  ) -> Bool {
    lock.lock()
    guard token.generation == generation else {
      lock.unlock()
      return false
    }
    let replaced = prepared
    prepared = Prepared(
      engine: engine,
      inputDeviceID: inputDeviceID,
      generation: token.generation,
      hooks: hooks
    )
    lock.unlock()
    Self.release(replaced)
    return true
  }

  /// The prepared engine when it still matches the current input device;
  /// otherwise a new engine. A prepared engine is handed out once. The analyzer
  /// can retain the adopted tap and atomically redirect its pre-roll consumer.
  func makeEngine(preservingAdoptedTap: Bool = false) -> Engine {
    let deviceID = currentInputDeviceID()
    lock.lock()
    let entry = prepared
    prepared = nil
    let usable = entry.flatMap { entry in
      deviceID == entry.inputDeviceID && entry.generation == generation ? entry : nil
    }
    claimed = usable
    lock.unlock()
    if let usable {
      if !preservingAdoptedTap {
        usable.hooks?.willHandOut(usable.engine)
      }
      return usable.engine
    }
    // Stopped before the fresh build: an adopted engine may still hold the
    // microphone open, and the fresh input node must not be built beside it.
    Self.release(entry)
    return makeFreshEngine()
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
  ///
  /// - Parameter releasingClaimed: also release an *adopted* engine a
  ///   controller claimed. Pass it only when the start failed or was abandoned:
  ///   a controller that threw before capture may have left the primer's
  ///   running engine open, and nothing else would ever stop it.
  func discard(_ token: Token, releasingClaimed: Bool = false) {
    lock.lock()
    guard token.generation == generation else {
      lock.unlock()
      return
    }
    let retired = prepared
    let abandoned = releasingClaimed ? claimed : nil
    prepared = nil
    claimed = nil
    lock.unlock()
    Self.release(retired)
    Self.release(abandoned)
  }

  /// Hooks run outside the lock: stopping an engine can block on Core Audio.
  private static func release(_ entry: Prepared?) {
    guard let entry, let hooks = entry.hooks else { return }
    hooks.release(entry.engine)
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
  private let primed: PrimedLiveInputReservation?

  /// - Parameter primed: the microphone the hotkey press already opened, if
  ///   any. Its running engine is handed on instead of building a new one.
  init(
    deviceManager: AudioInputDeviceManager,
    engines: LiveInputEngineStore<AVAudioEngine>,
    primed: PrimedLiveInputReservation? = nil
  ) {
    self.deviceManager = deviceManager
    self.engines = engines
    self.primed = primed
  }

  func prepare() async {
    // Taken before any suspension, so token order is start order: an older
    // start resuming late can never retire a newer start's preparation.
    let token = engines.beginPreparation()
    self.token = token
    if await adoptPrimedInput(token: token) { return }
    if inputSession == nil {
      inputSession = await deviceManager.beginUsingPreferredInput()
    }
    let engines = self.engines
    // Building the input node blocks for 100–300 ms; keep it off the main
    // thread so the HUD stays responsive. The token stops this build from
    // installing its engine if a newer start has begun meanwhile.
    await Task.detached(priority: .userInitiated) { engines.prepare(token) }.value
  }

  /// Hands the key-down primer's running engine, and the input session it
  /// opened, to this start. The primer's microphone is already open, so this
  /// start must never build an input node of its own beside it.
  private func adoptPrimedInput(token: LiveInputEngineStore<AVAudioEngine>.Token) async -> Bool {
    guard let primed, let capture = await primed.value, let handover = capture.handOver() else {
      return false
    }
    if inputSession == nil {
      inputSession = handover.inputSession
    } else if let extra = handover.inputSession {
      await deviceManager.endUsingPreferredInput(session: extra)
    }
    if engines.adopt(handover.engine, inputDeviceID: handover.inputDeviceID, token: token, hooks: handover.hooks) {
      return true
    }
    // A newer start owns the store. Stop the primed engine before this start
    // falls back to building its own input node.
    handover.hooks.release(handover.engine)
    return false
  }

  /// Releases the input session and any engine no controller claimed. Safe to
  /// call more than once.
  ///
  /// - Parameter startFailed: the start failed or was abandoned. An adopted
  ///   (already running) engine a controller claimed is then stopped too, in
  ///   case that controller threw before taking ownership of it.
  func finish(startFailed: Bool = false) async {
    if let token {
      engines.discard(token, releasingClaimed: startFailed)
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

  /// The idle engine the key-down primer starts (see `PrimedLiveInput`).
  static let standby = LiveInputStandby<AVAudioEngine>(
    makeEngine: {
      let engine = AVAudioEngine()
      _ = engine.inputNode
      return engine
    },
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
