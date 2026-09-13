import AVFoundation
import Foundation
import SpeakCore

/// macOS capture/controller path for providers implemented by a shared
/// `StreamingTranscriptionClient`.
///
/// Platform-specific code owns microphone capture and PCM conversion; the
/// provider transport and event parsing stay in SpeakCore and are shared with
/// iOS.
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
  private var latestTranscript = ""
  /// Folds updates by the hosted client's declared final shape (issue #700);
  /// re-created in start() once the client is known.
  private var accumulated = TranscriptAccumulator(shape: .cumulativeTranscript)
  private var isStopping = false
  private var isStarting = false
  private let audioProcessor = SharedClientAudioProcessor()

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
        guard !isRunning, !isStarting else { throw TranscriptionManagerError.liveSessionAlreadyRunning }
        isStarting = true
        defer { isStarting = false }
        try Task.checkCancellation()
        let permission = await permissionsManager.ensureGranted(.microphone)
        try Task.checkCancellation()
        guard permission.isGranted else {
            throw TranscriptionManagerError.microphonePermissionMissing
        }
    let (route, client) = try await resolveRouteAndClient()

    activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    audioEngine = AVAudioEngine()
    latestTranscript = ""
    accumulated = TranscriptAccumulator(shape: client.finalShape)
    isStopping = false
    self.client = client

    do {
      // A preferred-input session may have been acquired while cancellation
      // was pending; from here every exit must release it through cleanup.
      try Task.checkCancellation()
      startClient(client)
      try installAudioTap(route: route, client: client)
      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      try Task.checkCancellation()
      startedAt = Date()
      isRunning = true
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning, !isStopping else { return }
    isStopping = true
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    if let client {
      audioProcessor.drainConverterTail(to: client)
    }
    audioProcessor.setRunning(false)

    let finishingClient = client
    let hasExplicitBoundaries = finishingClient is UtteranceBoundaryStreamingClient
    if let finalizingClient = finishingClient as? FinalizingStreamingTranscriptionClient {
      // Contract: `finishAndWait()` returns the session's full transcript, so
      // this replaces what we have rather than appending to it — appending
      // would double every word the client already streamed.
      if let finalTranscript = await finalizingClient.finishAndWait(),
         latestTranscript != finalTranscript {
        applyFullTranscript(finalTranscript, inferBoundary: !hasExplicitBoundaries)
      }
    } else {
      finishingClient?.stop()
    }
    let captureDuration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
    let finalSnapshot = (finishingClient as? StreamingTranscriptSnapshotProviding)?
      .transcriptSnapshot(captureDuration: captureDuration)
    applySnapshotText(finalSnapshot)
    client = nil
    isRunning = false
    isStopping = false

    let result = TranscriptionResult(
      text: latestTranscript,
      segments: finalSnapshot?.segments ?? [],
      confidence: finalSnapshot?.confidence,
      duration: finalSnapshot?.duration ?? captureDuration,
      modelIdentifier: currentModel ?? "",
      cost: finalSnapshot?.cost,
      rawPayload: finalSnapshot?.rawPayload,
      debugInfo: nil
    )
    delegate?.liveTranscriber(self, didFinishWith: result)
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

  /// Applies a transcript update, folded by the hosted client's declared
  /// final shape (issue #700): cumulative finals replace (xAI restates the
  /// whole turn on every event), standalone segment finals append — including
  /// repeated identical text, which is a genuine repeat, so a segment-shaped
  /// provider routed here can no longer lose earlier segments.
  private func handleTranscript(
    _ text: String,
    isFinal: Bool,
    snapshot: StreamingTranscriptSnapshot?,
    inferBoundary: Bool
  ) {
    guard let displayText = SharedTranscriptProjection.apply(
      eventText: text,
      isFinal: isFinal,
      snapshot: snapshot,
      accumulator: &accumulated
    ) else { return }
    latestTranscript = displayText
    delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(
      text: displayText,
      isFinal: isFinal,
      confidence: snapshot?.latestUpdateConfidence
    ))
    delegate?.liveTranscriber(self, didUpdatePartial: displayText)
    if isFinal && inferBoundary {
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: displayText)
    }
  }

  private func applySnapshotText(_ snapshot: StreamingTranscriptSnapshot?) {
    guard let snapshot, let text = snapshot.resolvedDisplayText else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if snapshot.confirmedText != nil || !trimmed.isEmpty {
      latestTranscript = trimmed
      accumulated.replace(with: trimmed)
    }
  }

  /// Adopts a transcript that is already complete (the `finishAndWait()`
  /// return) as the whole session transcript — replace, never append, or every
  /// word the client already streamed would double.
  private func applyFullTranscript(_ transcript: String, inferBoundary: Bool = true) {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    accumulated.replace(with: trimmed)
    latestTranscript = accumulated.text
    delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(
      text: accumulated.text,
      isFinal: true,
      confidence: nil
    ))
    delegate?.liveTranscriber(self, didUpdatePartial: accumulated.text)
    if inferBoundary {
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: accumulated.text)
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
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
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
    audioEngine.inputNode.removeTap(onBus: 0)
    audioProcessor.setRunning(false)
    client?.stop()
    client = nil
    isRunning = false
    isStopping = false
    latestTranscript = ""
    accumulated.reset()
    startedAt = nil
    await endActiveInputSession()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}

