#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// Stop and finalisation: claims the stop once, drains the transcriber under
/// the completion identity, commits History and hands the settled result to
/// delivery and polish.
@MainActor
extension TranscriptionRecordingService {
    /// Stops recording, applies the requested result destination, and returns the result.
    ///
    /// - Parameter destination: An explicit Stop destination intentionally redirects the run.
    ///   When omitted, a frozen Focus, explicit Start or keyboard destination remains authoritative.
    ///   With no such destination override, this exported legacy API keeps clipboard delivery and
    ///   the existing `autoPostProcess` policy, independently of the hardware destination preference.
    ///   Internal hardware and automatic stops use the frozen typed selection instead; they do not
    ///   reinterpret a resolved destination as a new explicit Stop request.
    @discardableResult
    public func stopRecording(
        destination: HardwareTriggerDestination? = nil,
        saveToHistory: Bool = true,
        primedActivityMessage: String = "Ready for the Action Button",
        keyboardDeliverySource: KeyboardPickupOffer.Source? = .app
    ) async -> TranscriptionResult {
        let selection: CaptureDestinationSelection?
        if let destination {
            selection = CaptureDestinationSelection(destination: destination, origin: .explicitStop)
        } else if effectiveDestination?.origin == .global {
            // The exported nil Stop keeps its clipboard/auto-polish contract. Internal
            // hardware stops pass the frozen typed selection instead of coming here.
            selection = CaptureDestinationSelection(destination: .clipboard, origin: .legacy)
        } else {
            selection = effectiveDestination
        }
        return await stopRecording(
            selection: selection,
            legacyCaller: destination == nil,
            saveToHistory: saveToHistory, primedActivityMessage: primedActivityMessage,
            keyboardDeliverySource: keyboardDeliverySource
        )
    }

