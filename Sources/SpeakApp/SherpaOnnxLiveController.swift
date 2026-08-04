import SpeakCore
@preconcurrency import AVFoundation
import Foundation
import os.log

#if !APP_STORE
@MainActor
// swiftlint:disable type_body_length
final class SherpaOnnxLiveController: NSObject, LiveTranscriptionController {
  weak var delegate: LiveTranscriptionSessionDelegate?
  private(set) var isRunning: Bool = false

  private let appSettings: AppSettings
  private let permissionsManager: PermissionsManager
  private let audioDeviceManager: AudioInputDeviceManager
  private let runtimeManager: SherpaOnnxRuntimeManager
  private var audioEngine = AVAudioEngine()
  private let audioProcessor = SherpaOnnxAudioProcessor()
  private let targetSampleRate: Double = 16000
  private let logger = Logger(subsystem: "com.github.speakapp", category: "SherpaOnnxLiveController")

  private var process: Process?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var activeInputSession: AudioInputDeviceManager.SessionContext?
  private var currentModel: String?
  private var streamingStartTime: Date?
  private var latestText: String = ""
  private var hasFinished: Bool = false
  private var isStopping: Bool = false
  private var sidecarOutputBuffer = ""

  init(
    appSettings: AppSettings,
    permissionsManager: PermissionsManager,
    audioDeviceManager: AudioInputDeviceManager,
    runtimeManager: SherpaOnnxRuntimeManager
  ) {
    self.appSettings = appSettings
    self.permissionsManager = permissionsManager
    self.audioDeviceManager = audioDeviceManager
    self.runtimeManager = runtimeManager
  }

  func configure(language: String?, model: String) {
    currentModel = model
  }

  // swiftlint:disable:next function_body_length
  func start() async throws {
    guard !isRunning, !isStopping else {
      throw TranscriptionManagerError.liveSessionAlreadyRunning
    }
    guard await permissionsManager.ensureGranted(.microphone).isGranted else {
      throw TranscriptionManagerError.microphonePermissionMissing
    }

    let modelID = currentModel ?? appSettings.localStreamingModelSource
    let bundle = try await runtimeManager.ensureReady(sourceID: modelID)
    let process = try makeProcess(bundle: bundle)
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }

