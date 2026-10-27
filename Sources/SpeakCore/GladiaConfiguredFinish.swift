import Foundation

extension GladiaLiveClient {
    /// Effect-side revalidation protects a delay whose clock headroom was
    /// exhausted after construction. No transport/callback runs under lock.
    func armChecked(
        _ seconds: TimeInterval, _ active: GladiaLiveRun, effects: inout GladiaLiveEffects,
        ownsPhase: (@Sendable (GladiaLiveRun) -> Bool)?,
        action: @escaping @Sendable () -> Void
    ) {
        effects.append { [weak self, weak active] in
            guard let self, let active else { return }
            let maySchedule = self.perform { _ in
                self.isCurrent(active) && (ownsPhase?(active) ?? true)
            }
            guard maySchedule else { return }
            guard let deadline = GladiaConfiguredTiming.deadline(after: seconds) else {
                self.perform { effects in
                    guard self.isCurrent(active), ownsPhase?(active) ?? true else { return }
                    self.fail(GladiaTimingConfigurationError(), active, &effects)
                }
                return
            }
            guard self.perform({ _ in self.isCurrent(active) && (ownsPhase?(active) ?? true) }) else { return }
            if self.usesCheckedDefaultScheduler {
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: action)
            } else {
                self.schedule(seconds, action)
            }
        }
    }

    /// Admission accounts for the partial frame as one retained frame slot;
    /// completing a send releases only that send's frame/bytes, never its tail.
    func admitFramed(_ data: Data, _ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        guard var framer = active.framer else { return }
        guard data.count <= active.maximumAudioBytes - active.admittedAudioBytes else {
            fail(active.stage == .open ? stalledError : GladiaStreamingError.sessionNotReady, active, &effects)
            return
        }
        let hadTail = framer.bufferedByteCount > 0 ? 1 : 0
        let combined = framer.bufferedByteCount + data.count
        let newSlots = combined / framer.preferredBytes + (combined % framer.preferredBytes > 0 ? 1 : 0)
        guard newSlots <= Self.maximumQueuedChunks - (active.admittedAudioChunks - hadTail) else {
            fail(active.stage == .open ? stalledError : GladiaStreamingError.sessionNotReady, active, &effects)
            return
        }
        let frames = framer.append(data)
        active.framer = framer
        active.admittedAudioBytes += data.count
        active.admittedAudioChunks += newSlots - hadTail
        active.admittedAnyAudio = true
        active.outgoing.append(contentsOf: frames.map { .audio($0) })
        startNextSend(active, &effects)
    }

    func beginConfiguredFinish(_ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        guard var framer = active.framer else { return }
        guard framer.finalPaddingBytes <= active.maximumAudioBytes - active.admittedAudioBytes else {
            fail(stalledError, active, &effects)
            return
        }
        active.admittedAudioBytes += framer.finalPaddingBytes
        if let tail = framer.finish() { active.outgoing.append(.audio(tail)) }
        active.framer = framer
        enterFinishPhase(.draining, delay: GladiaConfiguredTiming.drain, active, &effects) { client, active, effects in
            let error = active.stage == .open ? client.stalledError : GladiaStreamingError.sessionNotReady
            client.fail(error, active, &effects)
        }
        advanceConfiguredDrain(active, &effects)
        startNextSend(active, &effects)
    }

    /// Called after every owned PCM send completion, including synchronous
    /// completions in the existing nonrecursive pump.
    func advanceConfiguredDrain(_ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        guard isCurrent(active), active.finishing, active.finishPhase == .draining,
              active.admittedAudioBytes == 0, !active.sending, let timing = mode.timing else { return }
        if timing.grace == 0 {
            queueConfiguredStop(active, &effects)
        } else {
            enterFinishPhase(.grace, delay: timing.grace, active, &effects) { client, active, effects in
                client.queueConfiguredStop(active, &effects)
                client.startNextSend(active, &effects)
            }
        }
    }

    private func queueConfiguredStop(_ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        enterFinishPhase(.control, delay: GladiaConfiguredTiming.control, active, &effects) { client, active, effects in
            client.fail(client.stalledError, active, &effects)
        }
        active.outgoing.append(.stopRecording)
    }

    func configuredStopCompleted(_ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects) {
        guard isCurrent(active), active.finishPhase == .control, let timing = mode.timing else { return }
        enterFinishPhase(.finalEvents, delay: timing.finalWindow, active, &effects) { client, active, effects in
            client.fail(GladiaStreamingError.missingCompletion, active, &effects)
        }
    }

    private func enterFinishPhase(
        _ phase: GladiaLiveRun.FinishPhase, delay: TimeInterval,
        _ active: GladiaLiveRun, _ effects: inout GladiaLiveEffects,
        action: @escaping @Sendable (GladiaLiveClient, GladiaLiveRun, inout GladiaLiveEffects) -> Void
    ) {
        active.finishPhase = phase
        active.finishPhaseGeneration &+= 1
        let generation = active.finishPhaseGeneration
        arm(delay, active, &effects, ownsPhase: {
            $0.finishPhase == phase && $0.finishPhaseGeneration == generation
        }, action: action)
    }
}