// MARK: - Start helpers
//
// Held in an extension so `start()` stays inside the cyclomatic-complexity
// budget and the class body stays inside the type-body-length budget.
extension SharedClientLiveController {
  /// Resolves the configured model to a route and a live client, loading the
  /// provider key on the way. Throws if the model is unknown, carries no key
  /// identifier, or has no registered client.
  private func resolveRouteAndClient() async throws
    -> (LiveTranscriptionRoute, StreamingTranscriptionClient) {
    guard let model = currentModel,
          let route = LiveTranscriptionRouting.route(for: model),
          let keyIdentifier = route.apiKeyIdentifier else {
      throw LiveTranscriptionClientError.unknownModel(currentModel ?? "")
    }

    let apiKey = try await loadAPIKey(identifier: keyIdentifier)
    try Task.checkCancellation()
    guard let client = LiveTranscriptionClientFactory.makeClient(
      for: route,
      apiKey: apiKey,
      language: currentLanguage,
      options: appSettings.liveClientOptions,
      azureEndpoint: UserDefaults.standard.string(forKey: AzureSpeechConfiguration.endpointDefaultsKey) ?? ""
    ) else {
      throw LiveTranscriptionClientError.providerNotAvailable(route.provider)
    }
    return (route, client)
  }

  /// Wires the boundary, transcript and error callbacks, then opens the stream.
  private func startClient(_ client: StreamingTranscriptionClient) {
    let hasExplicitBoundaries = client is UtteranceBoundaryStreamingClient
    if let boundaryClient = client as? UtteranceBoundaryStreamingClient {
      boundaryClient.onUtteranceBoundary = { [weak self, weak client] text in
        Task { @MainActor [weak self, weak client] in
          guard let self,
                LiveTranscriptionRun.isCurrent(client, activeStream: self.client) else { return }
          self.delegate?.liveTranscriber(self, didDetectUtteranceBoundary: text)
        }
      }
    }
    client.start(
      onTranscript: { [weak self, weak client] text, isFinal in
        let snapshot = (client as? StreamingTranscriptSnapshotProviding)?
          .transcriptSnapshot(captureDuration: 0)
        Task { @MainActor [weak self, weak client] in
          guard let self else { return }
          // Cached controllers are reused between recordings, so a message
          // queued by the previous stream can land here after the next
          // recording started. Only the current stream owns this state.
          guard LiveTranscriptionRun.isCurrent(client, activeStream: self.client) else { return }
          self.handleTranscript(
            text,
            isFinal: isFinal,
            snapshot: snapshot,
            inferBoundary: !hasExplicitBoundaries
          )
        }
      },
      onError: { [weak self, weak client] error in
        Task { @MainActor [weak self, weak client] in
          guard let self else { return }
          guard LiveTranscriptionRun.isCurrent(client, activeStream: self.client) else { return }
          self.delegate?.liveTranscriber(self, didFail: error)
        }
      }
    )
  }
}

enum SharedTranscriptProjection {
  static func apply(
    eventText: String,
    isFinal: Bool,
    snapshot: StreamingTranscriptSnapshot?,
    accumulator: inout TranscriptAccumulator
  ) -> String? {
    if let authoritative = snapshot?.resolvedDisplayText {
      let text = authoritative.trimmingCharacters(in: .whitespacesAndNewlines)
      accumulator.replace(with: text)
      return text
    }
    let text = eventText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return isFinal ? accumulator.append(final: text) : accumulator.display(withInterim: text)
  }
}
