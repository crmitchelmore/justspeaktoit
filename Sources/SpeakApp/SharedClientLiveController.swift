import AVFoundation
import Foundation
import SpeakCore
/// macOS capture/PCM conversion for shared StreamingTranscriptionClient providers.
/// Provider transport and parsing stay in SpeakCore, shared with iOS.
@MainActor
final class SharedClientLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning = false

  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private let appSettings: AppSettings

  private var currentLanguage: String?
  private var currentModel: String?
  private var client: StreamingTranscriptionClient?
  private var audioEngine = AVAudioEngine()
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var startedAt: Date?
  private var run: SharedClientControllerRun?
  private var boundaryDeliveryOwner: DeliveryOwner?
  private var displayedRevision: UInt64 = 0
  private var displayedTranscriptRevision: UInt64 = 0
  var stopCompletionTimeout: TimeInterval {
    guard let budget = (client as? FinalizingStreamingTranscriptionClient)?.finalisationBudget,
          budget.isFinite, budget > 0 else { return 10 }
    return max(10, budget + 1)
  }

  private var isStopping = false
  private var isStarting = false
  private let audioProcessor = SharedClientAudioProcessor()
  // Injectable system boundaries for controller lifecycle tests.
  var clientFactory: (() -> StreamingTranscriptionClient)?
  var configuredClientFactory: (@MainActor (LiveTranscriptionRoute, String?, LiveClientOptions) async throws
    -> StreamingTranscriptionClient)?
  var startCaptureAudio: (() async throws -> Void)?
  var enqueueClientUpdate: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { update in
    Task { @MainActor in update() }
  }

  init(
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    secureStorage: SecureAppStorage,
    appSettings: AppSettings
  ) {
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.secureStorage = secureStorage
    self.appSettings = appSettings
  }

  func configure(language: String?, model: String) {
    currentLanguage = language
    currentModel = model
  }

  func start() async throws {
        guard !isRunning, !isStarting, !isStopping else { throw TranscriptionManagerError.liveSessionAlreadyRunning }
        isStarting = true
        defer { isStarting = false }
        try Task.checkCancellation()
    guard let model = currentModel,
          let route = LiveTranscriptionRouting.route(for: model),
          let keyIdentifier = route.apiKeyIdentifier else {
      throw LiveTranscriptionClientError.unknownModel(currentModel ?? "")
    }

    let options = appSettings.liveClientOptions
    let language = currentLanguage
    let client = try await makeClient(
      route: route, keyIdentifier: keyIdentifier, language: language, options: options
    )
    if startCaptureAudio == nil {
      activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    }
    audioEngine = LiveInputEngines.shared.makeEngine()
    let active = SharedClientControllerRun(
      shape: client.finalShape, modelIdentifier: route.modelID,
      hasExplicitBoundaries: client is UtteranceBoundaryStreamingClient
    )
    run = active
    boundaryDeliveryOwner = active.pairsStandaloneBoundaries
      ? DeliveryOwner(delegate: delegate) : nil
    displayedRevision = 0
    displayedTranscriptRevision = 0
    isStopping = false
    self.client = client

    do {
      // A preferred-input session may have been acquired while cancellation
      // was pending; from here every exit must release it through cleanup.
      try Task.checkCancellation()
      startClient(client, for: active)
      if let failure = active.snapshot.error { throw failure }
      if let startCaptureAudio {
        try await startCaptureAudio()
      } else {
        try installAudioTap(route: route, client: client)
        try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      }
      try Task.checkCancellation()
      if let failure = active.snapshot.error { throw failure }
      startedAt = Date()
      isRunning = true
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning, !isStopping, let active = run, let activeClient = client else { return }
    let owner = boundaryDeliveryOwner
    isStopping = true
    defer { isStopping = false }
    audioEngine.stop()
    if startCaptureAudio == nil { audioEngine.inputNode.removeTap(onBus: 0) }
    audioProcessor.drainConverterTail(to: activeClient)
    audioProcessor.setRunning(false)

    let whole: String?
    if let finalizing = activeClient as? FinalizingStreamingTranscriptionClient {
      whole = await withTaskCancellationHandler {
        await finalizing.finishAndWait()
      } onCancel: { [weak self] in
        Task { @MainActor [weak self] in
          guard self?.run === active, active.cancel() else { return }
          activeClient.cancel()
        }
      }
    } else {
      if Task.isCancelled {
        if active.cancel() { activeClient.cancel() }
      } else {
        activeClient.stop()
      }
      whole = nil
    }
    if Task.isCancelled, active.cancel() { activeClient.cancel() }
    guard run === active, client === activeClient else { return }
    let captureDuration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
    let finalSnapshot = (activeClient as? StreamingTranscriptSnapshotProviding)?
      .transcriptSnapshot(captureDuration: captureDuration)
    var snapshot = active.finish(whole: whole, cancelled: Task.isCancelled, projection: finalSnapshot)
    // Read the synchronous state before retiring identity. Queued provider
    // errors must reach the owner before a stop can be mistaken for success.
    apply(snapshot, from: active, terminal: true, owner: owner)
    // A delegate can cancel synchronously while receiving the terminal text.
    // Publish that cancellation before success or retirement of this run.
    if Task.isCancelled, snapshot.error == nil {
      snapshot = active.finish(whole: nil, cancelled: true)
      activeClient.cancel()
      apply(snapshot, from: active, terminal: true, owner: owner)
    }
    isRunning = false
    if snapshot.error == nil, matchesDeliveryOwner(owner) {
      delegate?.liveTranscriber(self, didFinishWith: TranscriptionResult(
        text: snapshot.text, segments: finalSnapshot?.segments ?? [], confidence: finalSnapshot?.confidence,
        duration: finalSnapshot?.duration ?? captureDuration,
        modelIdentifier: active.modelIdentifier, cost: finalSnapshot?.cost,
        rawPayload: finalSnapshot?.rawPayload, debugInfo: nil
      ))
    }
    releaseRunOwnership()
    await endActiveInputSession()
  }

  private func loadAPIKey(identifier: String) async throws -> String {
    let apiKey: String
    do {
      apiKey = try await secureStorage.secret(identifier: identifier)
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error {
        throw TranscriptionProviderError.apiKeyMissing
      }
      throw error
    }
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TranscriptionProviderError.apiKeyMissing
    }
    return apiKey
  }

  private func apply(
    _ snapshot: SharedClientControllerRun.Snapshot,
    from active: SharedClientControllerRun,
    terminal: Bool = false,
    owner: DeliveryOwner? = nil
  ) {
    guard run === active, terminal || !isStopping else { return }
    let ownsDelivery: (() -> Bool)?
    if active.pairsStandaloneBoundaries {
      guard matchesDeliveryOwner(owner) else { return }
      // An already-cancelled terminal snapshot still reports its original
      // cancellation, but a delegate that cancels/replaces during this apply
      // cannot receive any remaining text or failure from the old delivery.
      let allowedAtEntry = active.mayDeliverBoundaries
      let cancelledAtEntry = Task.isCancelled
      ownsDelivery = { [weak self] in
        self?.run === active && active.mayDeliverBoundaries == allowedAtEntry
          && Task.isCancelled == cancelledAtEntry
          && self?.matchesDeliveryOwner(owner) == true
      }
    } else {
      ownsDelivery = nil
    }
    drainStandaloneBoundaries(from: active, terminal: terminal, owner: owner)
    guard run === active, ownsDelivery?() ?? true, snapshot.revision > displayedRevision else { return }
    publishTranscript(snapshot, from: active, terminal: terminal, ownsDelivery: ownsDelivery)
    guard ownsDelivery?() ?? true else { return }
    if let failure = active.takeFailure() {
      delegate?.liveTranscriber(self, didFail: failure)
    }
  }

  private func installAudioTap(
    route: LiveTranscriptionRoute,
    client: StreamingTranscriptionClient
  ) throws {
    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard audioInputFormatIsUsable(inputFormat) else {
      throw TranscriptionManagerError.noUsableAudioInput
    }
    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: Double(route.sampleRate),
      channels: 1,
      interleaved: true
    ), AVAudioConverter(from: inputFormat, to: targetFormat) != nil else {
      throw TranscriptionManagerError.noUsableAudioInput
    }

    let processor = audioProcessor
    processor.setRunning(true)
    try inputNode.installTapSafely(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
      processor.handleAudioTap(
        buffer,
        inputFormat: inputFormat,
        outputFormat: targetFormat,
        client: client
      )
    }
  }

  private func cleanupAfterFailedStart() async {
    audioEngine.stop()
    if startCaptureAudio == nil { audioEngine.inputNode.removeTap(onBus: 0) }
    audioProcessor.setRunning(false)
    run?.cancel()
    client?.cancel()
    releaseRunOwnership()
    isRunning = false
    isStopping = false
    startedAt = nil
    await endActiveInputSession()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}

