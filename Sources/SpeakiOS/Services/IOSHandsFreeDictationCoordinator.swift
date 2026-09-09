#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import SpeakCore
import UIKit

// The detector lifecycle, its capture ownership and its presentation belong to
// one type; splitting them across files hid ownership bugs before.
// swiftlint:disable file_length

/// Owns the iOS hands-free detector lifecycle. Silent audio is retained only
/// in the bounded pre-roll buffer and is neither recorded nor transcribed.
@MainActor
// swiftlint:disable:next type_body_length
final class IOSHandsFreeDictationCoordinator: ObservableObject {
    typealias StartCapture = ([AVAudioPCMBuffer]) async -> HandsFreeCaptureStartOutcome
    typealias StopCapture = (_ shouldRearm: @escaping @MainActor () -> Bool) async -> HandsFreeCaptureEndOutcome
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
    private var armGeneration = 0
    private let captureInterruptionObserver = CaptureDisruptionObserver()
    private var disruptionReason = iOSTranscriptionError.microphoneChanged
    @Published private(set) var captureStopNotice: String?
    private var routeChangeToken: UUID?
    private var ownsLiveActivity = false
    private let configurationObserver = CaptureDisruptionObserver()
    private enum StopReason {
        case captureDisruption
        case sceneInactive
    }
    private var stopReason: StopReason?
    private var stoppingForDisruption: Bool { stopReason != nil }
    private var sceneIsActive = true
    private var captureIsStarting = false
    // Injectable boundaries exercise route-to-owner behaviour without hardware.
    var inputIsUsable: () -> Bool = { !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty }
    /// Whether the owned capture has proven it is really recording — its
    /// backend started and its own input tap delivered (issue #983). An
    /// utterance must not announce active capture before that.
    var captureIsProven: () -> Bool = { true }
    var detectorIsRunning: (() -> Bool)?
    var startDetectorCapture: (() async throws -> Void)?
    var resumeDetectorCapture: (() throws -> Void)?