    latestText = ""
    hasFinished = false
    sidecarOutputBuffer = ""
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe

    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor [weak self] in
        self?.handleSidecarOutput(data)
      }
    }

    try process.run()

    let sessionContext = await audioDeviceManager.beginUsingPreferredInput()
    activeInputSession = sessionContext
    audioEngine = AVAudioEngine()

    do {
      let inputNode = audioEngine.inputNode
      inputNode.removeTap(onBus: 0)
      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard audioInputFormatIsUsable(inputFormat) else {
        throw TranscriptionManagerError.noUsableAudioInput
      }
      guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
      ) else {
        throw SherpaOnnxRuntimeError.processFailed("Could not create 16 kHz Float32 audio format.")
      }
      let writer = stdinPipe.fileHandleForWriting
      audioProcessor.setRunning(true)
      let processor = audioProcessor
      let log = logger
      inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
        processor.handleAudioTap(
          buffer,
          inputFormat: inputFormat,
          outputFormat: outputFormat,
          writer: writer,
          logger: log
        )
      }
      try await startAudioEngineAfterInputDeviceSettles(audioEngine)
      streamingStartTime = Date()
      isRunning = true
    } catch {
      await cleanupAfterFailedStart()
      throw error
    }
  }

  func stop() async {
    guard isRunning else { return }
    isStopping = true
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    audioProcessor.setRunning(false)

    await applyLiveStopGrace(appSettings.liveStopGracePeriod)
    try? stdinPipe?.fileHandleForWriting.close()
    await waitForProcessExit()
    processRemainingSidecarOutput()
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    isRunning = false

    let duration = streamingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    let result = TranscriptionResult(
      text: latestText,
      segments: latestText.isEmpty ? [] : [
        TranscriptionSegment(startTime: 0, endTime: duration, text: latestText)
      ],
      confidence: nil,
      duration: duration,
      modelIdentifier: currentModel ?? appSettings.localStreamingModelSource,
      cost: nil,
      rawPayload: nil,
      debugInfo: nil
    )
    hasFinished = true
    delegate?.liveTranscriber(self, didFinishWith: result)
    await endActiveInputSession()
    resetProcessState()
    isStopping = false
  }

  private func makeProcess(bundle: SherpaOnnxModelBundle) throws -> Process {
    let process = Process()
    process.executableURL = try runtimeManager.pythonExecutable()
    process.arguments = [
      "-u",
      try runtimeManager.sidecarScriptURL().path,
      "--tokens", bundle.tokens.path,
      "--encoder", bundle.encoder.path,
      "--decoder", bundle.decoder.path,
      "--joiner", bundle.joiner.path,
      "--feature-dim", "\(bundle.featureDim)"
    ]
    return process
  }

  private func handleSidecarOutput(_ data: Data) {
    guard !hasFinished else { return }
    guard let output = String(data: data, encoding: .utf8) else { return }
    sidecarOutputBuffer += output
    let lines = sidecarOutputBuffer.split(separator: "\n", omittingEmptySubsequences: false)
    sidecarOutputBuffer = lines.last.map(String.init) ?? ""
    for line in lines.dropLast() {
      decodeSidecarEvent(String(line))
    }
  }

  private func processRemainingSidecarOutput() {
    let remaining = sidecarOutputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    sidecarOutputBuffer = ""
    guard !remaining.isEmpty else { return }
    decodeSidecarEvent(remaining)
  }

  private func decodeSidecarEvent(_ line: String) {
    guard !hasFinished else { return }
    guard let lineData = line.data(using: .utf8),
      let event = try? JSONDecoder().decode(SidecarEvent.self, from: lineData)
    else { return }
    switch event.type {
    case "partial", "session_final":
      guard let rawText = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !rawText.isEmpty else {
        return
      }
      let text = SherpaOnnxTranscriptNormalizer.normalize(rawText)
      latestText = text
      let update = LiveTranscriptionUpdate(text: text, isFinal: event.type == "session_final")
      delegate?.liveTranscriber(self, didUpdateWith: update)
      delegate?.liveTranscriber(self, didUpdatePartial: text)
    case "error":
      delegate?.liveTranscriber(
        self,
        didFail: SherpaOnnxRuntimeError.processFailed(event.message ?? "Unknown sherpa-onnx error.")
      )
    default:
      break
    }
  }

  private func waitForProcessExit() async {
    guard let process else { return }
    for _ in 0..<40 where process.isRunning {
      try? await Task.sleep(for: .milliseconds(100))
    }
    if process.isRunning {
      process.terminate()
    }
  }

  private func cleanupAfterFailedStart() async {
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    audioProcessor.setRunning(false)
    try? stdinPipe?.fileHandleForWriting.close()
    process?.terminate()
    isRunning = false
    isStopping = false
    await endActiveInputSession()
    resetProcessState()
  }

  private func endActiveInputSession() async {
    guard let session = activeInputSession else { return }
    activeInputSession = nil
    await audioDeviceManager.endUsingPreferredInput(session: session)
  }

  private func resetProcessState() {
    process = nil
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil
    streamingStartTime = nil
    sidecarOutputBuffer = ""
  }

  private struct SidecarEvent: Decodable {
    let type: String
    let text: String?
    let message: String?
  }

  private final class SherpaOnnxAudioProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.github.speakapp.sherpa-onnx.audioProcessing")
    private var isRunning = false
    private var cachedConverter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private var reusableOutputBuffer: AVAudioPCMBuffer?

    func setRunning(_ running: Bool) {
      queue.sync {
        isRunning = running
        if !running {
          cachedConverter = nil
          cachedInputFormat = nil
          reusableOutputBuffer = nil
        }
      }
    }

    func handleAudioTap(
      _ buffer: AVAudioPCMBuffer,
      inputFormat: AVAudioFormat,
      outputFormat: AVAudioFormat,
      writer: FileHandle,
      logger: Logger
    ) {
      guard let copied = copyPCMBuffer(buffer) else { return }
      queue.async { [weak self] in
        guard let self, self.isRunning else { return }
        self.processAndWriteAudio(copied, from: inputFormat, to: outputFormat, writer: writer, logger: logger)
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
        guard let srcData = src[idx].mData, let dstData = dst[idx].mData else { continue }
        dstData.copyMemory(from: srcData, byteCount: Int(src[idx].mDataByteSize))
        dst[idx].mDataByteSize = src[idx].mDataByteSize
      }
      return copy
    }

    private func processAndWriteAudio(
      _ buffer: AVAudioPCMBuffer,
      from inputFormat: AVAudioFormat,
      to outputFormat: AVAudioFormat,
      writer: FileHandle,
      logger: Logger
    ) {
      let converter: AVAudioConverter
      if let cachedConverter, cachedInputFormat == inputFormat {
        converter = cachedConverter
      } else {
        guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
          logger.error("Failed to create sherpa-onnx audio converter")
          return
        }
        cachedConverter = newConverter
        cachedInputFormat = inputFormat
        converter = newConverter
      }

      let ratio = outputFormat.sampleRate / inputFormat.sampleRate
      let capacity = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio + 32))
      let outputBuffer: AVAudioPCMBuffer
      if let reusableOutputBuffer, reusableOutputBuffer.frameCapacity >= capacity {
        reusableOutputBuffer.frameLength = 0
        outputBuffer = reusableOutputBuffer
      } else {
        guard let newBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        reusableOutputBuffer = newBuffer
        outputBuffer = newBuffer
      }

      var didProvideInput = false
      var error: NSError?
      let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        if didProvideInput {
          outStatus.pointee = .noDataNow
          return nil
        }
        didProvideInput = true
        outStatus.pointee = .haveData
        return buffer
      }
      guard status != .error, error == nil, let channelData = outputBuffer.floatChannelData else {
        let errorDescription = error?.localizedDescription ?? "unknown"
        logger.error("sherpa-onnx audio conversion failed: \(errorDescription, privacy: .public)")
        return
      }
      let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Float>.size
      let data = Data(bytes: channelData[0], count: byteCount)
      do {
        try writer.write(contentsOf: data)
      } catch {
        logger.error("Failed to write audio to sherpa-onnx: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
// swiftlint:enable type_body_length
#endif