private extension SharedClientLiveController {
  private func makeClient(
    route: LiveTranscriptionRoute, keyIdentifier: String, language: String?, options: LiveClientOptions
  ) async throws -> StreamingTranscriptionClient {
    if let clientFactory { return clientFactory() }
    if let configuredClientFactory { return try await configuredClientFactory(route, language, options) }
    let permission = await permissionsManager.ensureGranted(.microphone)
    try Task.checkCancellation()
    guard permission.isGranted else { throw TranscriptionManagerError.microphonePermissionMissing }
    let apiKey = try await loadAPIKey(identifier: keyIdentifier)
    try Task.checkCancellation()
    guard let created = LiveTranscriptionClientFactory.makeClient(
      for: route, apiKey: apiKey, language: language, options: options,
      azureEndpoint: UserDefaults.standard.string(forKey: AzureSpeechConfiguration.endpointDefaultsKey) ?? ""
    ) else { throw LiveTranscriptionClientError.providerNotAvailable(route.provider) }
    return created
  }
  @MainActor
  final class DeliveryOwner {
    weak var delegate: LiveTranscriptionSessionDelegate?
    let hadDelegate: Bool

    init(delegate: LiveTranscriptionSessionDelegate?) {
      self.delegate = delegate
      hadDelegate = delegate != nil
    }
  }