    init(
        audioSessionManager: AudioSessionManager,
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
        routeChangeToken = audioSessionManager.addRouteChangeObserver(owner: self) { [weak self] reason in
            guard let self else { return }
            let id = self.sessionID
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                await self.handleRouteChange(reason: reason)
            }
        }
    }

    var isArmed: Bool { machine.isArmed }

    /// Re-publishes the current state when the owned capture's presentation
    /// changes. The machine state is unchanged, so nothing is announced twice.
    func refreshCapturePresentation() {
        guard machine.state == .recording else { return }
        publishState()
    }

    func handleRouteChange(reason: AVAudioSession.RouteChangeReason) async {
        // Reasons describe inputs OR outputs. Even oldDeviceUnavailable is
        // harmless when the current input and our detector are still usable.
        guard machine.isArmed, audioEngine != nil || detectorIsRunning != nil else { return }
        let running = detectorIsRunning?() ?? (audioEngine?.isRunning == true)
        guard !inputIsUsable() || !running else { return }
        await stopForCaptureDisruption()
    }

    /// Record scene intent synchronously, before another actor task can arm or
    /// deliver detector activity. A return to active never resumes listening.
    @discardableResult
    func sceneActivityChanged(isActive: Bool) -> Task<Void, Never>? {
        sceneIsActive = isActive
        if !isActive, ownsLiveActivity {
            activityManager.endActivity()
            ownsLiveActivity = false
        }
        guard !isActive, beginControlledStop(reason: .sceneInactive) else { return nil }
        let id = sessionID
        return Task { [weak self] in
            guard let self, self.sessionID == id else { return }
            await self.continueControlledStop()
        }
    }

    func stopForCaptureDisruption(reason: iOSTranscriptionError = .microphoneChanged) async {
        disruptionReason = reason
        guard beginControlledStop(reason: .captureDisruption) else { return }
        await continueControlledStop()
    }

    private func beginControlledStop(reason: StopReason) -> Bool {
        guard machine.isArmed, !stoppingForDisruption else { return false }
        stopReason = reason
        captureInterruptionObserver.stop()
        configurationObserver.stop()
        audioEngine?.stop()
        if machine.state == .arming { armTask?.cancel() }
        return true
    }

    private func continueControlledStop() async {
        // Retain capture ownership through startup and finalisation. Neither a
        // second phase change nor a Stop may cancel the result being drained.
        if machine.state == .recording {
            if !captureIsStarting { await apply(machine.handle(.silenceElapsed)) }
        } else if machine.state != .finalising {
            await finishDisruption()
        }
    }

    private func finishDisruption() async {
        let reason = stopReason
        let generation = armGeneration
        if machine.state == .finalising { _ = machine.handle(.captureFinished) }
        if reason == .captureDisruption {
            // A controlled interruption finalised normally through the owner,
            // so it disarms with a neutral notice rather than a failure alert
            // (issue #936). A real fault still surfaces as a failure.
            if disruptionReason.isControlledInterruption {
                await apply(machine.handle(.userDisarmed))
                if machine.state == .off, armGeneration == generation {
                    captureStopNotice = disruptionReason.localizedDescription
                }
            } else {
                await apply(machine.handle(.sessionFailed(.audioUnavailable)))
                // Teardown can suspend; do not attach an old notice to a new arm.
                if machine.state == .off, armGeneration == generation {
                    failureMessage = disruptionReason.localizedDescription
                }
            }
        } else {
            await apply(machine.handle(.userDisarmed))
        }
    }

    func toggle() async {
        if machine.isArmed {
            await disarm()
        } else {
            arm()
        }
    }

    func disarm() async {
        if stoppingForDisruption { return }
        armTask?.cancel()
        finalisationTask?.cancel()
        armTask = nil
        sessionID = nil
        await apply(machine.handle(.userDisarmed))
    }

    func finishCurrentUtterance() async {
        guard !stoppingForDisruption else { return }
        await apply(machine.handle(.silenceElapsed))
    }

    private func arm() {
        guard sceneIsActive else { return }
        stopReason = nil
        captureStopNotice = nil
        let effects = machine.handle(.userArmed)
        publishState()
        guard effects.contains(.startDetector) else { return }
        armGeneration += 1
        let id = UUID()
        sessionID = id
        guard captureIsSupported() else {
            Task { [weak self] in
                guard let self, self.armAttemptIsCurrent(id) else { return }
                await self.fail(.unsupportedConfiguration)
            }
            return
        }
        ownsLiveActivity = liveActivitiesEnabled()
            && activityManager.startActivity(provider: "Apple on-device", initialStatus: .arming)
        captureInterruptionObserver.observeAudioInterruption { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                await self.stopForCaptureDisruption(reason: .interrupted)
            }
        }
        armTask?.cancel()
        armTask = Task { [weak self] in await self?.startDetector(sessionID: id) }
    }

    private func apply(_ effects: [HandsFreeDictationMachine.Effect]) async {
        let generation = armGeneration
        for effect in effects {
            guard armGeneration == generation else { return }
            switch effect {
            case .startDetector:
                break
            case .stopDetector:
                await stopDetector()
            case .startCapture:
                await startOwnedCapture()
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

    private func startOwnedCapture() async {
        let captureSessionID = sessionID
        captureIsStarting = true
        let outcome = await startCapture(preRoll.takeSnapshot())
        guard sessionID == captureSessionID else { return }
        captureIsStarting = false
        if case .rejected(let failure) = outcome {
            // A refused start must not cancel somebody else's recording.
            await apply(machine.handle(.captureStartRejected(failure)))
        } else if stoppingForDisruption {
            await apply(machine.handle(.silenceElapsed))
        }
    }

    private func startDetector(sessionID: UUID) async {
        guard armAttemptIsCurrent(sessionID) else { return }
        let generation = armGeneration
        guard #available(iOS 26.0, *) else {
            await fail(.detectorUnavailable)
            return
        }
        guard await prepareMicrophone(sessionID: sessionID) else { return }

        do {
            try await audioSessionManager.configureForRecording()
            guard armAttemptIsCurrent(sessionID) else {
                releaseRetiredArmConfiguration(generation: generation)
                return
            }
            if let startDetectorCapture {
                try await startDetectorCapture()
            } else {
                try await startDetectorSession(sessionID: sessionID)
            }
            guard armAttemptIsCurrent(sessionID) else { return }
            armTask = nil
            await apply(machine.handle(.detectorStarted))
        } catch is CancellationError {
            releaseRetiredArmConfiguration(generation: generation)
        } catch {
            guard armAttemptIsCurrent(sessionID) else {
                releaseRetiredArmConfiguration(generation: generation)
                return
            }
            await fail(HandsFreeDictationMachine.Failure(error))
        }
    }

    private func prepareMicrophone(sessionID: UUID) async -> Bool {
        var hasMicrophonePermission = audioSessionManager.hasMicrophonePermission()
        if !hasMicrophonePermission {
            hasMicrophonePermission = await audioSessionManager.requestMicrophonePermission()
        }
        guard armAttemptIsCurrent(sessionID) else { return false }
        guard hasMicrophonePermission else {
            await fail(.audioUnavailable)
            return false
        }

        return true
    }

    private func releaseRetiredArmConfiguration(generation: Int) {
        // Activation can finish after teardown while crossing an async boundary.
        // Release that late activation only if no newer arm has taken ownership.
        guard armGeneration == generation else { return }
        audioSessionManager.deactivate()
    }

    private func startFinalisation() {
        let id = sessionID
        finalisationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.stopCapture { [weak self] in
                self?.sessionID == id && self?.sceneIsActive == true && self?.stopReason == nil
            }
            guard !Task.isCancelled, self.sessionID == id, self.machine.state == .finalising else { return }
            switch outcome {
            case .completed:
                await self.finishSuccessfulCapture(sessionID: id)
            case .failed(let failure):
                self.finalisationTask = nil
                // The stop owner has already preserved its best available result.
                _ = self.machine.handle(.captureFinished)
                await self.apply(self.machine.handle(.sessionFailed(failure)))
            }
        }
    }

    private func finishSuccessfulCapture(sessionID id: UUID?) async {
        if self.stoppingForDisruption {
            self.finalisationTask = nil
            await self.finishDisruption()
            return
        }
        do {
            try await self.resumeDetectorAfterCapture(sessionID: id)
            guard self.sessionID == id, !Task.isCancelled else { return }
            self.finalisationTask = nil
            if self.stoppingForDisruption {
                await self.finishDisruption()
                return
            }
            self.tracker.reset()
            self.preRoll.reset()
            await self.apply(self.machine.handle(.captureFinished))
        } catch {
            guard self.sessionID == id, !Task.isCancelled else { return }
            self.finalisationTask = nil
            // The capture has already committed; failure to restart the
            // detector must never clear its saved/shared result.
            _ = self.machine.handle(.captureFinished)
            if self.stoppingForDisruption {
                await self.finishDisruption()
            } else {
                await self.apply(self.machine.handle(.sessionFailed(.audioUnavailable)))
            }
        }
    }

    @available(iOS 26.0, *)
    private func startDetectorSession(sessionID: UUID) async throws {
        let session = try await AppleSpeechDetectorSession(
            onActivity: { [weak self] update in
                Task { @MainActor [weak self] in
                    guard self?.sessionID == sessionID, self?.stoppingForDisruption == false else { return }
                    await self?.handleActivity(update)
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard self?.sessionID == sessionID, self?.machine.isArmed == true,
                          self?.stoppingForDisruption == false else { return }
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
            observeDetectorConfiguration(engine: engine, sessionID: sessionID)
        } catch {
            engine.stop()
            inputNode.removeTap(onBus: 0)
            await session.cancel()
            throw error
        }
    }

    private func observeDetectorConfiguration(engine: AVAudioEngine, sessionID: UUID) {
        configurationObserver.observe(.AVAudioEngineConfigurationChange, object: engine) { [weak engine] in
            engine?.isRunning == true
        } onDisruption: { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.sessionID == sessionID else { return }
                await self?.stopForCaptureDisruption()
            }
        }
    }

    func handleActivity(_ update: AppleSpeechActivityUpdate) async {
        guard !stoppingForDisruption, sceneIsActive,
              machine.state == .armed || machine.state == .recording else { return }
        let hold = HandsFreeDictationPolicy.silenceHoldSeconds(configured: silenceDuration())
        guard let event = tracker.observe(
            speechDetected: update.speechDetected,
            atSeconds: update.seconds,
            silenceHoldSeconds: hold
        ) else { return }
        await apply(machine.handle(event))
    }

    private func stopDetector() async {
        captureInterruptionObserver.stop()
        configurationObserver.stop()
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
        let retiringDetector = detectorSession
        detectorSession = nil
        captureIsStarting = false
        audioSessionManager.deactivate()
        if #available(iOS 26.0, *), let session = retiringDetector as? AppleSpeechDetectorSession {
            await session.cancel()
        }
    }

    private func resumeDetectorAfterCapture(sessionID id: UUID?) async throws {
        guard sessionID == id, !stoppingForDisruption, sceneIsActive else { return }
        try await audioSessionManager.configureForRecording()
        guard sessionID == id, !stoppingForDisruption, sceneIsActive, !Task.isCancelled else { return }
        if let resumeDetectorCapture {
            try resumeDetectorCapture()
            return
        }
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
        case .recording: activityStatus = captureIsProven() ? .recording : .arming
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
        case .recording:
            return captureIsProven() ? "Recording" : CapturePresentationGate.preparingMessage
        case .finalising: return "Finalising transcript"
        }
    }

    private func armAttemptIsCurrent(_ id: UUID) -> Bool {
        sessionID == id && !Task.isCancelled && machine.state == .arming && !stoppingForDisruption && sceneIsActive
    }
}
#endif
