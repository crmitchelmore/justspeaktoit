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

  private var currentLanguage: String?
  private var currentModel: String?
  private var client: StreamingTranscriptionClient?
  private var audioEngine = AVAudioEngine()
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var startedAt: Date?
  private var latestTranscript = ""
  private var isStopping = false

  init(
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    secureStorage: SecureAppStorage
  ) {
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.secureStorage = secureStorage
  }

  func configure(language: String?, model: String) {
    currentLanguage = language
    currentModel = model
  }

  func start() async throws {
    guard !isRunning else { return }
    guard (await permissionsManager.ensureGranted(.microphone)).isGranted else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }
    guard let model = currentModel,
          let route = LiveTranscriptionRouting.route(for: model),
          let keyIdentifier = route.apiKeyIdentifier else {
      throw LiveTranscriptionClientError.unknownModel(currentModel ?? "")
    }

    let apiKey = try await loadAPIKey(identifier: keyIdentifier)
    guard let client = LiveTranscriptionClientFactory.makeClient(
      for: route,
      apiKey: apiKey,
      language: currentLanguage
    ) else {
      throw LiveTranscriptionClientError.providerNotAvailable(route.provider)
    }

    activeInputSession = await audioDeviceManager.beginUsingPreferredInput()
    audioEngine = AVAudioEngine()
    latestTranscript = ""
    isStopping = false
    self.client = client

    do {
      client.start(
        onTranscript: { [weak self] text, isFinal in
          Task { @MainActor [weak self] in
            self?.handleTranscript(text, isFinal: isFinal)
          }
        },
        onError: { [weak self] error in
          Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.delegate?.liveTranscriber(self, didFail: error)
          }
        }
      )
      try installAudioTap(route: route, client: client)
      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
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

    if let finalizingClient = client as? FinalizingStreamingTranscriptionClient {
      if let finalTranscript = await finalizingClient.finishAndWait(),
         latestTranscript != finalTranscript {
        handleTranscript(finalTranscript, isFinal: true)
      }
    } else {
      client?.stop()
    }
    client = nil
    isRunning = false
    isStopping = false

    let result = TranscriptionResult(
      text: latestTranscript,
      segments: [],
      confidence: nil,
      duration: startedAt.map { Date().timeIntervalSince($0) } ?? 0,
      modelIdentifier: currentModel ?? "",
      cost: nil,
      rawPayload: nil,
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

  private func handleTranscript(_ text: String, isFinal: Bool) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    latestTranscript = trimmed
    delegate?.liveTranscriber(self, didUpdateWith: LiveTranscriptionUpdate(
      text: trimmed,
      isFinal: isFinal,
      confidence: nil
    ))
    delegate?.liveTranscriber(self, didUpdatePartial: trimmed)
    if isFinal {
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: trimmed)
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
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(route.sampleRate),
      channels: 1,
      interleaved: false
    ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw TranscriptionManagerError.noUsableAudioInput
    }

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
      let ratio = targetFormat.sampleRate / inputFormat.sampleRate
      let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
      guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
        return
      }
      var conversionError: NSError?
      var didProvideInput = false
      let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
        guard !didProvideInput else {
          outStatus.pointee = .noDataNow
          return nil
        }
        didProvideInput = true
        outStatus.pointee = .haveData
        return buffer
      }
      guard status != .error, conversionError == nil,
            let channelData = output.floatChannelData?[0] else {
        return
      }

      let frameCount = Int(output.frameLength)
      guard frameCount > 0 else { return }
      var samples = [Int16](repeating: 0, count: frameCount)
      for index in 0..<frameCount {
        let clamped = max(-1, min(1, channelData[index]))
        samples[index] = Int16(clamped * Float(Int16.max))
      }
      client.sendAudio(samples.withUnsafeBufferPointer { Data(buffer: $0) })
    }
  }

  private func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    client?.stop()
    client = nil
    isRunning = false
    isStopping = false
    latestTranscript = ""
    startedAt = nil
    await endActiveInputSession()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }
}
