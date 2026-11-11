#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
// UI Automation GUIDs are defined in this translation unit (selectany) so the
// link never depends on which interface identifiers an import library ships.
#include <initguid.h>
#include "WindowsTextOutputInternal.hpp"
#include "WindowsTextOutputParts.hpp"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <functional>
#include <mutex>
#include <thread>

// Text output adapter. Every path is addressed to the control captured at the
// recording hotkey and re-verifies that identity first. Native Unicode
// Edit/RichEdit controls receive EM_REPLACESEL directly. Everything else goes
// through UI Automation on a dedicated worker: the Value pattern replaces a
// field only when that equals an insertion (empty field, whole selection or an
// explicit replace request), because the Text pattern is read-only and cannot
// insert. Otherwise a guarded paste places the text on the clipboard, sends
// Ctrl+V while the captured control still owns focus, reads the field back and
// restores the previous clipboard content. Nothing here logs transcript or
// clipboard contents.

namespace jsti::textoutput {
namespace {

// ---- environment -----------------------------------------------------------

HWND realForeground() { return GetForegroundWindow(); }
void realSleep(DWORD milliseconds) { Sleep(milliseconds); }
HRESULT realFocusedElement(IUIAutomation *automation, HWND, IUIAutomationElement **element) {
    return automation->GetFocusedElement(element);
}
std::mutex environmentMutex;
Environment overriddenEnvironment;
bool environmentOverridden = false;

Environment currentEnvironment() {
    std::lock_guard<std::mutex> lock(environmentMutex);
    return environmentOverridden ? overriddenEnvironment : defaultEnvironment();
}

} // namespace

// ---- worker accounting -------------------------------------------------------

std::mutex workerMutex;
std::condition_variable workerChanged;
size_t liveWorkers = 0;

namespace {

bool reserveWorker() {
    std::lock_guard<std::mutex> lock(workerMutex);
    if (liveWorkers >= 4) return false;
    ++liveWorkers;
    return true;
}

} // namespace

Environment defaultEnvironment() {
    Environment environment;
    environment.foregroundWindow = &realForeground;
    environment.ownApplication = &ownApplication;
    environment.sameApplication = &sameApplication;
    environment.clipboard = &systemClipboard;
    environment.sendPaste = &realSendPaste;
    environment.preparePaste = &prepareRealPaste;
    environment.releasePasteKeys = &releaseRealPasteKeys;
    environment.focusRevision = &observedFocusRevision;
    environment.captureFocusEvent = &observedFocusEvent;
    environment.resolveFocusEvent = &resolveObservedFocusEvent;
    environment.sleep = &realSleep;
    environment.focusedElement = &realFocusedElement;
    return environment;
}

void setEnvironment(const Environment &environment) {
    std::lock_guard<std::mutex> lock(environmentMutex);
    overriddenEnvironment = environment;
    environmentOverridden = true;
}

void resetEnvironment() {
    std::lock_guard<std::mutex> lock(environmentMutex);
    environmentOverridden = false;
}

size_t liveWorkerCount() {
    std::lock_guard<std::mutex> lock(workerMutex);
    return liveWorkers;
}

bool waitForWorkersToExit(DWORD timeoutMs) {
    std::unique_lock<std::mutex> lock(workerMutex);
    return workerChanged.wait_for(lock, std::chrono::milliseconds(timeoutMs), [] { return liveWorkers == 0; });
}

} // namespace jsti::textoutput

using namespace jsti::textoutput;

// ---- legacy direct API ---------------------------------------------------------

int jsti_target_capture(JSTITextTarget *target, char *error, size_t capacity) {
    if (!target) return jsti::fail("No text target supplied.", error, capacity);
    *target = {};
    Identity identity;
    std::string reason;
    if (!captureIdentity(currentEnvironment(), identity, reason)) return jsti::fail(reason, error, capacity);
    target->window = reinterpret_cast<uintptr_t>(identity.window);
    target->focused_control = reinterpret_cast<uintptr_t>(identity.focus);
    target->process_id = identity.process;
    target->thread_id = identity.thread;
    return 0;
}

int jsti_target_insert_text(const JSTITextTarget *target, const char *text, char *error, size_t capacity) {
    std::wstring value;
    if (!target || !target->window || !target->focused_control || !jsti::wide(text, value)) {
        return jsti::fail("No valid captured text field. Copy the transcript instead.", error, capacity);
    }
    Identity identity;
    identity.window = reinterpret_cast<HWND>(target->window);
    identity.focus = reinterpret_cast<HWND>(target->focused_control);
    identity.process = target->process_id;
    identity.thread = target->thread_id;
    std::string reason;
    if (!verifyIdentity(currentEnvironment(), identity, reason)) return jsti::fail(reason, error, capacity);
    const NativeKind kind = classifyNative(identity.focus);
    if (kind != NativeKind::Editable) return jsti::fail(refusal(kind), error, capacity);
    // This legacy entrypoint stays native-only: no keystrokes, no clipboard.
    // The guarded paste policy lives in jsti_insertion_insert.
    bool verified = false;
    if (!nativeReplaceSelection(identity.focus, value, false, verified, reason)) return jsti::fail(reason, error, capacity);
    return 0;
}

