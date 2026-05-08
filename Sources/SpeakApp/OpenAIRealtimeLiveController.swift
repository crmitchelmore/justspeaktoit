import AVFoundation
import Foundation
import SpeakCore
import os.log

// swiftlint:disable file_length

// MARK: - OpenAI Realtime Live Controller

/// Wraps `OpenAIRealtimeLiveTranscriber` to conform to
/// `LiveTranscriptionController`. Mirrors `AssemblyAILiveController`:
/// captures audio, resamples to PCM16 / 24 kHz, forwards to the WebSocket,
/// and on stop sends `input_audio_buffer.commit` and waits up to the
/// per-model `postStopFinalizeBudget` for the final completed event.
@MainActor
// swiftlint:disable:next type_body_length
final class OpenAIRealtimeLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: OpenAIRealtimeLiveTranscriber?
  private var currentModel: String?
  private var currentLanguage: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private let audioEngine = AVAudioEngine()
  private let logger = Logger(subsystem: "com.speak.app", category: "OpenAIRealtimeLiveController")
  private let audioProcessor = OpenAIRealtimeAudioProcessor(targetSampleRate: 24_000)
  private var hasFinished: Bool = false

  private let targetSampleRate: Double = 24_000
  private var targetFormat: AVAudioFormat?
  private var streamingStartTime: Date?
  /// Map item_id → committed final transcript. OpenAI Realtime emits one
  /// `…completed` event per conversation item; deltas accumulate into
  /// `currentDeltasByItem` until we see `.completed`.
  private var finalsByItem: [String: String] = [:]
  private var itemOrder: [String] = []
  private var currentDeltasByItem: [String: String] = [:]
  /// Item IDs that were completed *before* the user pressed stop. Used to
  /// guard the stop continuation: we only resume on a *new* completion
  /// (i.e. one not in this set) so a stale `.completed` for an earlier
  /// segment doesn't cause us to close the socket before the final
  /// commit-triggered completion arrives.
  private var preStopCompletedItemIDs: Set<String> = []
  private var stopContinuation: CheckedContinuation<Void, Never>?

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    secureStorage: SecureAppStorage
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.secureStorage = secureStorage
  }

  func configure(language: String?, model: String) {
    currentModel = model
    currentLanguage = language
    logger.info("Configured OpenAI Realtime with model: \(model)")
  }

  // swiftlint:disable:next function_body_length
  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.permissionsMissing
    }

    let apiKey = try await openAIAPIKey()

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()
    activeInputSession = sessionContext

    transcriber = nil
    targetFormat = nil
    finalsByItem = [:]
    itemOrder = []
    currentDeltasByItem = [:]
    preStopCompletedItemIDs = []
    streamingStartTime = nil
    hasFinished = false
    stopContinuation = nil
    isRunning = false

    do {
      let inputNode = audioEngine.inputNode
      inputNode.removeTap(onBus: 0)
      let inputFormat = inputNode.outputFormat(forBus: 0)

      guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: true
      ) else {
        throw OpenAIRealtimeError.encodingFailed
      }
      targetFormat = outputFormat

      let provider = OpenAIRealtimeTranscriptionProvider()
      let modelID = currentModel ?? appSettings.liveTranscriptionModel
      let realtimeName = OpenAIRealtimeTranscriptionProvider.realtimeModelName(from: modelID)
      transcriber = provider.createLiveTranscriber(
        apiKey: apiKey,
        model: realtimeName,
        language: currentLanguage.map(Self.extractLanguageCode(from:)),
        // OpenAI Realtime's transcription `prompt` is a glossary-style
        // bias — use the AssemblyAI keyterms list as a comma-joined hint.
        // We deliberately do *not* forward the post-processing system prompt
        // here; that's still applied later by PostProcessingManager.
        prompt: trimmedKeytermsPrompt(),
        sampleRate: 24_000
      )

      transcriber?.start(
        onEvent: { [weak self] event in
          Task { @MainActor [weak self] in
            self?.handleEvent(event)
          }
        },
        onError: { [weak self] error in
          Task { @MainActor [weak self] in
            guard let self else { return }
            // NOTE: we no longer drop errors that arrive before isRunning
            // flips true. WebSocket failures during the connecting window
            // (invalid API key, 401, DNS, etc.) used to be swallowed,
            // leaving the user with a session that ran locally but never
            // produced text. Surface them via the delegate.
            self.delegate?.liveTranscriber(self, didFail: error)
          }
        }
      )

      guard let transcriber else { throw OpenAIRealtimeError.encodingFailed }

      audioProcessor.setRunning(true)
      let processor = audioProcessor
      let log = logger
      inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
        processor.handleAudioTap(
          buffer,
          inputFormat: inputFormat,
          outputFormat: outputFormat,
          transcriber: transcriber,
          logger: log
        )
      }

      audioEngine.prepare()
      try audioEngine.start()
      isRunning = true
      streamingStartTime = Date()
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning else { return }
    guard !hasFinished else { return }
    hasFinished = true

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false

    // Snapshot which item ids have already finalised before stop. Any
    // .completed that arrives during the stop wait must be for a *new* item
    // id (the one created by our explicit commit) before we treat it as
    // the trigger to resume early.
    preStopCompletedItemIDs = Set(finalsByItem.keys)

    if let transcriber {
      // 1. Make sure the OpenAI session has acknowledged our config so any
      //    pre-ready buffered audio has somewhere correct to land.
      _ = await transcriber.awaitSessionReady(timeout: 1.0)
      // 2. Flush local resampler tail into the transcriber (which will send
      //    immediately now that the session is ready, or buffer briefly if
      //    the readiness timeout lapsed).
      audioProcessor.flushPendingAudio(to: transcriber)
      // 3. Await all pending audio appends so the server has the full tail.
      await transcriber.waitForPendingSends()
      audioProcessor.setRunning(false)
      // 4. Commit; the commit send is also tracked by pendingSendGroup.
      transcriber.commitInputBuffer()
      // 5. Await the commit send completion before starting the finalize
      //    budget — otherwise the budget can elapse before the server has
      //    even seen our commit.
      await transcriber.waitForPendingSends()

      // 6. Wait for a *new* `.completed` event triggered by our commit, or
      //    the model-specific finalize budget, whichever comes first.
      let budget = appSettings.liveModelCapabilities.postStopFinalizeBudget
      if budget > 0 {
        await withCheckedContinuation { continuation in
          stopContinuation = continuation
          Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(budget))
            guard let self, let cont = self.stopContinuation else { return }
            self.stopContinuation = nil
            cont.resume()
          }
        }
      }

      transcriber.stop()
    } else {
      audioProcessor.setRunning(false)
    }

    let result = buildFinalResult()
    delegate?.liveTranscriber(self, didFinishWith: result)

    await endActiveInputSession()
    transcriber = nil
  }

  // MARK: - Event handling

  private func handleEvent(_ event: OpenAIRealtimeLiveTranscriber.Event) {
    switch event {
    case .sessionCreated:
      logger.info("OpenAI Realtime session created (awaiting config ack)")
    case .sessionReady:
      logger.info("OpenAI Realtime session ready (config applied)")
    case .delta(let text, let itemId):
      let key = itemId.isEmpty ? "_pending" : itemId
      if currentDeltasByItem[key] == nil, finalsByItem[key] == nil {
        itemOrder.append(key)
      }
      currentDeltasByItem[key, default: ""].append(text)
      delegate?.liveTranscriber(self, didUpdatePartial: composedTranscript())
    case .completed(let transcript, let itemId):
      let key = itemId.isEmpty ? "_pending" : itemId
      let isNewItem = !preStopCompletedItemIDs.contains(key)
      if currentDeltasByItem[key] == nil, finalsByItem[key] == nil {
        itemOrder.append(key)
      }
      finalsByItem[key] = transcript
      currentDeltasByItem.removeValue(forKey: key)
      delegate?.liveTranscriber(self, didUpdatePartial: composedTranscript())

      // Resume the stop continuation only on a NEW completion — one that
      // wasn't already final before stop fired. Stale completions for
      // earlier items must not race the final commit.
      if hasFinished, isNewItem, let continuation = stopContinuation {
        stopContinuation = nil
        continuation.resume()
      }
    }
  }

  private func composedTranscript() -> String {
    var pieces: [String] = []
    for key in itemOrder {
      if let final = finalsByItem[key], !final.isEmpty {
        pieces.append(final)
      } else if let delta = currentDeltasByItem[key], !delta.isEmpty {
        pieces.append(delta)
      }
    }
    return pieces.joined(separator: " ")
  }

  // MARK: - Result building

  private func buildFinalResult() -> TranscriptionResult {
    let text = composedTranscript()
    let segments: [TranscriptionSegment] = itemOrder.compactMap { key in
      guard let final = finalsByItem[key], !final.isEmpty else { return nil }
      return TranscriptionSegment(startTime: 0, endTime: 0, text: final)
    }

    let streamingDuration: TimeInterval
    if let startTime = streamingStartTime {
      streamingDuration = Date().timeIntervalSince(startTime)
    } else {
      streamingDuration = 0
    }

    return TranscriptionResult(
      text: text,
      segments: segments,
      confidence: nil,
      duration: streamingDuration,
      modelIdentifier: currentModel ?? "openai/gpt-realtime-whisper-streaming",
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  // MARK: - Cleanup

  private func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false
    audioProcessor.setRunning(false)
    transcriber?.stop()
    transcriber = nil
    targetFormat = nil
    streamingStartTime = nil
    finalsByItem = [:]
    itemOrder = []
    currentDeltasByItem = [:]
    preStopCompletedItemIDs = []
    stopContinuation = nil
    await endActiveInputSession()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }

  private func ensurePermissions() async -> Bool {
    let microphone = await permissionsManager.request(.microphone)
    let speech = await permissionsManager.request(.speechRecognition)
    return microphone.isGranted && speech.isGranted
  }

  private func trimmedKeytermsPrompt() -> String? {
    let raw = appSettings.assemblyAIKeyterms.trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? nil : raw
  }

  /// Normalises a BCP-47 locale identifier (e.g. "en-GB", "en_US") to the
  /// ISO-639-1 two-letter code OpenAI Realtime expects (e.g. "en"). Mirrors
  /// the helper used by every other transcription provider.
  static func extractLanguageCode(from locale: String) -> String {
    let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
    return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
  }

  private func openAIAPIKey() async throws -> String {
    do {
      let apiKey = try await secureStorage.secret(identifier: "openai.apiKey")
      guard !apiKey.isEmpty else { throw OpenAIRealtimeError.missingAPIKey }
      return apiKey
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error {
        throw OpenAIRealtimeError.missingAPIKey
      }
      throw error
    } catch {
      throw error
    }
  }
}

