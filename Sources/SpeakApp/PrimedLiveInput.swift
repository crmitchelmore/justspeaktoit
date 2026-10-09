@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// The primed microphone a hotkey gesture claims, awaited because the open may
/// still be in flight when the gesture is recognised.
typealias PrimedLiveInputReservation = Task<PrimedLiveInput?, Never>

/// The newest audio a primed engine captured before its session existed.
///
/// Bounded by duration, so a press that is held without a session (or a
/// stalled hand-over) can never grow memory. The tap callback copies each
/// buffer: Core Audio reuses the buffers it hands a tap.
final class PrimerPreRollBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumDuration: TimeInterval
  private var buffers: [AVAudioPCMBuffer] = []
  private var bufferedFrames: AVAudioFramePosition = 0
  private var isCollecting = true
  private var firstSignal: TimeInterval?
  private var consumer: ((AVAudioPCMBuffer) -> Void)?

  init(maximumDuration: TimeInterval) {
    self.maximumDuration = maximumDuration
  }

  func append(_ buffer: AVAudioPCMBuffer, at uptime: TimeInterval) {
    guard buffer.frameLength > 0, let copy = Self.copy(of: buffer) else { return }
    let hasSignal = Self.containsSignal(buffer)
    lock.lock()
    defer { lock.unlock() }
    guard isCollecting else { return }
    if hasSignal, firstSignal == nil {
      firstSignal = uptime
    }
    if let consumer {
      consumer(copy)
      return
    }
    buffers.append(copy)
    bufferedFrames += AVAudioFramePosition(copy.frameLength)
    let limit = AVAudioFramePosition(maximumDuration * copy.format.sampleRate)
    while bufferedFrames > limit, buffers.count > 1 {
      bufferedFrames -= AVAudioFramePosition(buffers.removeFirst().frameLength)
    }
  }

  /// Ignores every later buffer. A removed tap can still deliver one
  /// in-flight callback.
  func stopCollecting() {
    lock.lock()
    defer { lock.unlock() }
    isCollecting = false
    consumer = nil
  }

  /// Keeps the existing tap live through analyzer setup and replay. The lock
  /// serializes replay and tap delivery, including the stateful audio converter.
  func startConsuming(
    preRollBuffers: [AVAudioPCMBuffer],
    using consume: @escaping (AVAudioPCMBuffer) -> Void
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard isCollecting else { return }
    for buffer in preRollBuffers + buffers {
      consume(buffer)
    }
    buffers = []
    bufferedFrames = 0
    consumer = consume
  }

  func drain() -> [AVAudioPCMBuffer] {
    lock.lock()
    defer { lock.unlock() }
    let drained = buffers
    buffers = []
    bufferedFrames = 0
    return drained
  }

  /// Uptime of the first buffer carrying a non-zero sample. Bluetooth headsets
  /// deliver digital silence until their call-quality link is up.
  var firstSignalUptime: TimeInterval? {
    lock.lock()
    defer { lock.unlock() }
    return firstSignal
  }

  var bufferedDuration: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    guard let rate = buffers.first?.format.sampleRate, rate > 0 else { return 0 }
    return Double(bufferedFrames) / rate
  }

  private static func copy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
      return nil
    }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in 0..<min(source.count, destination.count) {
      guard let from = source[index].mData, let into = destination[index].mData else { continue }
      let bytes = min(source[index].mDataByteSize, destination[index].mDataByteSize)
      memcpy(into, from, Int(bytes))
      destination[index].mDataByteSize = bytes
    }
    return copy
  }

  private static func containsSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
    let frames = Int(buffer.frameLength)
    if let channels = buffer.floatChannelData {
      let samples = UnsafeBufferPointer(start: channels[0], count: frames)
      return samples.contains { $0 != 0 }
    }
    if let channels = buffer.int16ChannelData {
      let samples = UnsafeBufferPointer(start: channels[0], count: frames)
      return samples.contains { $0 != 0 }
    }
    return false
  }
}

/// A microphone opened speculatively on hotkey key-down.
///
/// Opening the input at key-down overlaps device warm-up — a Bluetooth headset
/// switching to its call-quality link takes ~0.7 s — with the hold threshold,
/// instead of starting it once the hold is recognised. The running engine is
/// then handed to the session through `LiveInputEngineStore.adopt`, so the live
/// controller captures through it and no second input node is ever built
/// beside an open microphone. Audio heard before the hand-over is kept as
/// pre-roll.
///
/// A press that never becomes a session is closed: the engine stops, the input
/// session ends and nothing else (history, cues, HUD, providers) is touched.
@MainActor
final class PrimedLiveInput {
  struct Handover {
    let engine: AVAudioEngine
    let inputDeviceID: AudioDeviceID
    let inputSession: AudioInputDeviceManager.SessionContext?
    let hooks: LiveInputEngineStore<AVAudioEngine>.AdoptionHooks
  }

  private enum State {
    case open
    case handedOver
    case closed
  }