int jsti_clipboard_write(const char *text, char *error, size_t capacity) {
    std::wstring value;
    if (!jsti::wide(text, value)) return jsti::fail("Clipboard text is not valid UTF-8.", error, capacity);
    OwnerWindow owner;
    if (!owner.handle) return jsti::fail(jsti::systemError("Creating clipboard owner", owner.error), error, capacity);
    DWORD sequence = 0;
    std::string reason;
    if (!placeText(*systemClipboard(), owner.handle, value, false, sequence, reason)) return jsti::fail(reason, error, capacity);
    return 0;
}

// ---- opaque insertion API --------------------------------------------------------

void jsti_insertion_prepare(void) { (void)observedFocusRevision(); }

static JSTIInsertionTarget *captureTarget(char *error, size_t capacity, bool readOnly, bool voiceEdit = false) {
    try {
        Environment environment = currentEnvironment();
        if (readOnly) environment.allowCurrentProcess = true;
        const uint64_t revision = environment.focusRevision ? environment.focusRevision() : 0;
        Identity identity;
        std::string reason;
        if (!captureIdentity(environment, identity, reason)) { jsti::fail(reason, error, capacity); return nullptr; }
        auto state = std::make_shared<State>();
        state->readOnlyTarget = readOnly;
        state->voiceEditTarget = voiceEdit;
        state->selectionRequested = readOnly || voiceEdit;
        state->insertBusy = readOnly || voiceEdit;
        state->selectionDeadline = GetTickCount64() + environment.insertTimeoutMs;
        state->environment = environment;
        state->identity = identity;
        state->focusRevision = revision;
        FocusEvent event;
        if (environment.captureFocusEvent && environment.captureFocusEvent(event) && event.revision == revision &&
            event.thread == identity.thread && GetAncestor(event.window, GA_ROOT) == identity.window) {
            state->focusEvent = event;
        }
        state->process.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, identity.process);
        if (!state->process.value) {
            jsti::fail("The original application process could not be retained.", error, capacity);
            return nullptr;
        }
        state->exited.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!state->exited.value) {
            jsti::fail(jsti::systemError("Creating insertion worker state"), error, capacity);
            return nullptr;
        }
        auto target = std::make_unique<JSTIInsertionTarget>();
        target->state = state;
        if (reserveWorker()) {
            try { target->worker = std::thread([state] { runInsertionWorker(state); }); }
            catch (...) { WorkerScope releaseReservedSlot; throw; }
        } else if (readOnly || voiceEdit) {
            jsti::fail("Too many app accessibility requests are still pending.", error, capacity);
            return nullptr;
        }
        if (error && capacity) error[0] = 0;
        return target.release();
    } catch (const std::exception &) {
        jsti::fail("Could not allocate the insertion target.", error, capacity);
        return nullptr;
    }
}

JSTIInsertionTarget *jsti_insertion_capture(char *error, size_t capacity) {
    return captureTarget(error, capacity, false);
}

JSTIInsertionTarget *jsti_selection_capture(char *error, size_t capacity) {
    return captureTarget(error, capacity, true);
}

JSTIInsertionTarget *jsti_voice_edit_capture(char *error, size_t capacity) {
    return captureTarget(error, capacity, false, true);
}

int jsti_selection_read(JSTIInsertionTarget *target, char *text, size_t textCapacity,
                         char *error, size_t capacity) {
    if (text && textCapacity) text[0] = 0;
    if (!target || !target->state || (!target->state->readOnlyTarget && !target->state->voiceEditTarget) ||
        !target->worker.joinable())
        return jsti::fail("A retained selected-text capture is required.", error, capacity);
    try {
        State &state = *target->state;
        std::unique_lock<std::mutex> lock(state.mutex);
        if (state.abandoned || (state.shutdown && !state.selectionFinished) || state.selectionStarted)
            return jsti::fail("This selected-text request is no longer current.", error, capacity);
        state.selectionStarted = true;
        if (!state.changed.wait_for(lock, std::chrono::milliseconds(state.environment.insertTimeoutMs), [&] {
                return state.selectionFinished || state.abandoned || state.shutdown;
            })) {
            state.abandoned = true; state.shutdown = true; state.changed.notify_all();
            return jsti::fail("Selected-text capture timed out.", error, capacity);
        }
        if (state.abandoned || !state.selectionFinished || state.selectionStatus != 0)
            return jsti::fail(state.selectionError.empty() ? "Selected-text capture was cancelled."
                : state.selectionError, error, capacity);
        std::string reason;
        const NativeKind kind = classifyNative(state.identity.focus);
        if (WaitForSingleObject(state.process.value, 0) != WAIT_TIMEOUT ||
            (state.environment.focusRevision && state.environment.focusRevision() != state.focusRevision) ||
            !verifyIdentity(state.environment, state.identity, reason) ||
            kind == NativeKind::Password || kind == NativeKind::Disabled) {
            state.selectionText.clear();
            return jsti::fail("The selected-text target changed before speech could start.", error, capacity);
        }
        const std::string encoded = jsti::utf8(state.selectionText);
        state.selectionText.clear();
        if (encoded.empty() || !text || textCapacity <= encoded.size())
            return jsti::fail("Selected text could not fit in its bounded UTF-8 buffer.", error, capacity);
        std::memcpy(text, encoded.c_str(), encoded.size() + 1);
        state.selectionDelivered = true;
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Selected-text capture could not retain its bounded native state.", error, capacity);
    }
}

