#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import os.log

// swiftlint:disable file_length

/// iOS live transcriber backed by OpenAI's Realtime API in transcription mode.
///
/// Mirrors the macOS `OpenAIRealtimeLiveTranscriber` / `OpenAIRealtimeLiveController`
/// pair, collapsed into a single `ObservableObject` to match the existing
/// iOS provider shape (`DeepgramLiveTranscriber`, `ElevenLabsLiveTranscriber`).
///
/// Endpoint:
/// - Beta (default): `wss://api.openai.com/v1/realtime?intent=transcription`
/// - GA (gpt-realtime-whisper): `wss://api.openai.com/v1/realtime?model=<name>`
/// Audio: PCM16 mono @ 24 kHz, base64 in `input_audio_buffer.append`.
/// On stop we wait for the session config ack, flush, send
/// `input_audio_buffer.commit`, then wait for the final `.completed` event
/// or `postStopFinalizeBudget` (0.5 s) — whichever comes first.
@MainActor
// swiftlint:disable:next type_body_length
public final class OpenAIRealtimeLiveTranscriber: ObservableObject {
    // MARK: - Published State

    @Published public private(set) var isRunning = false
    @Published public private(set) var partialText = ""
    @Published public private(set) var finalText = ""
    @Published public private(set) var error: Error?

    // MARK: - Configuration

    public var language: String? = Locale.current.language.languageCode?.identifier
    /// Catalogue id like `openai/gpt-realtime-whisper-streaming`. The
    /// `-streaming` suffix is stripped before being sent to OpenAI.
    public var modelID: String = "gpt-realtime-whisper-streaming"

    // MARK: - Callbacks

    public var onPartialResult: ((String, Bool) -> Void)?
    public var onFinalResult: ((TranscriptionResult) -> Void)?
    public var onError: ((Error) -> Void)?

    // MARK: - Private

    private let audioSessionManager: AudioSessionManager
    private let audioEngine = AVAudioEngine()
    private var apiKey: String?
    private var startTime: Date?
    private var transcriber: OpenAIRealtimeWebSocketClient?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private static let targetSampleRate: Double = 24_000

    /// Per-segment bookkeeping keyed by `item_id`. Mirrors the macOS
    /// controller — keeps stable order for multi-segment commits.
    private var itemOrder: [String] = []
    private var finalsByItem: [String: String] = [:]
    private var currentDeltasByItem: [String: String] = [:]
    /// Item ids that completed *before* the user pressed stop. We only
    /// resume the stop continuation on a *new* completion — typically the
    /// one triggered by our explicit commit.
    private var preStopCompletedItemIDs: Set<String> = []
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var hasFinishedStopping = false

    /// Persistent audio recorder — saves audio to disk alongside transcription.
    public let audioRecorder = AudioRecordingPersistence()

    // MARK: - Init

    public init(audioSessionManager: AudioSessionManager) {
        self.audioSessionManager = audioSessionManager
        setupInterruptionHandling()
    }

    // MARK: - Public API

    public func configure(apiKey: String) {
        self.apiKey = apiKey
    }

    public var isConfigured: Bool {
        apiKey?.isEmpty == false
    }

    public func start() async throws {
        guard !isRunning else { return }

        SpeakLogger.logTranscription(event: "start", model: "openai/\(modelID)")

        guard let apiKey, !apiKey.isEmpty else {
            let err = OpenAIRealtimeError.missingAPIKey
            SpeakLogger.logError(err, context: "OpenAIRealtimeLiveTranscriber.start", logger: SpeakLogger.transcription)
            self.error = err
            throw err
        }

        try await ensureMicrophonePermission()
        try configureAudioSession()
        connectClient(apiKey: apiKey)
        do {
            try startAudioEngine()
        } catch {
            transcriber?.stop()
            transcriber = nil
            throw error
        }
        resetState()

        print("[OpenAIRealtimeLiveTranscriber] Started")
    }

    public func stop() async -> TranscriptionResult {
        guard isRunning else {
            return emptyResult()
        }

        hasFinishedStopping = true
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        preStopCompletedItemIDs = Set(finalsByItem.keys)

        if let client = transcriber {
            await finalizeRemoteSession(client)
        }
        transcriber = nil

        _ = audioRecorder.stopRecording()

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let text = composedTranscript()

        let result = TranscriptionResult(
            text: text,
            segments: [],
            confidence: nil,
            duration: duration,
            modelIdentifier: "openai/\(modelID)",
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )

        isRunning = false
        audioSessionManager.deactivate()

        SpeakLogger.logTranscription(
            event: "stop",
            model: "openai/\(modelID)",
            wordCount: result.text.split(separator: " ").count
        )
        onFinalResult?(result)

        return result
    }