  let keyDownUptime: TimeInterval
  let startedUptime: TimeInterval
  let inputDeviceID: AudioDeviceID
  private let engine: AVAudioEngine
  private let preRoll: PrimerPreRollBuffer
  private let deviceManager: AudioInputDeviceManager
  private var inputSession: AudioInputDeviceManager.SessionContext?
  private var state = State.open

  private init(
    keyDownUptime: TimeInterval,
    engine: AVAudioEngine,
    inputDeviceID: AudioDeviceID,
    preRoll: PrimerPreRollBuffer,
    deviceManager: AudioInputDeviceManager,
    inputSession: AudioInputDeviceManager.SessionContext
  ) {
    self.keyDownUptime = keyDownUptime
    self.startedUptime = ProcessInfo.processInfo.systemUptime
    self.engine = engine
    self.inputDeviceID = inputDeviceID
    self.preRoll = preRoll
    self.deviceManager = deviceManager
    self.inputSession = inputSession
  }

  /// Selects the preferred input, then starts the standby engine for it (or
  /// builds one when the standby was built for another device) with a
  /// pre-roll tap. Nil when no usable input could be started.
  static func open(
    keyDownUptime: TimeInterval,
    deviceManager: AudioInputDeviceManager,
    standby: LiveInputStandby<AVAudioEngine>,
    preRollDuration: TimeInterval
  ) async -> PrimedLiveInput? {
    let session = await deviceManager.beginUsingPreferredInput()
    guard let deviceID = LiveInputEngines.defaultInputDeviceID() else {
      await deviceManager.endUsingPreferredInput(session: session)
      return nil
    }
    let preRoll = PrimerPreRollBuffer(maximumDuration: preRollDuration)
    let started = await Task.detached(priority: .userInitiated) { () -> AVAudioEngine? in
      let engine = standby.take(matching: deviceID) ?? standby.buildEngine()
      do {
        try startCapturing(engine, into: preRoll)
        return engine
      } catch {
        preRoll.stopCollecting()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return nil
      }
    }.value
    guard let started else {
      await deviceManager.endUsingPreferredInput(session: session)
      return nil
    }
    return PrimedLiveInput(
      keyDownUptime: keyDownUptime,
      engine: started,
      inputDeviceID: deviceID,
      preRoll: preRoll,
      deviceManager: deviceManager,
      inputSession: session
    )
  }

  private nonisolated static func startCapturing(_ engine: AVAudioEngine, into preRoll: PrimerPreRollBuffer) throws {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard audioInputFormatIsUsable(format) else { throw TranscriptionManagerError.noUsableAudioInput }
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      preRoll.append(buffer, at: ProcessInfo.processInfo.systemUptime)
    }
    engine.prepare()
    try engine.start()
  }

  /// Gives the running engine and the input session to a starting session.
  /// Nil once handed over or closed.
  func handOver() -> Handover? {
    guard state == .open else { return nil }
    state = .handedOver
    let session = inputSession
    inputSession = nil
    let preRoll = self.preRoll
    let hooks = LiveInputEngineStore<AVAudioEngine>.AdoptionHooks(
      willHandOut: { engine in
        preRoll.stopCollecting()
        engine.inputNode.removeTap(onBus: 0)
      },
      release: { engine in
        preRoll.stopCollecting()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
      }
    )
    return Handover(engine: engine, inputDeviceID: inputDeviceID, inputSession: session, hooks: hooks)
  }

  func captures(using engine: AVAudioEngine) -> Bool {
    state == .handedOver && self.engine === engine
  }

  /// The analyzer retains the primer tap rather than replacing it, so setup
  /// and pre-roll conversion never leave the running input without a consumer.
  func startConsuming(preRollBuffers: [AVAudioPCMBuffer], using consume: @escaping (AVAudioPCMBuffer) -> Void) {
    preRoll.startConsuming(preRollBuffers: preRollBuffers, using: consume)
  }

  func stopConsuming() {
    preRoll.stopCollecting()
  }

  /// Key-down → first non-silent audio, when any has arrived yet.
  var firstSignalMilliseconds: Int? {
    preRoll.firstSignalUptime.map { Int((($0 - keyDownUptime) * 1000).rounded()) }
  }

  /// Stops the engine and ends the input session of a press that did not
  /// become a session. Returns the stopped engine, whose input node is still
  /// built, for reuse as the next standby. A handed-over input is untouched.
  func close() async -> (engine: AVAudioEngine, inputDeviceID: AudioDeviceID)? {
    guard state == .open else { return nil }
    state = .closed
    let engine = self.engine
    let preRoll = self.preRoll
    await Task.detached(priority: .userInitiated) {
      preRoll.stopCollecting()
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }.value
    _ = preRoll.drain()
    if let session = inputSession {
      inputSession = nil
      await deviceManager.endUsingPreferredInput(session: session)
    }
    return (engine, inputDeviceID)
  }

  var isOpen: Bool { state == .open }
}
