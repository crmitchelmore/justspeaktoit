// C ABI: insertion, copy-only delivery and correction learning on a captured target.
#include "WindowsTextOutputParts.hpp"

using namespace jsti::textoutput;

int jsti_insertion_insert(JSTIInsertionTarget *target, const char *text, unsigned flags,
                          JSTIInsertionResult *result, char *error, size_t capacity) {
    JSTIInsertionResult local{};
    local.method = JSTI_INSERTION_METHOD_NONE;
    local.identity = JSTI_INSERTION_IDENTITY_WINDOW;
    local.clipboard = JSTI_INSERTION_CLIPBOARD_UNTOUCHED;
    if (result) *result = local;
    if (!target || !target->state) return jsti::fail("No captured text field. Copy the transcript instead.", error, capacity);
    if (target->state->readOnlyTarget)
        return jsti::fail("A read-only selection capture cannot insert text.", error, capacity);
    {
        std::lock_guard<std::mutex> lock(target->state->mutex);
        target->state->learningAcknowledged = false;
        target->state->learningStarted = false;
        target->state->learningInserted.clear();
    }
    std::wstring value;
    if (!jsti::wide(text, value)) return jsti::fail("The transcript is not valid UTF-8.", error, capacity);
    if (value.empty()) return jsti::fail("There is no transcript text to insert.", error, capacity);
    State &state = *target->state;
    const Environment &environment = state.environment;
    std::string reason;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.abandoned || state.shutdown) return jsti::fail("This insertion target was cancelled.", error, capacity);
        if (state.voiceEditTarget && !state.selectionDelivered)
            return jsti::fail("Read the anchored selection before requesting a voice edit.", error, capacity);
    }
    if (WaitForSingleObject(state.process.value, 0) != WAIT_TIMEOUT) {
        return jsti::fail("The original application process has exited.", error, capacity);
    }
    if (!deliveryOwnerAvailable(state, reason)) return jsti::fail(reason, error, capacity);
    const unsigned policyMask = JSTI_INSERTION_ORIGINAL_APP | JSTI_INSERTION_CURRENT_APP |
        JSTI_INSERTION_ONLY_ORIGINAL_FRONT;
    const unsigned policy = flags & policyMask;
    if (state.voiceEditTarget && (policy || (flags & JSTI_INSERTION_REPLACE_FIELD)))
        return jsti::fail("Voice editing can replace only its original anchored selection.", error, capacity);
    if (policy && (policy & (policy - 1)))
        return jsti::fail("The app-switch delivery policy is invalid.", error, capacity);
    auto recoveryCopy = [&] {
        const int status = jsti_insertion_copy_text(target, text, &local, error, capacity);
        if (status == 0) local.method = JSTI_INSERTION_METHOD_CLIPBOARD;
        if (result) *result = local;
        return status;
    };
    const HWND foreground = environment.foregroundWindow();
    DWORD foregroundProcess = 0;
    if (foreground) GetWindowThreadProcessId(foreground, &foregroundProcess);
    const bool originalWindowFront = foreground == state.identity.window;
    const bool originalAppFront = foreground && environment.sameApplication(foreground, state.identity.window);
    const bool backgroundNative = policy && !originalWindowFront;
    const bool addressCapturedNativeField = policy != 0;
    auto focusStillCaptured = [&] {
        return !(flags & redirectedFocusFence) || (state.focusRevision && environment.focusRevision &&
            environment.focusRevision() == state.focusRevision);
    };
    if (!focusStillCaptured()) return jsti::fail(changedMessage, error, capacity);
    if (!verifyIdentity(environment, state.identity, reason, addressCapturedNativeField))
        return jsti::fail(reason, error, capacity);
    if (!integrityAllows(state.identity.process, reason)) return jsti::fail(reason, error, capacity);
    const NativeKind kind = environment.nativeDirectPath && !state.voiceEditTarget
        ? classifyNative(state.identity.focus) : NativeKind::NotNative;
    if (kind == NativeKind::Password || kind == NativeKind::ReadOnly || kind == NativeKind::Disabled) {
        return jsti::fail(refusal(kind), error, capacity);
    }
    if (policy && !originalWindowFront) {
        if (!foreground || !foregroundProcess ||
            (policy == JSTI_INSERTION_ONLY_ORIGINAL_FRONT && !originalAppFront))
            return recoveryCopy();
        const bool movedToOtherApp = !environment.ownApplication(foreground) &&
            !environment.sameApplication(foreground, state.identity.window);
        if (policy == JSTI_INSERTION_CURRENT_APP && movedToOtherApp) {
            std::unique_ptr<JSTIInsertionTarget, decltype(&jsti_insertion_destroy)> redirected(
                jsti_insertion_capture(error, capacity), jsti_insertion_destroy);
            if (!redirected) return recoveryCopy();
            // Capture must still describe the real app observed above. The child
            // retains its process and the existing per-field focus fences.
            if (redirected->state->identity.window != foreground ||
                redirected->state->identity.process != foregroundProcess) return recoveryCopy();
            {
                std::lock_guard<std::mutex> lock(redirected->state->mutex);
                redirected->state->deliveryOwner = target->state;
                redirected->state->requiresDeliveryOwner = true;
            }
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                if (state.abandoned || state.shutdown)
                    return jsti::fail("This insertion target was cancelled.", error, capacity);
                if (state.insertBusy)
                    return jsti::fail("An insertion is already in progress.", error, capacity);
                state.insertBusy = true;
                state.redirectedOutput = redirected->state;
            }
            struct RedirectGuard {
                State &state;
                ~RedirectGuard() {
                    std::lock_guard<std::mutex> lock(state.mutex);
                    state.redirectedOutput.reset();
                    state.insertBusy = false;
                }
            } redirectOwner{state};
            if (environment.beforeRedirectedInsert) environment.beforeRedirectedInsert(environment.hookContext);
            const int status = jsti_insertion_insert(redirected.get(), text, (flags & ~policyMask) | redirectedFocusFence,
                                                    &local, error, capacity);
            if (result) *result = local;
            // Never replay ambiguous or failed dispatch into a different route.
            return status;
        }
        // Native Unicode edit messages can address the captured field without
        // activating it. UIA/paste cannot safely address arbitrary background apps.
        if (kind != NativeKind::Editable) return recoveryCopy();
    }
    if (kind == NativeKind::Editable) {
        // Never waits on the UI Automation worker: native controls are
        // addressed directly on the caller's thread.
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            if (state.insertBusy) return jsti::fail("An insertion is already in progress.", error, capacity);
            state.insertBusy = true;
            state.mutationStarted = false;
        }
        struct BusyGuard {
            State &state;
            ~BusyGuard() { std::lock_guard<std::mutex> lock(state.mutex); state.insertBusy = false; }
        } busy{state};
        bool verified = false;
        DWORD learningCaret = static_cast<DWORD>(-1);
        auto mayMutate = [&] {
            if (!deliveryOwnerAvailable(state, reason)) return false;
            if (!focusStillCaptured()) { reason = changedMessage; return false; }
            if (policy == JSTI_INSERTION_ONLY_ORIGINAL_FRONT &&
                !environment.sameApplication(environment.foregroundWindow(), state.identity.window)) {
                reason = movedMessage; return false;
            }
            if (policy == JSTI_INSERTION_CURRENT_APP && backgroundNative &&
                environment.foregroundWindow() != foreground) { reason = movedMessage; return false; }
            if (WaitForSingleObject(state.process.value, 0) != WAIT_TIMEOUT) {
                reason = "The original application process has exited."; return false;
            }
            if (!verifyIdentity(environment, state.identity, reason, addressCapturedNativeField)) return false;
            if (classifyNative(state.identity.focus) != NativeKind::Editable) { reason = unsupportedMessage; return false; }
            std::lock_guard<std::mutex> lock(state.mutex);
            if (state.abandoned || state.shutdown) { reason = "This insertion target was cancelled."; return false; }
            state.mutationStarted = true;
            return true;
        };
        if (!nativeReplaceSelection(state.identity.focus, value, (flags & JSTI_INSERTION_REPLACE_FIELD) != 0,
                                    verified, reason, mayMutate, &learningCaret)) {
            jsti::fail(reason, error, capacity);
            std::lock_guard<std::mutex> lock(state.mutex);
            if (state.mutationStarted) {
                local.method = JSTI_INSERTION_METHOD_NATIVE_EDIT;
                if (result) *result = local;
                return 1;
            }
            return -1;
        }
        local.method = JSTI_INSERTION_METHOD_NATIVE_EDIT;
        local.verified = verified ? 1 : 0;
        std::string readbackReason;
        const bool learningDestinationFront = verifyIdentity(environment, state.identity, readbackReason);
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.learningAcknowledged = learningDestinationFront && verified && learningCaret != static_cast<DWORD>(-1);
            state.learningInserted = state.learningAcknowledged ? value : std::wstring();
            state.learningCaret = learningCaret;
            state.learningWholeField = false;
            state.learningStarted = false;
        }
        if (result) *result = local;
        if (error && capacity) error[0] = 0;
        return 0;
    }
    if (!target->worker.joinable()) return jsti::fail("Text insertion workers are busy. Copy the transcript instead.", error, capacity);
    try {
        std::unique_lock<std::mutex> lock(state.mutex);
        if (state.abandoned || state.shutdown || state.insertBusy) {
            return jsti::fail("An insertion is already in progress for this field.", error, capacity);
        }
        state.text = value;
        state.flags = flags;
        state.insertRequested = true;
        state.insertBusy = true;
        state.insertFinished = false;
        state.mutationStarted = false;
        state.result = local;
        state.changed.notify_all();
        if (!state.changed.wait_for(lock, std::chrono::milliseconds(environment.insertTimeoutMs),
                                    [&] { return state.insertFinished; })) {
            // The worker finishes or abandons the job on its own and still
            // restores the clipboard; it must not paste after this report.
            state.abandoned = true;
            if (result) *result = state.result;
            jsti::fail(timeoutMessage, error, capacity);
            return state.mutationStarted ? 1 : -1;
        }
        if (result) *result = state.result;
        if (state.status != 0) { jsti::fail(state.error, error, capacity); return state.status; }
    } catch (const std::exception &) {
        return jsti::fail("Could not queue the insertion request.", error, capacity);
    }
    if (error && capacity) error[0] = 0;
    return 0;
}

