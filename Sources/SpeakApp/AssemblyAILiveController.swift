// swiftlint:disable file_length
import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

// MARK: - AssemblyAI Live Controller

// swiftlint:disable type_body_length
/// Wraps AssemblyAILiveTranscriber to conform to LiveTranscriptionController protocol.
/// Resamples audio from device sample rate (typically 48kHz) to 16kHz for AssemblyAI.
final class AssemblyAILiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let secureStorage: SecureAppStorage
  private var transcriber: AssemblyAILiveTranscriber?
  private var currentModel: String?
  private var currentLanguage: String?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var audioEngine = AVAudioEngine()
  private let logger = Logger(subsystem: "com.speak.app", category: "AssemblyAILiveController")
  private let audioProcessor = AssemblyAIAudioProcessor()
  private var hasFinished: Bool = false

  private let targetSampleRate: Double = 16000
  private var targetFormat: AVAudioFormat?
  private var streamingStartTime: Date?
  private var finalSegments: [TranscriptionSegment] = []
  private var currentInterim: String = ""
  private var fullTranscript: String = ""
  private var currentTurnOrder: Int = -1
  private var finalSegmentIndexByTurnOrder: [Int: Int] = [:]
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
    logger.info("Configured AssemblyAI with model: \(model)")
  }

  // swiftlint:disable:next function_body_length
  // swiftlint:disable:next function_body_length
  func start() async throws {
    guard await ensurePermissions() else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }

    let apiKey = try await assemblyAIAPIKey()

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()
    activeInputSession = sessionContext
    audioEngine = AVAudioEngine()

    transcriber = nil
    targetFormat = nil
    finalSegments = []
    currentInterim = ""
    fullTranscript = ""
    currentTurnOrder = -1
    finalSegmentIndexByTurnOrder = [:]
    streamingStartTime = nil
    hasFinished = false
    stopContinuation = nil
    isRunning = false

    do {
      let inputNode = audioEngine.inputNode
      inputNode.removeTap(onBus: 0)
      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard audioInputFormatIsUsable(inputFormat) else {
        throw TranscriptionManagerError.noUsableAudioInput
      }

      guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: true
      ) else {
        throw AssemblyAIError.connectionFailed
      }
      targetFormat = outputFormat

      // Keep style/format instructions in PostProcessingManager. Universal-3.5
      // supports contextual prompting, while this app currently sends only the
      // user's explicit recognition keyterms to the streaming request.
      let keyterms = appSettings.assemblyAIKeyterms
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

      let provider = AssemblyAITranscriptionProvider()
      let newTranscriber = provider.createLiveTranscriber(
        apiKey: apiKey,
        sampleRate: 16000,
        model: currentModel ?? appSettings.liveTranscriptionModel,
        keyterms: keyterms,
        language: currentLanguage
      )
      transcriber = newTranscriber

      newTranscriber.start(
        onTranscript: { [weak self, weak newTranscriber] turn in
          Task { @MainActor [weak self, weak newTranscriber] in
            guard let self else { return }
            // Cached controllers are reused between recordings, so a message
            // queued by the previous stream can land here after the next
            // recording started. Only the current stream owns this state.
            guard LiveTranscriptionRun.isCurrent(newTranscriber, activeStream: self.transcriber) else { return }
            self.handleTurn(turn)
          }
        },
        onError: { [weak self] error in
          Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.isRunning { return }
            self.delegate?.liveTranscriber(self, didFail: error)
          }
        }
      )

      guard let transcriber else { throw AssemblyAIError.connectionFailed }

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

      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      isRunning = true
      streamingStartTime = Date()
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  private func handleTurn(_ turn: AssemblyAITurnResponse) {
    guard !turn.transcript.isEmpty || turn.end_of_turn else { return }

    let eot = turn.end_of_turn
    let fmt = turn.turn_is_formatted
    logger.debug("Turn: order=\(turn.turn_order) end=\(eot) formatted=\(fmt) len=\(turn.transcript.count)")

    if let langCode = turn.language_code {
      logger.info("Detected language: \(langCode) (confidence: \(turn.language_confidence ?? 0))")
    }

    // Utterance boundary — trigger immediate polish before end-of-turn
    if let utterance = turn.utterance, !utterance.isEmpty {
      delegate?.liveTranscriber(self, didDetectUtteranceBoundary: utterance)
    }

    if turn.end_of_turn && turn.turn_is_formatted {
      // Universal-3.5 Pro returns one formatted final for each end-of-turn.
      let segment = TranscriptionSegment(startTime: 0, endTime: 0, text: turn.transcript)

      if let existingIndex = finalSegmentIndexByTurnOrder[turn.turn_order],
        finalSegments.indices.contains(existingIndex) {
        finalSegments[existingIndex] = segment
        // Replaced an existing turn — must rebuild from scratch
        fullTranscript = finalSegments.map(\.text).joined(separator: " ")
      } else {
        finalSegments.append(segment)
        finalSegmentIndexByTurnOrder[turn.turn_order] = finalSegments.count - 1
        // Appended a new turn — incremental update
        if fullTranscript.isEmpty {
          fullTranscript = turn.transcript
        } else {
          fullTranscript.append(contentsOf: " \(turn.transcript)")
        }
      }
      currentInterim = ""
      currentTurnOrder = -1
      delegate?.liveTranscriber(self, didUpdatePartial: fullTranscript)

      // Signal stop() that the final turn has been captured
      if hasFinished, let continuation = stopContinuation {
        stopContinuation = nil
        continuation.resume()
      }
    } else {
      // Ongoing turn — replace interim (AssemblyAI sends the full running
      // transcript text on every Turn frame, including non-final words).
      currentTurnOrder = turn.turn_order
      currentInterim = turn.transcript
      rebuildDisplay()
    }
  }

  private func rebuildDisplay() {
    let displayText = fullTranscript.isEmpty
      ? currentInterim
      : fullTranscript + " " + currentInterim
    delegate?.liveTranscriber(self, didUpdatePartial: displayText)
  }

  // Audio processor that resamples and forwards to AssemblyAI
  private final class AssemblyAIAudioProcessor: @unchecked Sendable {
    private static let minimumChunkBytes = 1600   // 50ms @ 16kHz PCM16 mono
    private static let preferredChunkBytes = 3200 // 100ms @ 16kHz PCM16 mono

    private let queue = DispatchQueue(label: "com.speak.app.assemblyai.audioProcessing")
    private var isRunning: Bool = false
    private var cachedConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private var reusableOutputBuffer: AVAudioPCMBuffer?
    private var pendingPCMData = Data()

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

    func flushPendingAudio(to transcriber: AssemblyAILiveTranscriber) {
      queue.sync {
        guard !pendingPCMData.isEmpty else { return }

        var offset = 0
        while pendingPCMData.count - offset >= Self.preferredChunkBytes {
          let chunk = pendingPCMData.subdata(in: offset..<(offset + Self.preferredChunkBytes))
          transcriber.sendAudio(chunk)
          offset += Self.preferredChunkBytes
        }
        if offset > 0 {
          pendingPCMData = Data(pendingPCMData.dropFirst(offset))
        }

        guard !pendingPCMData.isEmpty else { return }
        if pendingPCMData.count < Self.minimumChunkBytes {
          pendingPCMData.append(
            contentsOf: repeatElement(0, count: Self.minimumChunkBytes - pendingPCMData.count))
        }
        transcriber.sendAudio(pendingPCMData)
        pendingPCMData.removeAll(keepingCapacity: false)
      }
    }

    func handleAudioTap(
      _ buffer: AVAudioPCMBuffer,
      inputFormat: AVAudioFormat,
      outputFormat: AVAudioFormat,
      transcriber: AssemblyAILiveTranscriber,
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
      transcriber: AssemblyAILiveTranscriber,
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

      converter.reset()
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
      while pendingPCMData.count - offset >= Self.preferredChunkBytes {
        let chunk = pendingPCMData.subdata(in: offset..<(offset + Self.preferredChunkBytes))
        transcriber.sendAudio(chunk)
        offset += Self.preferredChunkBytes
      }
      if offset > 0 {
        pendingPCMData = Data(pendingPCMData.dropFirst(offset))
      }
    }
  }

  func stop() async {
    guard isRunning else { return }
    guard !hasFinished else { return }
    hasFinished = true

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false

    // Wait for the final Turn response triggered by ForceEndpoint, with a timeout.
    if let transcriber {
      audioProcessor.flushPendingAudio(to: transcriber)
      await transcriber.waitForPendingSends()
      audioProcessor.setRunning(false)
      // Send ForceEndpoint *without* closing the socket so the formatted
      // final Turn can arrive on the same WebSocket while we wait below.
      // Skip the wait when the AssemblyAI session never received its
      // `Begin` ack — there is no Turn to wait for.
      let serverBegan = transcriber.didReceiveBegin()
      if serverBegan {
        transcriber.sendForceEndpoint()
      }
      // Wait for the final Turn response (resumed in handleTurn) or the
      // model-specific finalize budget, whichever comes first. Both paths
      // nil-out stopContinuation under the MainActor before resuming, so
      // resume is idempotent.
      let budget = appSettings.liveModelCapabilities.postStopFinalizeBudget
      if budget > 0, serverBegan {
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
      // Apply the user grace AFTER the finalisation budget but BEFORE
      // tearing down the socket — extra trailing-finals window without
      // delaying the ForceEndpoint signal.
      await applyLiveStopGrace(appSettings.liveStopGracePeriod)
      // Only now tear down the socket (sends Terminate + cancel).
      transcriber.stop()
    } else {
      audioProcessor.setRunning(false)
    }

    let result = buildFinalResult()
    await MainActor.run {
      delegate?.liveTranscriber(self, didFinishWith: result)
    }

    await endActiveInputSession()
    transcriber = nil
  }

  private func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    isRunning = false
    audioProcessor.setRunning(false)
    transcriber?.stop()
    transcriber = nil
    targetFormat = nil
    streamingStartTime = nil
    currentInterim = ""
    currentTurnOrder = -1
    finalSegments = []
    finalSegmentIndexByTurnOrder = [:]
    fullTranscript = ""
    stopContinuation = nil
    await endActiveInputSession()
  }

  private func buildFinalResult() -> TranscriptionResult {
    logger.info(
      "Building result: segments=\(self.finalSegments.count) interim=\(self.currentInterim.count) chars"
    )
    var text = finalSegments.map(\.text).joined(separator: " ")
    let trimmedInterim = currentInterim.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedInterim.isEmpty {
      if !text.isEmpty { text += " " }
      text += trimmedInterim
    }

    let streamingDuration: TimeInterval
    if let startTime = streamingStartTime {
      streamingDuration = Date().timeIntervalSince(startTime)
    } else {
      streamingDuration = 0
    }

    return TranscriptionResult(
      text: text,
      segments: finalSegments,
      confidence: nil,
      duration: streamingDuration,
      modelIdentifier: currentModel ?? AssemblyAIModels.universal35ProStreamingID,
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }

  private func ensurePermissions() async -> Bool {
    // Remote streaming providers only need microphone access; speech recognition
    // permission is exclusive to the on-device Apple transcriber.
    let microphone = await permissionsManager.ensureGranted(.microphone)
    return microphone.isGranted
  }

  private func assemblyAIAPIKey() async throws -> String {
    do {
      let apiKey = try await secureStorage.secret(identifier: "assemblyai.apiKey")
      guard !apiKey.isEmpty else { throw AssemblyAIError.missingAPIKey }
      return apiKey
    } catch let error as SecureAppStorageError {
      if case .valueNotFound = error {
        throw AssemblyAIError.missingAPIKey
      }
      throw error
    } catch {
      throw error
    }
  }
}
// swiftlint:enable type_body_length
