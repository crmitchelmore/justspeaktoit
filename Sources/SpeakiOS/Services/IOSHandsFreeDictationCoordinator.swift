#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import SpeakCore
import UIKit

/// Owns the iOS hands-free detector lifecycle. Silent audio is retained only
/// in the bounded pre-roll buffer and is neither recorded nor transcribed.
@MainActor
// swiftlint:disable:next type_body_length
final class IOSHandsFreeDictationCoordinator: ObservableObject {
    typealias StartCapture = ([AVAudioPCMBuffer]) async -> HandsFreeCaptureStartOutcome
    typealias StopCapture = () async -> HandsFreeCaptureEndOutcome

    @Published private(set) var state: HandsFreeDictationMachine.State = .off
    @Published private(set) var failureMessage: String?

    private let audioSessionManager: AudioSessionManager
    private let activityManager = TranscriptionActivityManager.shared
    private let startCapture: StartCapture
    private let stopCapture: StopCapture
    private let cancelCapture: () -> Void
    private let silenceDuration: () -> TimeInterval
    private let captureIsSupported: () -> Bool
    private let liveActivitiesEnabled: () -> Bool
    private var machine = HandsFreeDictationMachine()
    private var tracker = HandsFreeVoiceActivityTracker()
    private let preRoll = HandsFreeAudioPreRollBuffer()
    private var audioEngine: AVAudioEngine?
    private var detectorSession: Any?
    private var armTask: Task<Void, Never>?
    private var finalisationTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var interruptionToken: UUID?
    private var routeChangeToken: UUID?
    private var ownsLiveActivity = false

    init(
        audioSessionManager: AudioSessionManager = AudioSessionManager(),
        startCapture: @escaping StartCapture,
        stopCapture: @escaping StopCapture,
        cancelCapture: @escaping () -> Void,
        silenceDuration: @escaping () -> TimeInterval,
        captureIsSupported: @escaping () -> Bool,
        liveActivitiesEnabled: @escaping () -> Bool
    ) {
        self.audioSessionManager = audioSessionManager
        self.startCapture = startCapture
        self.stopCapture = stopCapture
        self.cancelCapture = cancelCapture
        self.silenceDuration = silenceDuration
        self.captureIsSupported = captureIsSupported
        self.liveActivitiesEnabled = liveActivitiesEnabled
        interruptionToken = audioSessionManager.addInterruptionObserver(owner: self) { [weak self] began in
            guard began else { return }
            Task { @MainActor [weak self] in await self?.fail(.audioUnavailable) }
        }
        routeChangeToken = audioSessionManager.addRouteChangeObserver(owner: self) { [weak self] in
            Task { @MainActor [weak self] in await self?.fail(.audioUnavailable) }
        }
    }

    var isArmed: Bool { machine.isArmed }

    func toggle() async {
        if machine.isArmed {
            await disarm()
        } else {
            arm()
        }
    }

    func disarm() async {
        armTask?.cancel()
        finalisationTask?.cancel()
        armTask = nil
        sessionID = nil
        await apply(machine.handle(.userDisarmed))
    }

    func finishCurrentUtterance() async {
        await apply(machine.handle(.silenceElapsed))
    }

    private func arm() {
        let effects = machine.handle(.userArmed)
        publishState()
        guard effects.contains(.startDetector) else { return }
        guard captureIsSupported() else {
            Task { [weak self] in await self?.fail(.unsupportedConfiguration) }
            return
        }
        ownsLiveActivity = liveActivitiesEnabled()
            && activityManager.startActivity(provider: "Apple on-device", initialStatus: .arming)
        let id = UUID()
        sessionID = id
        armTask?.cancel()
        armTask = Task { [weak self] in await self?.startDetector(sessionID: id) }
    }