    /// Stop sequence that must run while we still have a live WebSocket client:
    /// 1. Await session-ready (config ack) so any pre-ready buffered audio
    ///    is dispatched correctly (or the timeout lapses).
    /// 2. Await pending audio sends.
    /// 3. Send commit.
    /// 4. Await the commit's send to complete before starting the finalize
    ///    budget — otherwise the budget can elapse before the server has
    ///    even seen our commit.
    /// 5. Wait for a *new* completed event or the budget, whichever comes
    ///    first.
    /// 6. Close the socket.
    private func finalizeRemoteSession(_ client: OpenAIRealtimeWebSocketClient) async {
        _ = await client.awaitSessionReady(timeout: 1.0)
        await client.waitForPendingSends()
        client.commitInputBuffer()
        await client.waitForPendingSends()

        let budget: TimeInterval = 0.5
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
            // Capture continuation explicitly so a deallocated transcriber
            // never leaks an unresumed continuation. We also identity-check
            // against `stopContinuation` to avoid double-resuming if a real
            // .completed event already fired before the budget elapsed.
            Task(priority: .userInitiated) { [weak self, continuation] in
                try? await Task.sleep(for: .seconds(budget))
                guard let self else {
                    continuation.resume()
                    return
                }
                guard let cont = self.stopContinuation else { return }
                self.stopContinuation = nil
                cont.resume()
            }
        }