void jsti_insertion_cancel(JSTIInsertionTarget *target) {
    if (!target || !target->state) return;
    const auto state = target->state;
    std::shared_ptr<State> redirected;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->abandoned = true;
        state->shutdown = true;
        redirected = state->redirectedOutput;
    }
    state->changed.notify_all();
    if (redirected) {
        {
            std::lock_guard<std::mutex> lock(redirected->mutex);
            redirected->abandoned = true;
            redirected->shutdown = true;
        }
        redirected->changed.notify_all();
    }
}

int jsti_insertion_executable_path(const JSTIInsertionTarget *target, char *path, size_t pathCapacity,
                                   size_t *requiredBytes, char *error, size_t errorCapacity) {
    if (requiredBytes) *requiredBytes = 0;
    if (path && pathCapacity) path[0] = 0;
    if (!target || !target->state || !target->state->process.value) {
        return jsti::fail("The original application process is unavailable.", error, errorCapacity);
    }
    try {
        std::wstring value(32768, L'\0');
        DWORD length = static_cast<DWORD>(value.size());
        if (!QueryFullProcessImageNameW(target->state->process.value, 0, value.data(), &length)) {
            return jsti::fail(jsti::systemError("Reading the original application path"), error, errorCapacity);
        }
        value.resize(length);
        const std::string encoded = jsti::utf8(value);
        if (encoded.empty()) return jsti::fail("The original application path is unavailable.", error, errorCapacity);
        if (requiredBytes) *requiredBytes = encoded.size() + 1;
        if (!path || pathCapacity <= encoded.size()) return 2;
        std::memcpy(path, encoded.c_str(), encoded.size() + 1);
        if (error && errorCapacity) error[0] = 0;
        return 0;
    } catch (...) { return jsti::fail("Could not read the original application path.", error, errorCapacity); }
}

int jsti_foreground_executable_path(char *path, size_t pathCapacity, char *error, size_t errorCapacity) {
    if (!path || !pathCapacity) return jsti::fail("No application path buffer was supplied.", error, errorCapacity);
    path[0] = 0;
    try {
        const Environment environment = currentEnvironment();
        const HWND window = environment.foregroundWindow();
        DWORD pid = 0;
        if (!window) { if (error && errorCapacity) error[0] = 0; return 0; }
        if (!GetWindowThreadProcessId(window, &pid)) {
            return jsti::fail(jsti::systemError("Reading the foreground application"), error, errorCapacity);
        }
        if (pid == GetCurrentProcessId() && !environment.allowCurrentProcess) {
            if (error && errorCapacity) error[0] = 0;
            return 0;
        }
        jsti::Handle process;
        process.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!process.value) return jsti::fail(jsti::systemError("Retaining the foreground application"), error, errorCapacity);
        std::wstring value(32768, L'\0');
        DWORD length = static_cast<DWORD>(value.size());
        if (!QueryFullProcessImageNameW(process.value, 0, value.data(), &length)) {
            return jsti::fail(jsti::systemError("Reading the foreground application path"), error, errorCapacity);
        }
        value.resize(length);
        const std::string encoded = jsti::utf8(value);
        if (encoded.empty() || pathCapacity <= encoded.size()) {
            return jsti::fail("The foreground application path does not fit its buffer.", error, errorCapacity);
        }
        std::memcpy(path, encoded.c_str(), encoded.size() + 1);
        if (error && errorCapacity) error[0] = 0;
        return 0;
    } catch (...) { return jsti::fail("Could not read the foreground application path.", error, errorCapacity); }
}

void jsti_insertion_destroy(JSTIInsertionTarget *target) {
    if (!target) return;
    std::unique_ptr<JSTIInsertionTarget> owned(target);
    const std::shared_ptr<State> state = owned->state;
    if (!state) return;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->shutdown = true;
        state->abandoned = true;
    }
    state->changed.notify_all();
    if (!owned->worker.joinable()) return;
    // Bounded: a worker still inside a provider call keeps its own reference
    // to the state and releases everything when that call returns.
    if (WaitForSingleObject(state->exited.value, state->environment.destroyWaitMs) == WAIT_OBJECT_0) {
        owned->worker.join();
    } else {
        owned->worker.detach();
    }
}
