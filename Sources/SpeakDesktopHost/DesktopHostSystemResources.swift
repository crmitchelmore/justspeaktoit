import Foundation
import SpeakCore
import SpeakDesktop

/// The microphone session a dictation claim describes.
private struct DictationSession {
    let id: UUID
    let model: String
    let live: DesktopLiveSession?
}

/// One resource the controller holds, as "System resources in use" lists it.
struct DesktopHostResourceClaim: Equatable, Sendable {
    enum Release: Equatable, Sendable {
        case cancelDictation, disarmHandsFree, closePressMicrophone(UUID), releaseCapturePreparation
        case closeConnectionWarmUp, stopSpeaking, cancelVoiceExport, stopPlayback, cancelComparison
    }

    /// Changes with the underlying session, so a new session gets a new hold and start time.
    let key: String
    let kind: SystemResourceKind
    let title: String
    let reason: String
    var detail: String?
    var releaseTitle: String?
    var release: Release?
}

/// Registers the controller's holds (issue #1473) from the state that owns
/// them, so a hold cannot outlive its resource: every property below
/// reconciles when it changes. Windows and Linux share this; the hotkey
/// listener is registered by each platform, which owns it.
///
/// Native callback contexts (capture, hotkey hooks) are retained by their
/// owners here; once `NativeCallbackContext<T>` (#1472) lands, a context's
/// retire point is the natural place to end a platform-owned hold too.
extension DesktopHostController {
    package static var systemResourceOwner: String { "DesktopHostController" }

    var systemResourceClaims: [DesktopHostResourceClaim] {
        var claims: [DesktopHostResourceClaim] = []
        if let dictation = activeDictationResource { claims.append(contentsOf: dictation) }
        if let press = shortcutPressMicrophone {
            claims.append(.init(
                key: "press:\(press.id)", kind: .microphone, title: "Hotkey warm-up",
                reason: "Opened when the hotkey went down, so dictation starts without a delay. "
                    + "Closes within seconds.",
                releaseTitle: "Close", release: .closePressMicrophone(press.id)
            ))
        }
        if let run = handsFreeRun {
            claims.append(.init(
                key: "handsFree:\(run.id)", kind: .microphone, title: "Hands-free listening",
                reason: "Armed: waiting for you to speak.", releaseTitle: "Disarm", release: .disarmHandsFree
            ))
        }
        if comparisonCapture != nil {
            claims.append(.init(
                key: "comparison:\(comparisonGeneration)", kind: .microphone, title: "Compare Models recording",
                reason: "Recording the comparison you started.",
                releaseTitle: "Cancel comparison", release: .cancelComparison
            ))
        }
        if let preparation = capturePreparation, preparation.value.isActive {
            claims.append(.init(
                key: "prepare:\(preparation.deviceID)", kind: .backgroundTask,
                title: "Microphone preparation",
                reason: "Readies the selected microphone while idle so dictation starts quickly. "
                    + "The microphone stays closed. Ends within ten minutes.",
                releaseTitle: "Release", release: .releaseCapturePreparation
            ))
        }
        if let warm = connectionWarmTask {
            claims.append(.init(
                key: "warm:\(warm.id)", kind: .providerConnection, title: "Cleanup connection warm-up",
                reason: "Connects to the cleanup provider ahead of your next dictation. No audio or text is sent.",
                releaseTitle: "Close", release: .closeConnectionWarmUp
            ))
        }
        claims.append(contentsOf: audioOutputClaims)
        return claims
    }

    /// Speech, an export that only writes a file, and History playback.
    private var audioOutputClaims: [DesktopHostResourceClaim] {
        var claims: [DesktopHostResourceClaim] = []
        switch Platform.readAloudActivity(readAloudState) {
        case .speaking:
            claims.append(.init(
                key: "speech", kind: .audioOutput, title: "Speech playback", reason: "Reading text aloud.",
                releaseTitle: "Stop speaking", release: .stopSpeaking
            ))
        case .exporting:
            claims.append(.init(
                key: "voiceExport", kind: .backgroundTask, title: "Voice export",
                reason: "Writing voice audio to the file you chose. Nothing is played.",
                releaseTitle: "Cancel export", release: .cancelVoiceExport
            ))
        case .idle: break
        }
        if let saved = savedAudioPlayback {
            claims.append(.init(
                key: "playback:\(saved.recordID)", kind: .audioOutput, title: "Recording playback",
                reason: "Playing a saved recording from History.",
                releaseTitle: "Stop playback", release: .stopPlayback
            ))
        }
        return claims
    }