        client.stop()
    }

    private func emptyResult() -> TranscriptionResult {
        TranscriptionResult(
            text: composedTranscript(),
            segments: [],
            confidence: nil,
            duration: 0,
            modelIdentifier: "openai/\(modelID)",
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    public func cancel() {
        guard isRunning else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        transcriber?.stop()
        transcriber = nil

        audioRecorder.cancelRecording()

        isRunning = false
        audioSessionManager.deactivate()

        print("[OpenAIRealtimeLiveTranscriber] Cancelled")
    }

    // MARK: - Private

    private func ensureMicrophonePermission() async throws {
        if !audioSessionManager.hasMicrophonePermission() {
            let granted = await audioSessionManager.requestMicrophonePermission()
            if !granted {
                let err = iOSTranscriptionError.permissionDenied(.microphone)
                SpeakLogger.logError(err, context: "Microphone permission", logger: SpeakLogger.audio)
                self.error = err
                throw err
            }
        }
    }

    private func configureAudioSession() throws {
        do {
            try audioSessionManager.configureForRecording()
            SpeakLogger.audio.info("Audio session configured for OpenAI Realtime")
        } catch {
            let wrapped = iOSTranscriptionError.audioSessionFailed(error)
            SpeakLogger.logError(wrapped, context: "Audio session setup", logger: SpeakLogger.audio)
            self.error = wrapped
            throw wrapped
        }
    }

    private func connectClient(apiKey: String) {
        let realtimeName = Self.realtimeModelName(from: modelID)
        let client = OpenAIRealtimeWebSocketClient(
            apiKey: apiKey,
            model: realtimeName,
            language: language.map(Self.extractLanguageCode(from:)),
            sampleRate: Int(Self.targetSampleRate)
        )
        transcriber = client
        SpeakLogger.network.info("Connecting to OpenAI Realtime streaming API")
        client.start(
            onEvent: { [weak self] event in
                Task { @MainActor in
                    self?.handleEvent(event)
                }
            },
            onError: { [weak self] err in
                Task { @MainActor in
                    self?.handleError(err)
                }
            }
        )
    }

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let (target, conv) = try createAudioConverter(from: nativeFormat)
        targetFormat = target
        converter = conv
        let client = transcriber

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            self?.audioRecorder.writeBuffer(buffer)
            self?.convertAndSendAudio(
                buffer: buffer,
                nativeFormat: nativeFormat,
                targetFormat: target,
                converter: conv,
                client: client
            )
        }

        audioEngine.prepare()
        try audioEngine.start()
        try? audioRecorder.startRecording(format: nativeFormat)
    }

    private func createAudioConverter(
        from nativeFormat: AVAudioFormat
    ) throws -> (AVAudioFormat, AVAudioConverter) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            let err = iOSTranscriptionError.audioSessionFailed(
                NSError(domain: "OpenAIRealtimeLiveTranscriber", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format"])
            )
            self.error = err
            throw err
        }
        guard let conv = AVAudioConverter(from: nativeFormat, to: target) else {
            let err = iOSTranscriptionError.audioSessionFailed(
                NSError(domain: "OpenAIRealtimeLiveTranscriber", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
            )
            self.error = err
            throw err
        }
        return (target, conv)
    }

    private nonisolated func convertAndSendAudio(
        buffer: AVAudioPCMBuffer,
        nativeFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        client: OpenAIRealtimeWebSocketClient?
    ) {
        let ratio = Self.targetSampleRate / nativeFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error,
              let int16Channel = outputBuffer.int16ChannelData?[0] else { return }
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }
        let byteCount = frameCount * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Channel, count: byteCount)
        client?.sendAudio(data)
    }

    private func resetState() {
        partialText = ""
        finalText = ""
        error = nil
        startTime = Date()
        itemOrder = []
        finalsByItem = [:]
        currentDeltasByItem = [:]
        preStopCompletedItemIDs = []
        hasFinishedStopping = false
        stopContinuation = nil
        isRunning = true
    }

    private func setupInterruptionHandling() {
        audioSessionManager.onInterruption = { [weak self] began in
            Task { @MainActor in
                if began { self?.handleInterruption() }
            }
        }
    }

    private func handleInterruption() {
        guard isRunning else { return }
        print("[OpenAIRealtimeLiveTranscriber] Handling interruption")
        let err = iOSTranscriptionError.interrupted
        error = err
        onError?(err)
        Task { _ = await stop() }
    }

    private func handleEvent(_ event: OpenAIRealtimeWebSocketClient.Event) {
        switch event {
        case .sessionCreated:
            SpeakLogger.transcription.info("OpenAI Realtime session created (awaiting config ack)")
        case .sessionReady:
            SpeakLogger.transcription.info("OpenAI Realtime session ready (config applied)")
        case .delta(let text, let itemId):
            let key = itemId.isEmpty ? "_pending" : itemId
            if currentDeltasByItem[key] == nil, finalsByItem[key] == nil {
                itemOrder.append(key)
            }
            currentDeltasByItem[key, default: ""].append(text)
            partialText = composedTranscript()
            onPartialResult?(partialText, false)
        case .completed(let transcript, let itemId):
            let key = itemId.isEmpty ? "_pending" : itemId
            let isNewItem = !preStopCompletedItemIDs.contains(key)
            if currentDeltasByItem[key] == nil, finalsByItem[key] == nil {
                itemOrder.append(key)
            }
            finalsByItem[key] = transcript
            currentDeltasByItem.removeValue(forKey: key)
            partialText = composedTranscript()
            finalText = composedTranscript()
            onPartialResult?(partialText, true)

            if hasFinishedStopping, isNewItem, let cont = stopContinuation {
                stopContinuation = nil
                cont.resume()
            }
        }
    }

    private func handleError(_ err: Error) {
        error = err
        onError?(err)
    }

    private func composedTranscript() -> String {
        itemOrder.compactMap { key in
            finalsByItem[key] ?? currentDeltasByItem[key]
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    /// Translate catalogue id `openai/gpt-realtime-whisper-streaming` (or
    /// already-stripped `gpt-realtime-whisper-streaming`) to the OpenAI API
    /// model name `gpt-realtime-whisper`.
    static func realtimeModelName(from modelID: String) -> String {
        var name = modelID
        if name.hasPrefix("openai/") {
            name = String(name.dropFirst("openai/".count))
        }
        if name.hasSuffix("-streaming") {
            name = String(name.dropLast("-streaming".count))
        }
        return name
    }

    /// Normalises a BCP-47 locale identifier (e.g. "en-GB", "en_US") to the
    /// ISO-639-1 two-letter code OpenAI Realtime expects (e.g. "en"). Mirrors
    /// the helper used by the macOS provider.
    static func extractLanguageCode(from locale: String) -> String {
        let components = locale.split(whereSeparator: { $0 == "_" || $0 == "-" })
        return components.first.map(String.init)?.lowercased() ?? locale.lowercased()
    }
}

// MARK: - Errors

public enum OpenAIRealtimeError: LocalizedError, Sendable {
    case missingAPIKey
    case connectionFailed(String)
    case sessionError(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is not configured."
        case .connectionFailed(let message):
            return "OpenAI Realtime connection failed: \(message)"
        case .sessionError(let message):
            return "OpenAI Realtime session error: \(message)"
        }
    }
}

// MARK: - WebSocket client

// swiftlint:disable type_body_length
/// WebSocket client for the OpenAI Realtime API in transcription mode.
/// Off-MainActor; `@unchecked Sendable` with `NSLock` state guarding,
/// matching the macOS implementation.
final class OpenAIRealtimeWebSocketClient: @unchecked Sendable {
    enum Event {
        case sessionCreated
        case sessionReady
        case delta(String, itemId: String)
        case completed(String, itemId: String)
    }