  func releaseRunOwnership() {
    client = nil
    run = nil
    boundaryDeliveryOwner = nil
  }

  func publishTranscript(
    _ snapshot: SharedClientControllerRun.Snapshot,
    from active: SharedClientControllerRun,
    terminal: Bool,
    ownsDelivery: (() -> Bool)? = nil
  ) {
    displayedRevision = snapshot.revision
    if snapshot.transcriptRevision > displayedTranscriptRevision {
      displayedTranscriptRevision = snapshot.transcriptRevision
      delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(
        text: snapshot.text, isFinal: snapshot.isFinal && snapshot.error == nil, confidence: snapshot.confidence
      ))
      if let ownsDelivery, !ownsDelivery() { return }
      delegate?.liveTranscriber(self, didUpdatePartial: snapshot.text)
      if let ownsDelivery, !ownsDelivery() { return }
      if run === active, !active.hasExplicitBoundaries, snapshot.isFinal, snapshot.error == nil,
         !terminal || !Task.isCancelled {
        delegate?.liveTranscriber(self, didDetectUtteranceBoundary: snapshot.text)
      }
    }
  }

  /// Each pair was captured before the next standalone receive. Drain before
  /// newer UI snapshots, and at terminal finish before retiring ownership.
  /// Cumulative explicit clients keep their existing boundary ordering.
  func drainStandaloneBoundaries(from active: SharedClientControllerRun, terminal: Bool, owner: DeliveryOwner?) {
    guard active.pairsStandaloneBoundaries else { return }
    for pair in active.takeBoundaryPairs() {
      guard ownsBoundaryDelivery(active, terminal: terminal, owner: owner) else { return }
      if pair.display.revision > displayedRevision {
        publishTranscript(pair.display, from: active, terminal: terminal, ownsDelivery: { [weak self] in
          self?.ownsBoundaryDelivery(active, terminal: terminal, owner: owner) == true
        })
      }
      guard ownsBoundaryDelivery(active, terminal: terminal, owner: owner) else { return }
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: pair.utterance)
    }
  }

  func ownsBoundaryDelivery(_ active: SharedClientControllerRun, terminal: Bool, owner: DeliveryOwner?) -> Bool {
    run === active && active.mayDeliverBoundaries && (!terminal || !Task.isCancelled) && matchesDeliveryOwner(owner)
  }

  func matchesDeliveryOwner(_ owner: DeliveryOwner?) -> Bool {
    guard let owner else { return true }
    guard let original = owner.delegate else { return !owner.hadDelegate && delegate == nil }
    return delegate === original
  }
}

// MARK: - Client callbacks

extension SharedClientLiveController {
  /// Folds provider callbacks into this recording before any MainActor hop,
  /// then opens the stream.
  private func startClient(_ client: StreamingTranscriptionClient, for active: SharedClientControllerRun) {
    let enqueue = enqueueClientUpdate
    let owner = boundaryDeliveryOwner
    observeBoundaries(of: client, for: active, owner: owner)
    client.start(
      onTranscript: { [weak self, weak client] text, isFinal in
        // A client with an authoritative result replaces the text rather
        // than having it folded a second time.
        let projection = (client as? StreamingTranscriptSnapshotProviding)?
          .transcriptSnapshot(captureDuration: 0)
        guard let snapshot = active.receive(text, isFinal: isFinal, projection: projection) else { return }
        enqueue { [weak self] in self?.apply(snapshot, from: active, owner: owner) }
      },
      onError: { [weak self] error in
        guard let snapshot = active.fail(error) else { return }
        enqueue { [weak self] in self?.apply(snapshot, from: active, owner: owner) }
      }
    )
  }

  /// A client that reports its own utterance boundaries is listened to
  /// directly; finals of such a client never imply one.
  private func observeBoundaries(
    of client: StreamingTranscriptionClient, for active: SharedClientControllerRun, owner: DeliveryOwner?
  ) {
    guard let boundaryClient = client as? UtteranceBoundaryStreamingClient else { return }
    let enqueue = enqueueClientUpdate
    boundaryClient.onUtteranceBoundary = { [weak self] text in
      if active.pairsStandaloneBoundaries {
        guard let snapshot = active.recordStandaloneBoundary(text) else { return }
        enqueue { [weak self] in self?.apply(snapshot, from: active, owner: owner) }
        return
      }
      guard active.isOpen else { return }
      enqueue { [weak self] in
        guard let self, self.run === active, active.isOpen else { return }
        self.delegate?.liveTranscriber(self, didDetectUtteranceBoundary: text)
      }
    }
  }
}
