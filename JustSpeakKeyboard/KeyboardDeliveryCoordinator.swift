import Foundation
import SpeakCore

/// What the delivery side needs to know about the keyboard's current
/// appearance. The view model owns these facts; delivery reads one snapshot
/// per pass so a decision never mixes two appearances.
struct KeyboardDeliveryContext {
    let isBlocked: Bool
    let documentIdentifier: UUID?
    let isSecureField: Bool
    let captureInFlight: Bool
    let activeInputModeCount: Int
    let insertText: ((String) -> Void)?
    let handBack: (() -> Void)?
}

/// Delivery of app-owned transcripts into the open field (issues #1002, #1003,
/// #1005): advertises the open target, evaluates a pending offer, inserts and
/// claims it, and hands the keyboard back afterwards.
@MainActor
final class KeyboardDeliveryCoordinator {
    private let store: KeyboardDeliveryStore
    private var statusObservation: KeyboardHandoffSignalObservation?
    private var pickupTask: Task<Void, Never>?
    private var isDelivering = false

    /// Reads the view model's current appearance; `nil` once it has gone.
    var context: @MainActor () -> KeyboardDeliveryContext? = { nil }

    /// Called on every assignment, so the view model republishes it exactly
    /// as often as it used to set its own published value.
    var onOfferingChange: (@MainActor (KeyboardPickupPolicy.Offering) -> Void)?

    /// Called with a delivered transcript once it is in the field and before
    /// the keyboard hands itself back, so it can be watched for corrections.
    var onDidDeliver: (@MainActor (String) -> Void)?

    private(set) var preferences: KeyboardDeliveryPreferences = .default

    private(set) var offering: KeyboardPickupPolicy.Offering = .none {
        didSet { onOfferingChange?(offering) }
    }

    /// Whether this appearance is still on screen.
    ///
    /// A status wake-up is a queued main-actor task, and dropping the
    /// observation does not unschedule one that has already been dispatched.
    /// Without this guard such a task could run after `deactivate()` and
    /// re-advertise an open target for a keyboard that is no longer visible —
    /// which the app would then treat as grounds for a targeted insert into a
    /// document nobody is looking at.
    private var isActiveAppearance = false

    /// Cadence for refreshing the open-target advertisement (which lapses
    /// after 8 s) and as the safety net for noticing an offer. Since #990 the
    /// app also posts a Darwin `statusChanged` when it publishes one, so a new
    /// offer no longer waits for a tick; the target refresh still needs the
    /// loop, and the store throttles that rewrite to one write per 2 s.
    private static let pollInterval = Duration.milliseconds(500)

    init(store: KeyboardDeliveryStore) {
        self.store = store
    }

    func reloadPreferences() {
        preferences = store.preferences()
    }

    func beginAppearance() {
        isActiveAppearance = true
    }

    /// Starts the poll loop and the status observation for this appearance.
    func startObserving() {
        startLoop()
        observeStatusChanges()
    }

    func deactivate() {
        isActiveAppearance = false
        // Not just dropped: a wake-up already queued on the main actor still
        // runs otherwise, and it would find enough state left behind to
        // republish a target for a dismissed keyboard.
        statusObservation?.invalidate()
        statusObservation = nil
        pickupTask?.cancel()
        pickupTask = nil
        // Withdraw the open-target advertisement. Its short lifetime covers
        // the case where the extension is killed before this ever runs.
        store.clearTarget()
        offering = .none
    }

    /// Nothing may keep aiming at a field that is now collecting a secret:
    /// withdraw the advertisement and drop the chip.
    func withdrawForSecureField() {
        store.clearTarget()
        offering = .none
    }

    /// Explicit one-tap pickup of the chip (#1003).
    func insertPendingPickup() {
        guard case let .chip(chip) = offering else { return }
        deliver(chip.text, offerID: chip.offerID)
    }