    private enum AudioSendAction {
        case send(URLSessionWebSocketTask)
        case buffer
        case drop
    }

    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let session: URLSession
    private let logger = Logger(subsystem: "com.speak.ios", category: "OpenAIRealtimeWebSocket")
    private let stateLock = NSLock()
    private let pendingSendGroup = DispatchGroup()

    private var webSocketTask: URLSessionWebSocketTask?
    private var onEvent: ((Event) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isStopping: Bool = false
    private var sessionReady: Bool = false
    private var readyWaitTokens: [WaitToken] = []
    private var preReadyAudioBuffer: [Data] = []
    private var preReadyAudioBufferBytes: Int = 0
    private static let preReadyAudioByteLimit = 24_000 * 2 * 5 // 5s of 24 kHz PCM16

    init(apiKey: String, model: String, language: String?, sampleRate: Int) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func start(onEvent: @escaping (Event) -> Void, onError: @escaping (Error) -> Void) {
        withStateLock {
            isStopping = false
            sessionReady = false
            preReadyAudioBuffer = []
            preReadyAudioBufferBytes = 0
            self.onEvent = onEvent
            self.onError = onError
        }

        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            onError(OpenAIRealtimeError.connectionFailed("Invalid URL"))
            return
        }
        // All GA transcription models share the same `?intent=transcription`
        // URL with a unified `session.update` payload. The legacy
        // `?model=<name>` URL creates a realtime conversation session and
        // rejects transcription `session.update` events. The legacy
        // `OpenAI-Beta: realtime=v1` header pins the server to the old
        // schema and rejects `session.type`, so we omit it.
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        guard let url = components.url else {
            onError(OpenAIRealtimeError.connectionFailed("Invalid URL components"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        withStateLock { webSocketTask = task }
        task.resume()
        sendSessionUpdate()
        receiveMessages()
    }

    func stop() {
        let task: URLSessionWebSocketTask? = withStateLock {
            isStopping = true
            let snapshot = webSocketTask
            webSocketTask = nil
            onEvent = nil
            onError = nil
            return snapshot
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Outbound

    private func sendSessionUpdate() {
        // turn_detection: null mirrors the macOS provider — push-to-talk
        // semantics. Deltas may only arrive after we send commit.
        var transcription: [String: Any] = [:]
        transcription["model"] = model
        if let language { transcription["language"] = language }

        let payload: [String: Any] = [
            // Unified GA shape for all transcription models. The legacy
            // `transcription_session.update` event was removed during GA.
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "transcription": transcription,
                        "noise_reduction": ["type": "near_field"],
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
        sendJSON(payload)
    }

    func sendAudio(_ pcmData: Data) {
        let base64 = pcmData.base64EncodedString()
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64
        ]

        let action: AudioSendAction = withStateLock {
            if isStopping { return .drop }
            if !sessionReady {
                if preReadyAudioBufferBytes + pcmData.count <= Self.preReadyAudioByteLimit {
                    preReadyAudioBuffer.append(pcmData)
                    preReadyAudioBufferBytes += pcmData.count
                }
                return .buffer
            }
            guard let task = webSocketTask, task.state == .running else {
                return .drop
            }
            return .send(task)
        }

        switch action {
        case .drop, .buffer:
            return
        case .send(let task):
            sendJSONOnTask(payload, task: task)
        }
    }

    func commitInputBuffer() {
        let task: URLSessionWebSocketTask? = withStateLock {
            guard !isStopping, let task = webSocketTask, task.state == .running else { return nil }
            return task
        }
        guard let task else { return }
        let payload: [String: Any] = ["type": "input_audio_buffer.commit"]
        sendJSONOnTask(payload, task: task)
    }

    func waitForPendingSends() async {
        await withCheckedContinuation { continuation in
            pendingSendGroup.notify(queue: .global()) {
                continuation.resume()
            }
        }
    }

    func awaitSessionReady(timeout: TimeInterval) async -> Bool {
        if withStateLock({ sessionReady }) { return true }

        let token = WaitToken()
        let alreadyReady: Bool = withStateLock {
            if sessionReady { return true }
            readyWaitTokens.append(token)
            return false
        }
        if alreadyReady { return true }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            token.signal(false)
        }
        return await token.wait()
    }

    private func flushPreReadyAudio() {
        let (task, frames): (URLSessionWebSocketTask?, [Data]) = withStateLock {
            let pending = preReadyAudioBuffer
            preReadyAudioBuffer = []
            preReadyAudioBufferBytes = 0
            return (webSocketTask, pending)
        }
        guard let task, task.state == .running, !frames.isEmpty else { return }
        logger.info("Flushing \(frames.count) pre-ready OpenAI Realtime audio frames")
        for frame in frames {
            let payload: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": frame.base64EncodedString()
            ]
            sendJSONOnTask(payload, task: task)
        }
    }

    private func sendJSON(_ payload: [String: Any]) {
        let task: URLSessionWebSocketTask? = withStateLock {
            guard !isStopping else { return nil }
            return webSocketTask
        }
        guard let task else { return }
        sendJSONOnTask(payload, task: task)
    }

    private func sendJSONOnTask(_ payload: [String: Any], task: URLSessionWebSocketTask) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            logger.error("Failed to serialize OpenAI Realtime payload: \(error.localizedDescription)")
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            logger.error("Failed to encode OpenAI Realtime payload as UTF-8")
            return
        }
        pendingSendGroup.enter()
        task.send(.string(text)) { [weak self] error in
            self?.pendingSendGroup.leave()
            if let error {
                self?.deliverError(error)
            }
        }
    }

    private func deliverError(_ error: Error) {
        let stopping = withStateLock { isStopping }
        if stopping { return }
        currentOnError()?(error)
    }

    // MARK: Inbound

    private func receiveMessages() {
        guard let task = withStateLock({ webSocketTask }) else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.deliverError(error)
            case .success(let message):
                switch message {
                case .string(let text):
                    for outcome in OpenAIRealtimeEventParser.parse(text) {
                        self.dispatch(outcome)
                    }
                case .data:
                    break
                @unknown default:
                    break
                }
                self.receiveMessages()
            }
        }
    }

    private func dispatch(_ outcome: OpenAIRealtimeEventParser.ParsedOutcome) {
        switch outcome {
        case .event(let event):
            if case .sessionReady = event {
                let tokensToFire: [WaitToken] = withStateLock {
                    sessionReady = true
                    let tokens = readyWaitTokens
                    readyWaitTokens.removeAll()
                    return tokens
                }
                for token in tokensToFire {
                    token.signal(true)
                }
                flushPreReadyAudio()
            }
            currentOnEvent()?(event)
        case .error(let error):
            currentOnError()?(error)
        case .ignored:
            break
        }
    }

    @discardableResult
    private func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    private func currentOnEvent() -> ((Event) -> Void)? {
        withStateLock { onEvent }
    }

    private func currentOnError() -> ((Error) -> Void)? {
        withStateLock { onError }
    }
}