    /// Lists History playback until the player reports it stopped. Every
    /// path that ends it (Stop, another row, recording, import, finishing)
    /// goes through the player, so the claim follows the player itself.
    func trackSavedAudioPlayback(recordID: UUID) {
        savedAudioPlayback?.watch.cancel()
        let watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, await self.endSavedAudioPlaybackIfStopped() else { continue }
                return
            }
        }
        savedAudioPlayback = (recordID, watch)
    }

    /// Returns true once the claim is gone.
    @discardableResult
    func endSavedAudioPlaybackIfStopped() -> Bool {
        guard let saved = savedAudioPlayback else { return true }
        guard closed || !playback.isPlayingSavedAudio else { return false }
        saved.watch.cancel()
        savedAudioPlayback = nil
        return true
    }

    /// The dictation's microphone and, when streaming, its provider socket.
    private var activeDictationResource: [DesktopHostResourceClaim]? {
        let session: DictationSession?
        if let active = recording, !active.handsFree {
            session = DictationSession(id: active.record.id, model: active.record.modelIdentifier, live: active.live)
        } else if let owned = ownedDictation {
            session = DictationSession(
                id: owned.id, model: owned.request.record.modelIdentifier, live: owned.request.live
            )
        } else if let startup = ownedCaptureStartup {
            session = DictationSession(id: startup.id, model: "", live: nil)
        } else if let active = recording {
            // A hands-free utterance: its microphone is the hands-free hold; list only the socket.
            return active.live.map { [Self.liveClaim($0, model: active.record.modelIdentifier)] }
        } else {
            session = nil
        }
        guard let session else { return nil }
        var claims = [DesktopHostResourceClaim(
            key: "dictation:\(session.id)", kind: .microphone, title: "Dictation",
            reason: "Recording the dictation you started.",
            releaseTitle: "Cancel recording", release: .cancelDictation
        )]
        if let live = session.live { claims.append(Self.liveClaim(live, model: session.model)) }
        return claims
    }

    private static func liveClaim(_ live: DesktopLiveSession, model: String) -> DesktopHostResourceClaim {
        let provider = DesktopLiveTranscription.route(forID: model)?.provider.displayName ?? "Provider"
        return .init(
            key: "live:\(live.id)", kind: .providerConnection, title: "\(provider) live connection",
            reason: "Streams the dictation in progress for live text. Closes when the dictation ends.",
            detail: model.isEmpty ? nil : ModelCatalog.friendlyName(for: model)
        )
    }

    /// Ends holds whose resource is gone and registers new ones. Synchronous
    /// and actor-isolated, so it is safe from the properties' observers.
    func reconcileSystemResources() {
        let claims = closed ? [] : systemResourceClaims
        let wanted = Set(claims.map(\.key))
        for key in systemResourceHolds.keys where !wanted.contains(key) {
            systemResourceHolds.removeValue(forKey: key)?.end()
        }
        for claim in claims {
            if let existing = systemResourceHolds[claim.key] {
                existing.update(detail: claim.detail)
                continue
            }
            let release: SystemResourceRegistry.Release? = claim.release.map { action in
                { @Sendable [weak self] in await self?.releaseSystemResource(action) }
            }
            systemResourceHolds[claim.key] = systemResourceRegistry.acquire(
                kind: claim.kind, title: claim.title, reason: claim.reason, owner: Self.systemResourceOwner,
                detail: claim.detail, releaseTitle: claim.releaseTitle, release: release
            )
        }
    }

    /// Moves the controller's holds to `registry`; tests pass a private one.
    func useSystemResourceRegistry(_ registry: SystemResourceRegistry) {
        systemResourceHolds.values.forEach { $0.end() }
        systemResourceHolds = [:]
        systemResourceRegistry = registry
        reconcileSystemResources()
    }

    func releaseSystemResource(_ action: DesktopHostResourceClaim.Release) async {
        switch action {
        case .cancelDictation: await cancelTranscription()
        case .disarmHandsFree: _ = await disarmHandsFree()
        case .closePressMicrophone(let id): endShortcutPressMicrophone(id: id)
        case .releaseCapturePreparation: releaseCapturePreparation()
        case .closeConnectionWarmUp: invalidateConnectionPreWarming(resetCapture: false)
        case .stopSpeaking, .cancelVoiceExport: stopReadAloud()
        case .stopPlayback: playbackStop()
        case .cancelComparison: await cancelComparison()
        }
        reconcileSystemResources()
    }
}
