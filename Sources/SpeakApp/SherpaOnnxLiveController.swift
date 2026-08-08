// swiftlint:disable file_length
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
  /// Sink for the current process's stderr. Replaced on every start so stderr
  /// from a previous sidecar can never be attributed to this session.
  private var sidecarErrorSink: SidecarErrorSink?
  /// Set once `process.run()` succeeds; the pipes only reach EOF for a process
  /// that actually launched, so draining them is unsafe before this is true.
  private var processDidLaunch = false
  /// Cap on retained sidecar stderr so a chatty process cannot grow this without bound.
  private static let maxSidecarErrorByteCount = 8192

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
    processDidLaunch = false
    let errorSink = SidecarErrorSink(maxByteCount: Self.maxSidecarErrorByteCount)
    sidecarErrorSink = errorSink
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

    // Drain stderr continuously: an undrained pipe fills its kernel buffer and
    // blocks the sidecar's next write, which would stall transcription entirely.
    // The append is synchronous and capped, so a burst of stderr neither spawns
    // a task per read nor grows memory; the sink is captured by value so bytes
    // always land in the session they were produced for.
    stderrPipe.fileHandleForReading.readabilityHandler = { [errorSink] handle in
      errorSink.append(handle.availableData)
    }

    do {
      try process.run()
      processDidLaunch = true
    } catch {
      // The pipes, handlers and `process` are already stored on self; without
      // this the failed launch would leave them attached to the next start.
      await cleanupAfterFailedStart()
      throw error
    }

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
    drainRemainingSidecarPipes()
    processRemainingSidecarOutput()
    logSidecarErrorOutput()
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
      "--feature-dim", "\(bundle.featureDim)",
      "--model-type", bundle.modelType
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

  private func logSidecarErrorOutput() {
    guard let captured = sidecarErrorSink?.drainText()
      .trimmingCharacters(in: .whitespacesAndNewlines), !captured.isEmpty
    else { return }
    logger.error("sherpa-onnx sidecar stderr: \(captured, privacy: .public)")
  }

  /// Detaches the readability handlers and picks up whatever the sidecar left in
  /// the pipes. `resetProcessState()` drops the pipes straight after, so bytes
  /// still sitting in the kernel buffer when the process exited would otherwise
  /// never reach the logs. Only reads once the process has actually exited:
  /// `availableData` blocks while a writer is still attached to the pipe.
  private func drainRemainingSidecarPipes() {
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    guard processDidLaunch, process?.isRunning == false else { return }
    if let stdout = stdoutPipe?.fileHandleForReading {
      for chunk in Self.remainingData(on: stdout) {
        handleSidecarOutput(chunk)
      }
    }
    if let stderr = stderrPipe?.fileHandleForReading, let sink = sidecarErrorSink {
      for chunk in Self.remainingData(on: stderr) {
        sink.append(chunk)
      }
    }
  }

  /// Reads buffered bytes until EOF, bounded so a pipe that somehow still has a
  /// writer attached can never spin the main actor indefinitely.
  private static func remainingData(on handle: FileHandle) -> [Data] {
    var chunks: [Data] = []
    for _ in 0..<8 {
      let chunk = handle.availableData
      guard !chunk.isEmpty else { break }
      chunks.append(chunk)
    }
    return chunks
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
    // Offline transducer models (Parakeet TDT) decode the whole session once
    // stdin closes, so long recordings need more headroom than the online
    // models, which exit almost immediately.
    for _ in 0..<100 where process.isRunning {
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
    // `terminate()` raises on a process that never launched, which is exactly
    // the case when `process.run()` itself is what failed.
    if let process, process.isRunning {
      process.terminate()
    }
    drainRemainingSidecarPipes()
    logSidecarErrorOutput()
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
    processDidLaunch = false
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil
    streamingStartTime = nil
    sidecarOutputBuffer = ""
    sidecarErrorSink = nil
  }

  private struct SidecarEvent: Decodable {
    let type: String
    let text: String?
    let message: String?
  }

  /// Capped, lock-guarded store for one sidecar's stderr.
  ///
  /// The pipe's readability handler runs on its own dispatch queue and appends
  /// here directly, so draining costs no task allocation per read and the
  /// retained bytes stay bounded regardless of how chatty the process is.
  /// Bytes are decoded only when read back: `availableData` can split a
  /// multibyte UTF-8 sequence across two reads, which would make a per-chunk
  /// decode drop the chunk.
  private final class SidecarErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let maxByteCount: Int

    init(maxByteCount: Int) {
      self.maxByteCount = maxByteCount
    }

    func append(_ data: Data) {
      guard !data.isEmpty else { return }
      lock.lock()
      defer { lock.unlock() }
      buffer.append(data)
      guard buffer.count > maxByteCount else { return }
      buffer.removeFirst(buffer.count - maxByteCount)
      // Trimming the head can land mid-character; drop the orphaned
      // continuation bytes so the log doesn't start with a replacement char.
      while let first = buffer.first, first & 0xC0 == 0x80 {
        buffer.removeFirst()
      }
    }

    func drainText() -> String {
      lock.lock()
      let captured = buffer
      buffer = Data()
      lock.unlock()
      // Deliberately lossy: a failable decode would throw away a whole log
      // fragment because the head was trimmed mid-character.
      // swiftlint:disable:next optional_data_string_conversion
      return String(decoding: captured, as: UTF8.self)
    }
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