    private func apply(_ effects: [HandsFreeDictationMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .startDetector:
                break
            case .stopDetector:
                await stopDetector()
            case .startCapture:
                let outcome = await startCapture(preRoll.takeSnapshot())
                if case .rejected(let failure) = outcome {
                    await apply(machine.handle(.sessionFailed(failure)))
                }
            case .stopCapture:
                startFinalisation()
            case .cancelCapture:
                cancelCapture()
            case .reportFailure(let failure):
                failureMessage = failure.message
                if ownsLiveActivity {
                    activityManager.reportError(failure.message)
                }
            }
        }
        publishState()
    }

    private func startDetector(sessionID: UUID) async {
        guard #available(iOS 26.0, *) else {
            await fail(.detectorUnavailable)
            return
        }
        var hasMicrophonePermission = audioSessionManager.hasMicrophonePermission()
        if !hasMicrophonePermission {
            hasMicrophonePermission = await audioSessionManager.requestMicrophonePermission()
        }
        guard hasMicrophonePermission else {
            await fail(.audioUnavailable)
            return
        }
        guard armAttemptIsCurrent(sessionID) else { return }

        do {
            try await audioSessionManager.configureForRecording()
            guard armAttemptIsCurrent(sessionID) else {
                audioSessionManager.deactivate()
                return
            }
            try await startDetectorSession(sessionID: sessionID)
            guard armAttemptIsCurrent(sessionID) else {
                await stopDetector()
                return
            }
            armTask = nil
            await apply(machine.handle(.detectorStarted))
        } catch is CancellationError {
            audioSessionManager.deactivate()
        } catch {
            await fail(HandsFreeDictationMachine.Failure(error))
        }
    }

    private func startFinalisation() {
        finalisationTask?.cancel()
        finalisationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.stopCapture()
            guard !Task.isCancelled, self.machine.state == .finalising else { return }
            self.finalisationTask = nil
            switch outcome {
            case .completed:
                do {
                    try await self.resumeDetectorAfterCapture()
                    self.tracker.reset()
                    self.preRoll.reset()
                    await self.apply(self.machine.handle(.captureFinished))
                } catch {
                    await self.apply(self.machine.handle(.sessionFailed(.audioUnavailable)))
                }
            case .failed(let failure):
                await self.apply(self.machine.handle(.sessionFailed(failure)))
            }
        }
    }

    @available(iOS 26.0, *)
    private func startDetectorSession(sessionID: UUID) async throws {
        let session = try await AppleSpeechDetectorSession(
            onActivity: { [weak self] update in
                Task { @MainActor [weak self] in await self?.handleActivity(update) }
            },
            onFailure: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard self?.sessionID == sessionID, self?.machine.isArmed == true else { return }
                    await self?.fail(HandsFreeDictationMachine.Failure(error))
                }
            }
        )
        guard armAttemptIsCurrent(sessionID) else {
            await session.cancel()
            throw CancellationError()
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            await session.cancel()
            throw AppleLocalModelError.compatibleAudioFormatUnavailable
        }
        do {
            let converter = try AppleSpeechAudioConverter(
                sourceFormat: inputFormat,
                targetFormat: session.audioFormat
            )
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [preRoll] buffer, _ in
                preRoll.append(buffer)
                if let converted = converter.convert(buffer) {
                    session.send(converted)
                }
            }
            engine.prepare()
            try engine.start()
            audioEngine = engine
            detectorSession = session
        } catch {
            engine.stop()
            inputNode.removeTap(onBus: 0)
            await session.cancel()
            throw error
        }
    }

    private func handleActivity(_ update: AppleSpeechActivityUpdate) async {
        guard machine.isArmed else { return }
        let hold = HandsFreeDictationPolicy.silenceHoldSeconds(configured: silenceDuration())
        guard let event = tracker.observe(
            speechDetected: update.speechDetected,
            atSeconds: update.seconds,
            silenceHoldSeconds: hold
        ) else { return }
        await apply(machine.handle(event))
    }

    private func stopDetector() async {
        armTask?.cancel()
        armTask = nil
        finalisationTask?.cancel()
        finalisationTask = nil
        sessionID = nil
        tracker.reset()
        preRoll.reset()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        if #available(iOS 26.0, *), let session = detectorSession as? AppleSpeechDetectorSession {
            await session.cancel()
        }
        detectorSession = nil
        audioSessionManager.deactivate()
    }

    private func resumeDetectorAfterCapture() async throws {
        try await audioSessionManager.configureForRecording()
        guard let audioEngine else {
            throw AppleLocalModelError.speechDetectorFailed
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    private func fail(_ failure: HandsFreeDictationMachine.Failure) async {
        await apply(machine.handle(.sessionFailed(failure)))
    }

    private func publishState() {
        let previousState = state
        state = machine.state
        if state != previousState {
            UIAccessibility.post(
                notification: .announcement,
                argument: "Hands-free dictation \(handsFreeStatusText.lowercased())"
            )
        }
        if state != .off { failureMessage = nil }
        let activityStatus: TranscriptionActivityAttributes.TranscriptionStatus?
        switch state {
        case .off: activityStatus = nil
        case .arming: activityStatus = .arming
        case .armed: activityStatus = .armed
        case .recording: activityStatus = .recording
        case .finalising: activityStatus = .finalising
        }
        if let activityStatus, ownsLiveActivity {
            activityManager.updateActivity(
                status: activityStatus,
                lastSnippet: handsFreeStatusText,
                wordCount: 0,
                duration: 0
            )
        } else if state == .off, ownsLiveActivity {
            activityManager.endActivity()
            ownsLiveActivity = false
        }
    }

    private var handsFreeStatusText: String {
        switch machine.state {
        case .off: return "Hands-free off"
        case .arming: return "Preparing on-device detector"
        case .armed: return "Hands-free armed"
        case .recording: return "Recording"
        case .finalising: return "Finalising transcript"
        }
    }

    private func armAttemptIsCurrent(_ id: UUID) -> Bool {
        sessionID == id && !Task.isCancelled && machine.state == .arming
    }
}
#endif