    /// The user declining the chip. The claim is recorded so it does not come
    /// back on the next appearance; the transcript stays in History.
    func dismissPendingPickup() {
        guard case let .chip(chip) = offering else { return }
        store.claimOffer(chip.offerID)
        offering = .none
    }

    /// The app wakes the keyboard when it publishes an offer (issue #990), so
    /// a targeted insert lands as soon as the capture finishes instead of on
    /// the next tick. The notification carries nothing: the offer, its nonce
    /// and its document binding are still read and validated from the App
    /// Group by `evaluatePickup`.
    private func observeStatusChanges() {
        guard statusObservation == nil else { return }
        // Delivered on the main queue, and coalesced to one outstanding
        // wake-up by the observation, so this needs no main-actor task of its
        // own — one per notification would let any process posting the
        // payload-free Darwin name stack stale refreshes on this extension.
        statusObservation = KeyboardHandoffSignal.observeStatusChanges { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// Advertises the open field and watches for a transcript the app has left
    /// pending. Both halves are cheap reads of the App Group; the store
    /// throttles the target rewrite.
    private func startLoop() {
        guard pickupTask == nil else { return }
        pickupTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func refresh() {
        guard isActiveAppearance, let context = context() else {
            // A delayed callback from an appearance that has ended may neither
            // advertise a target nor evaluate an offer.
            offering = .none
            return
        }
        if context.isBlocked {
            // Without Full Access there is no shared container to advertise
            // into and nothing to offer; the blocked strip already says so.
            offering = .none
            return
        }
        guard !context.isSecureField else {
            // Not merely "do not advertise": actively withdraw, because the
            // advertisement outlives its last refresh by design and the app
            // would otherwise still see an open target for a password field.
            store.clearTarget()
            offering = .none
            return
        }
        // Preferences are app-owned and the user can change them while this
        // keyboard stays on screen. Re-reading them here is one small App Group
        // read per tick, and it stops hand-back or auto-pickup decisions
        // applying a choice the user has already superseded.
        preferences = store.preferences()
        if let documentIdentifier = context.documentIdentifier {
            store.publishTarget(documentIdentifier: documentIdentifier, isSecureField: false)
        }
        evaluatePickup(context)
    }

    /// The decision, the text, and the claimed identifier all come from **one**
    /// snapshot of the offer. Reading the store twice let the app replace the
    /// offer in between, so the keyboard could insert offer A's text while
    /// claiming — and so silently burning — offer B.
    private func evaluatePickup(_ context: KeyboardDeliveryContext) {
        let offer = store.pendingOffer()
        let offering = KeyboardPickupPolicy.offering(
            offer: offer,
            claim: store.claim(),
            currentDocumentIdentifier: context.documentIdentifier,
            isSecureField: context.isSecureField,
            handoffInFlight: context.captureInFlight,
            preferences: preferences
        )
        if case let .autoInsert(text) = offering, let offer {
            deliver(text, offerID: offer.offerID)
            return
        }
        self.offering = offering
    }

    /// Inserts once and records the claim afterwards, so a death between the
    /// two leaves the offer retryable rather than losing the transcript.
    private func deliver(_ text: String, offerID: UUID) {
        // The insertion makes the host call back into `updateDocumentContext`.
        // Claiming happens after the proxy accepts the text, so guard the
        // window in between rather than letting a re-entrant pass insert twice.
        guard let insertText = context()?.insertText, !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        insertText(text)
        store.claimOffer(offerID)
        offering = .none
        onDidDeliver?(text)
        handBackAfterInsertIfPermitted()
    }

    /// Hands the keyboard back after a successful insertion (#1005). Only when
    /// exactly two keyboards are enabled: `advanceToNextInputMode()` moves to
    /// the *next* one, and with three or more that is not the one the user was
    /// typing on.
    func handBackAfterInsertIfPermitted() {
        guard let context = context(),
              KeyboardHandBackPolicy.shouldAdvanceToNextInputMode(
                  preferences: preferences,
                  activeInputModeCount: context.activeInputModeCount
              ) else {
            return
        }
        context.handBack?()
    }
}