// MARK: - Event parser

/// Pure-function parser for OpenAI Realtime API JSON events. Module-private
/// so it doesn't collide with the macOS parser of the same name.
enum OpenAIRealtimeEventParser {
    enum ParsedOutcome {
        case event(OpenAIRealtimeWebSocketClient.Event)
        case error(Error)
        case ignored
    }

    static func parse(_ text: String) -> [ParsedOutcome] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return [.ignored]
        }

        switch type {
        case "transcription_session.created", "session.created":
            return [.event(.sessionCreated)]
        case "transcription_session.updated", "session.updated":
            return [.event(.sessionReady)]
        case "conversation.item.input_audio_transcription.delta":
            let itemId = (object["item_id"] as? String) ?? ""
            guard let delta = object["delta"] as? String, !delta.isEmpty else {
                return [.ignored]
            }
            return [.event(.delta(delta, itemId: itemId))]
        case "conversation.item.input_audio_transcription.completed":
            let itemId = (object["item_id"] as? String) ?? ""
            let transcript = (object["transcript"] as? String) ?? ""
            return [.event(.completed(transcript, itemId: itemId))]
        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String
                ?? (object["message"] as? String)
                ?? "Unknown OpenAI Realtime error"
            return [.error(OpenAIRealtimeError.sessionError(message))]
        default:
            return [.ignored]
        }
    }
}

// MARK: - WaitToken

/// One-shot async latch. The first `signal(_:)` resolves any pending
/// `wait()` and is idempotent thereafter. Mirrors the macOS implementation.
private final class WaitToken: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: Bool = false
    private var value: Bool = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal(_ value: Bool) {
        let cont: CheckedContinuation<Bool, Never>?
        let resolvedValue: Bool
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        self.value = value
        cont = continuation
        continuation = nil
        resolvedValue = value
        lock.unlock()
        cont?.resume(returning: resolvedValue)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if resolved {
                let resolvedValue = value
                lock.unlock()
                cont.resume(returning: resolvedValue)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}
// swiftlint:enable type_body_length
#endif