int jsti_insertion_copy_text(JSTIInsertionTarget *target, const char *text, JSTIInsertionResult *result,
                              char *error, size_t capacity) {
    if (result) *result = {};
    if (!target || !target->state) return jsti::fail("No captured output request.", error, capacity);
    if (target->state->readOnlyTarget)
        return jsti::fail("A read-only selection capture cannot replace the clipboard.", error, capacity);
    try {
        const auto state = target->state;
        std::wstring value;
        if (!jsti::wide(text, value)) return jsti::fail("Clipboard text is not valid UTF-8.", error, capacity);
        OwnerWindow owner;
        if (!owner.handle) return jsti::fail(jsti::systemError("Creating clipboard owner", owner.error), error, capacity);
        std::string reason;
        DWORD sequence = 0;
        int clipboard = JSTI_INSERTION_CLIPBOARD_UNTOUCHED;
        const bool copied = placeText(*state->environment.clipboard(), owner.handle, value, false, sequence, reason,
                                     nullptr, &clipboard, [&] {
            std::lock_guard<std::mutex> lock(state->mutex);
            return !state->abandoned && !state->shutdown;
        });
        if (result) result->clipboard = copied ? JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT : clipboard;
        if (!copied) return jsti::fail(reason, error, capacity);
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (...) { return jsti::fail("Could not copy the transcript.", error, capacity); }
}

int jsti_insertion_learning(JSTIInsertionTarget *target, const char *original,
                             char *edited, size_t editedCapacity, char *error, size_t capacity) {
    try {
    if (edited && editedCapacity) edited[0] = 0;
    if (!target || !target->state || !target->worker.joinable())
        return jsti::fail("Correction learning requires a retained UI Automation worker.", error, capacity);
    const bool capture = original != nullptr;
    std::wstring value;
    if (capture && (!jsti::wide(original, value) || value.empty() || value.size() > 8192))
        return jsti::fail("Correction learning requires a bounded confirmed insertion.", error, capacity);
    State &state = *target->state;
    std::unique_lock<std::mutex> lock(state.mutex);
    if (state.abandoned || state.shutdown || state.insertBusy || !state.learningAcknowledged ||
        (capture && (state.learningStarted || value != state.learningInserted)) ||
        (!capture && !state.learningStarted))
        return jsti::fail("This correction observation is no longer current.", error, capacity);
    state.learningStarted = true;
    state.learningCapture = capture;
    state.learningRequested = true;
    state.learningFinished = false;
    state.insertBusy = true;
    state.changed.notify_all();
    if (!state.changed.wait_for(lock, std::chrono::milliseconds(state.environment.insertTimeoutMs), [&] {
            return state.learningFinished || state.abandoned || state.shutdown;
        })) {
        state.abandoned = true; state.shutdown = true; state.changed.notify_all();
        return jsti::fail("Correction observation timed out; no edit was learned.", error, capacity);
    }
    if (state.abandoned || state.shutdown || state.learningStatus != 0)
        return jsti::fail(state.learningError.empty() ? "Correction observation cancelled."
            : state.learningError, error, capacity);
    if (!capture) {
        const std::string encoded = jsti::utf8(state.learningText);
        if (!edited || editedCapacity <= encoded.size())
            return jsti::fail("Correction observation buffer is too small.", error, capacity);
        std::memcpy(edited, encoded.c_str(), encoded.size() + 1);
        state.learningText.clear(); state.learningInserted.clear(); state.learningAcknowledged = false;
    }
    if (error && capacity) error[0] = 0;
    return 0;
    } catch (const std::exception &) {
        return jsti::fail("Correction observation could not retain its bounded native state.", error, capacity);
    }
}