    @discardableResult
    // The additional ownership guard follows the newly awaited durable History write.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func stopRecording(
        selection: CaptureDestinationSelection?,
        legacyCaller: Bool = false,
        saveToHistory: Bool = true,
        primedActivityMessage: String = "Ready for the Action Button",
        keyboardDeliverySource: KeyboardPickupOffer.Source? = .app
    ) async -> TranscriptionResult {
        // Disarmed first, before anything can suspend: a monitor that is still
        // polling while this stop runs would find the session gone and do
        // nothing, but cancelling here means it cannot even observe the
        // teardown. The auto-stop path re-enters this method, and the
        // reentrancy guard below is what makes that safe either way.
        disarmEndPointing()

        // A stop during startup cancels the pending run and waits for it to
        // unwind (issue #701): retiring `activeStartRunID` makes the suspended
        // start release everything it allocated instead of activating the
        // microphone after the user asked to stop.
        if lifecycle.state == .starting {
            lifecycle.retireStartRun()
            await lifecycle.awaitStartSettled()
            state = lifecycle.state
            return syntheticResult()
        }

        // Reentrancy guard: a rapid double-stop (e.g. double Action Button
        // press) must not produce a second history entry or clobber the
        // clipboard with stale text. Return an empty no-op result instead.
        guard lifecycle.beginStopping() else {
            return syntheticResult()
        }
        let selected = selection ?? effectiveDestination
            ?? CaptureDestinationSelection(destination: .clipboard, origin: .legacy)
        let destination: HardwareTriggerDestination? = selected.origin == .legacy ? nil : selected.destination
        lastCompletedDestination = selected
        state = lifecycle.state
        isRunning = false
        presentation.finish()
        diagnostics.retire()
        disarmWatchdogs()
        // Shared state stops claiming active capture as soon as the stop is
        // claimed, before the drain; the transcript is committed below.
        sharedState.clearRecordingState()
        let duration = elapsedSeconds
        let recordingEnded = Date()
        let recordingStarted = startTime
        let completionID = polishLedger.beginCompletion()

        // Keep the (often headless / backgrounded) process alive long enough for
        // the clipboard write — and any post-processing — to actually commit.
        // Short recordings were being suspended before the pasteboard flush
        // landed, so "Copied N words" was reported but nothing arrived.
        let assertion = beginBackgroundAssertion("Finalise transcription")

        let isBatch = transcriptionSession?.isBatch == true
        activityManager.updateActivity(
            status: isBatch ? .processing : .finalising,
            lastSnippet: isBatch ? "Transcribing recording…" : "Finalising transcript…",
            wordCount: wordCount,
            duration: duration
        )

        let endingSession = transcriptionSession
        let drained = await drainActiveTranscriber(duration: duration)
        startTime = nil
        guard polishLedger.isCurrent(completionID) else {
            // Explicit Cancel during the drain must not publish History or
            // output. The run still settles for anything waiting on it, and
            // its recording is not discarded: nothing delivered it.
            deliveringSession = nil
            currentTrigger = nil
            currentRunParameters = .none
            effectiveConfiguration = nil
            effectiveDestination = nil
            publishFinishedCapture(text: "", failure: nil)
            completeRun(with: "")
            partialText = ""
            wordCount = 0
            sharesLiveTranscript = true
            activityManager.endActivity()
            assertion.end()
            lifecycle.finishStopping()
            state = lifecycle.state
            return drained.replacingText("")
        }

        // Use the best available text and make the returned result, the history
        // entry, the clipboard, and the spoken dialog all agree on it.
        let text = bestAvailableText(from: drained)
        let result = drained.replacingText(text)
        // Onboarding progress is earned by evidence only: an unidentified
        // caller, or a run that produced no text, proves nothing.
        if let currentTrigger {
            dependencies.recordDictation(currentTrigger, text)
        }
        let captureDetails = IOSCaptureDetails(
            trigger: currentTrigger, isBatch: isBatch, recordingStarted: recordingStarted,
            recordingEnded: recordingEnded, transcriptionEnded: Date()
        )
        currentTrigger = nil
        // The overrides belong to the run that just ended; the next capture
        // starts from the global settings again unless it brings its own.
        currentRunParameters = .none
        // Tagged with the run, so a waiter that started this capture gets this
        // capture's text — including when that text is empty. The identity is
        // kept for the polish that may follow.
        let completedRunID = currentRunID
        let completedRequestContext = health.requests.admission(for: completedRunID)
        let completedRequestFailure = health.requests.failure(for: completedRunID)
        completeRun(with: text)
        partialText = text
        wordCount = text.split(whereSeparator: \.isWhitespace).count

        // Specialized callers may opt out when their result is intentionally transient.
        let historyItem = saveToHistory
            ? await historyManager.recordTranscriptionAndWait(
                text: text,
                model: currentModel,
                duration: result.duration,
                errorMessage: endingSession?.recordingLossSummary.map { warning in
                    [warning, lastSessionError?.localizedDescription].compactMap { $0 }.joined(separator: " ")
                },
                requestContext: completedRequestContext, requestFailure: completedRequestFailure,
                captureDetails: captureDetails
            )
            : nil
        if let historyItem, let intended = offlineIntendedModel,
           let recording = deliveringSession?.safetyRecordingID {
            dependencies.tagOfflineCapture(historyItem, recording, intended)
        }
        // Cancellation can retire this completion while its admitted History write
        // finishes. Keep that durable receipt, but never deliver a retired run or
        // clear a replacement run's state. cancelRecording already owns teardown.
        guard polishLedger.isCurrent(completionID) else {
            assertion.end()
            return result.replacingText("")
        }

        // Offer the transcript to the keyboard *before* anything else acts on
        // the destination: straight into the field when the keyboard is on
        // screen right now, otherwise as a one-tap chip for late pickup
        // (issues #1002, #1003). The offer that actually got written is what
        // `.auto` routes on and what the receipt reports, so the decision can
        // never disagree with the delivery. The keyboard hand-off passes `nil`
        // because its result already travels the nonce-scoped record.
        let requestedDestination: HardwareTriggerDestination = destination ?? .clipboard
        let permitsExternalDelivery = requestedDestination != .historyOnly
        let keyboardOffer = publishKeyboardOffer(
            text: text, source: keyboardDeliverySource, destination: requestedDestination
        )
        // Publishing an offer is not delivering it. For an offer bound to the
        // document the keyboard is open in, wait briefly for the extension to
        // claim it — that claim is written after the proxy accepted the text,
        // so it is the only evidence that the words reached the field. Without
        // it the capture falls back to the clipboard below and the receipt
        // says the keyboard did not take it, rather than reporting a field
        // delivery for a transcript that is only in History.
        let keyboardOutcome = await KeyboardDeliveryPublisher.awaitOutcome(
            for: keyboardOffer, store: dependencies.keyboardDelivery
        )

        // Resolve the destination. When nil (legacy callers), preserve the
        // pre-destination behaviour: clipboard + post-process if user opted in.
        let autoPlan = AutoDestinationPolicy.plan(
            AutoDestinationPolicy.Inputs(
                transcriptIsEmpty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                keyboardInsertedIntoField: keyboardOutcome == .insertedInField,
                keyboardOfferAvailable: keyboardDeliverySource != nil
                    && dependencies.keyboardDelivery.isAvailable
            )
        )
        let resolvedDestination = requestedDestination == .auto
            ? Self.concreteDestination(for: autoPlan)
            : requestedDestination
        // Read before the side effects reset the flag: only a shared completion
        // leaves a transcript the result row's actions can retrieve.
        let publishesCompletedTranscript = permitsSharedCompletion(selected) && permitsExternalDelivery
        let clipboardOutcome = await applyDestinationSideEffects(
            text: text,
            destination: resolvedDestination,
            sharesCompletedTranscript: publishesCompletedTranscript
        )

        // The transcript has landed, so *this* capture's safety audio no longer
        // needs recovering (issue #992). Marking it here rather than at stop is
        // deliberate: a kill anywhere above this line leaves the claim
        // un-delivered and the recording offered back on the next launch. It
        // names the one capture that was delivered — an overlapping or earlier
        // capture of this process may still be pending, and calling it
        // delivered would withhold its audio from recovery.
        if let recording = deliveringSession?.safetyRecordingID {
            dependencies.markDelivered(recording)
        }
        if lastSessionError == nil {
            health.journal(text.isEmpty ? .cancelled : .delivered, failure: nil)
        }

        // The receipt is built from what every lane reported, never from what
        // was attempted (issues #945, #952, #1008).
        let receipt = CaptureReceiptBuilder.receipt(
            for: CaptureReceiptBuilder.Outcome(
                transcriptIsEmpty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                preferredLane: requestedDestination == .auto ? autoPlan.preferredLane : .clipboard,
                keyboard: keyboardOutcome,
                clipboardWriteSucceeded: clipboardOutcome.writeSucceeded,
                savedToHistory: historyItem != nil,
                mac: historyManager.macLaneOutcome(for: historyItem)
            )
        )
        lastCaptureReceipt = receipt

        // The "Continue on Mac" pointer (issue #1006). It carries the History
        // entry id, not the words — see `TranscriptHandoffActivity`.
        publishHandoff(
            entryID: historyItem?.id, createdAt: historyItem?.createdAt ?? Date(),
            wordCount: wordCount, allowed: permitsExternalDelivery
        )

        // Update shared state. Live writes are throttled, so commit the
        // complete transcript exactly once at stop.
        if publishesCompletedTranscript {
            sharedState.updateTranscript(text)
        }
        // Stamp the published transcript with this completion so the Live
        // Activity result row's Copy action can prove the text it retrieves is
        // the one that row was rendered from, however many sessions finish while
        // it is still on screen. Post-processing rewrites the text under the same
        // id, so a polished result stays copyable from the same row.
        let publishedCompletionID = publishesCompletedTranscript && !text.isEmpty
            ? completionID.uuidString
            : ""
        if !publishedCompletionID.isEmpty {
            sharedState.completedTranscriptID = publishedCompletionID
        }
        sharedState.clearRecordingState()
        sharesLiveTranscript = true

        // Delivery of this capture is done: History has the transcript and the
        // destination has been applied. Only now may a non-retained batch
        // capture's temporary recording go — before this point it is the only
        // copy of what the user said (issues #993, #992).
        discardDeliveredRecording()

        // The outcome stays what the completion itself can prove: the
        // clipboard write is not a delivery receipt. A non-nil History row
        // confirms durable local storage, and keyboard callers may not have inserted yet. The
        // capture receipt (issue #1008) travels alongside it as the snippet,
        // where it reports what each lane actually did without becoming a
        // stronger claim than the outcome earns.
        //
        // Publish this session's settled outcome under its own identity, before
        // anything else can start a new one. `lastSessionError` is cleared at
        // the start of every run, so it is this session's error or nothing.
        //
        // This overlaps the `CaptureRunCompletion` / `activeCaptureID` pair
        // above: the two were built independently, on branches that had not met,
        // for the same problem — letting a caller collect its own capture's
        // result instead of a global. They should collapse into one, keeping the
        // failure this one carries and the settlement `isSettling` gives. Kept
        // side by side here so the integration branch compiles and CI exercises
        // both; the convergence belongs on #1070.
        self.publishFinishedCapture(text: text, failure: lastSessionError)

        completeRecordingActivity(
            duration: duration,
            primedMessage: lastSessionError?.localizedDescription ?? captureStopNotice ?? primedActivityMessage,
            outcome: .unconfirmed(transcript: text),
            // Keyboard handoffs publish nothing retrievable, so they carry no
            // preview and the result row offers no actions it cannot honour.
            resultPreview: publishesCompletedTranscript ? TranscriptionResultRow.preview(for: text) : "",
            completionMessage: receipt.summary,
            identity: (copyToken: publishedCompletionID, surfaceOwnerID: completionID)
        )

        // Freeze the durable row and this capture's settled facts before any
        // notification await. Scheduling cannot change capture delivery or polish.
        dependencies.notifyTranscriptReady(TranscriptReadyNotificationInput(
            historyID: historyItem?.id,
            transcriptIsEmpty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            failed: lastSessionError != nil,
            isForeground: dependencies.applicationState() != .background,
            keyboardInserted: keyboardOutcome == .insertedInField,
            matchingResultActivity: dependencies.activity.hasActiveResultSurface(completionID)
        ))

        // Kick off background post-processing if the chosen destination + user
        // settings call for it. Polished text stays in History; the raw clipboard
        // write is final. Release the assertion when post-processing finishes.
        // A new stop supersedes whatever the previous one polished, so an
        // intent that waits can never be handed the run before last's text.
        let polishes = shouldPostProcess(
            destination: resolvedDestination,
            isLegacyCaller: legacyCaller && (selected.origin == .global || selected.origin == .legacy)
        ) && !text.isEmpty
        if polishes, let historyItem {
            historyManager.beginPostProcessing(for: historyItem.id)
        }
        // Published so a returning intent can wait for the polished text
        // instead of being handed the raw transcript (issue #1015), tagged with
        // the run ids intents hold so a waiter is only satisfied by its own.
        polishLedger.settlePolish(startingFor: completedRunID, polishes: polishes)
        if polishes {
            startPostProcessing(
                text: text,
                historyItemID: historyItem?.id,
                recordingWarning: historyItem?.errorMessage,
                completionID: completionID,
                runID: completedRunID,
                assertion: assertion
            )
        } else {
            assertion.end()
        }

        // Clear per-session live state so a duplicate stop or a later fallback
        // path can never resurface this session's text.
        partialText = ""
        wordCount = 0

        effectiveConfiguration = nil
        effectiveDestination = nil
        lifecycle.finishStopping()
        state = lifecycle.state
        return result
    }
}
#endif