// MARK: - Audio Processor

/// PCM16 audio resampler that batches frames into ≥50 ms chunks and forwards
/// them to the OpenAI Realtime WebSocket. Logically identical to
/// `AssemblyAILiveController.AssemblyAIAudioProcessor` except for the target
/// sample rate (24 kHz here, 16 kHz there) and the destination type.
private final class OpenAIRealtimeAudioProcessor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.speak.app.openairealtime.audioProcessing")
  private let minimumChunkBytes: Int
  private let preferredChunkBytes: Int

  private var isRunning: Bool = false
  private var cachedConverter: AVAudioConverter?
  private var cachedInputFormat: AVAudioFormat?
  private var reusableOutputBuffer: AVAudioPCMBuffer?
  private var pendingPCMData = Data()

  init(targetSampleRate: Int) {
    // 50 ms safety lower bound, 100 ms preferred upload chunk size.
    self.minimumChunkBytes = (targetSampleRate / 1000) * 50 * 2
    self.preferredChunkBytes = (targetSampleRate / 1000) * 100 * 2
  }

  func setRunning(_ running: Bool) {
    queue.sync {
      isRunning = running
      if !running {
        cachedConverter = nil
        cachedInputFormat = nil
        reusableOutputBuffer = nil
        pendingPCMData.removeAll(keepingCapacity: false)
      }
    }
  }

  func flushPendingAudio(to transcriber: OpenAIRealtimeLiveTranscriber) {
    queue.sync {
      guard !pendingPCMData.isEmpty else { return }

      var offset = 0
      while pendingPCMData.count - offset >= preferredChunkBytes {
        let chunk = pendingPCMData.subdata(in: offset..<(offset + preferredChunkBytes))
        transcriber.sendAudio(chunk)
        offset += preferredChunkBytes
      }
      if offset > 0 {
        pendingPCMData = Data(pendingPCMData.dropFirst(offset))
      }

      guard !pendingPCMData.isEmpty else { return }
      if pendingPCMData.count < minimumChunkBytes {
        pendingPCMData.append(
          contentsOf: repeatElement(0, count: minimumChunkBytes - pendingPCMData.count))
      }
      transcriber.sendAudio(pendingPCMData)
      pendingPCMData.removeAll(keepingCapacity: false)
    }
  }

  func handleAudioTap(
    _ buffer: AVAudioPCMBuffer,
    inputFormat: AVAudioFormat,
    outputFormat: AVAudioFormat,
    transcriber: OpenAIRealtimeLiveTranscriber,
    logger: Logger
  ) {
    guard let copied = copyPCMBuffer(buffer) else { return }
    queue.async { [weak self] in
      guard let self, self.isRunning else { return }
      self.processAndSendAudio(
        copied, from: inputFormat, to: outputFormat,
        transcriber: transcriber, logger: logger
      )
    }
  }

  private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let frameLength = buffer.frameLength
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameLength) else {
      return nil
    }
    copy.frameLength = frameLength
    let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let dst = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: copy.audioBufferList))
    for idx in 0..<min(src.count, dst.count) {
      let srcBuf = src[idx]
      guard let srcData = srcBuf.mData, let dstData = dst[idx].mData else { continue }
      dstData.copyMemory(from: srcData, byteCount: Int(srcBuf.mDataByteSize))
      dst[idx].mDataByteSize = srcBuf.mDataByteSize
    }
    return copy
  }

  private func processAndSendAudio(
    _ buffer: AVAudioPCMBuffer,
    from inputFormat: AVAudioFormat,
    to outputFormat: AVAudioFormat,
    transcriber: OpenAIRealtimeLiveTranscriber,
    logger: Logger
  ) {
    let converter: AVAudioConverter
    if let cached = cachedConverter, cachedInputFormat == inputFormat {
      converter = cached
    } else {
      guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
        logger.error("Failed to create audio converter")
        return
      }
      cachedConverter = newConverter
      cachedInputFormat = inputFormat
      converter = newConverter
    }

    let ratio = outputFormat.sampleRate / inputFormat.sampleRate
    let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

    let outputBuffer: AVAudioPCMBuffer
    if let reusable = reusableOutputBuffer, reusable.frameCapacity >= outputFrameCapacity {
      reusable.frameLength = 0
      outputBuffer = reusable
    } else {
      guard let newBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat, frameCapacity: outputFrameCapacity
      ) else { return }
      reusableOutputBuffer = newBuffer
      outputBuffer = newBuffer
    }

    // NOTE: We deliberately do NOT call converter.reset() between chunks —
    // doing so wipes the resampler's filter history and priming/trailing
    // frames, which audibly clicks at chunk boundaries (~50 Hz). The
    // converter is only created once per inputFormat (cachedConverter), so
    // its state is the *correct* thing to preserve across taps.
    var error: NSError?
    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }

    guard status != .error, error == nil else { return }

    guard let int16Data = outputBuffer.int16ChannelData else { return }
    let frameLength = Int(outputBuffer.frameLength)
    let data = Data(bytes: int16Data[0], count: frameLength * 2)
    pendingPCMData.append(data)

    var offset = 0
    while pendingPCMData.count - offset >= preferredChunkBytes {
      let chunk = pendingPCMData.subdata(in: offset..<(offset + preferredChunkBytes))
      transcriber.sendAudio(chunk)
      offset += preferredChunkBytes
    }
    if offset > 0 {
      pendingPCMData = Data(pendingPCMData.dropFirst(offset))
    }
  }
}
