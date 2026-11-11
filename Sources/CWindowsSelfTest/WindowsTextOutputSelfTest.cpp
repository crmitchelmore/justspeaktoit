#include "WindowsTextOutputSelfTestSupport.hpp"

// Deterministic checks for the insertion adapter. Synthetic hidden Edit and
// RichEdit controls live on a helper UI thread inside this process; the
// adapter's environment seams substitute that window for the foreground
// window, an in-memory clipboard for the system clipboard and a stub that
// emulates an application's paste handler for SendInput. Nothing here sends
// real input, reads or writes the user's clipboard or touches another app.

namespace jsti::textoutput::selftest {

std::string checkVoiceEditAnchors(Fixture &state) {
    auto &host = state.host;
    Environment environment = testEnvironment(true);
    setEnvironment(environment);
    state.foreground = host.window;
    state.resolveOverride = nullptr;
    state.failFocusResolution = false;
    if (!host.focus(host.richEdit)) return "The voice-edit fixture could not focus its RichEdit.";
    Target target;
    char error[512]{}, selected[128]{};
    auto capture = [&](bool read = true) {
        target.destroy();
        target.value = jsti_voice_edit_capture(error, sizeof(error));
        return target.value && (!read ||
            jsti_selection_read(target.value, selected, sizeof(selected), error, sizeof(error)) == 0);
    };
    setText(host.richEdit, L"prefix original suffix");
    select(host.richEdit, 7, 15);
    if (!capture() || std::strcmp(selected, "original") != 0)
        return describe("voice edit capture", "did not retain just the selected text", error);
    const Attempt replaced = insert(target, "changed");
    if (replaced.status != 0 || !replaced.result.verified ||
        replaced.result.method == JSTI_INSERTION_METHOD_NATIVE_EDIT ||
        textOf(host.richEdit) != L"prefix changed suffix")
        return describe("voice edit anchored replacement", "did not replace only the original range", replaced.error);

    auto original = [&] {
        setText(host.richEdit, L"same same");
        select(host.richEdit, 0, 4);
        return capture();
    };
    auto refusedWithoutEffects = [&](unsigned flags = 0) {
        const std::wstring before = textOf(host.richEdit);
        const DWORD sequence = state.clipboard.sequence();
        const int pastes = state.pasteCalls.load();
        const Attempt attempt = insert(target, "forbidden", flags);
        return attempt.status == -1 && textOf(host.richEdit) == before &&
            sequence == state.clipboard.sequence() && pastes == state.pasteCalls.load();
    };
    if (!original()) return describe("voice edit moved range", "capture failed", error);
    select(host.richEdit, 5, 9);
    if (!refusedWithoutEffects())
        return describe("voice edit moved range", "identical text at a different range retained authority");
    if (!original()) return describe("voice edit document", "capture failed", error);
    setText(host.richEdit, L"same newer");
    select(host.richEdit, 0, 4);
    if (!refusedWithoutEffects())
        return describe("voice edit document", "changed surrounding text retained authority");
    if (!original()) return describe("voice edit focus", "capture failed", error);
    ++state.focusRevision;
    if (!refusedWithoutEffects())
        return describe("voice edit focus", "a focus transition retained authority");
    environment.preparePaste = +[](std::string &) {
        select(fixture->host.richEdit, 5, 9);
        return true;
    };
    setEnvironment(environment);
    // A captured target retains its environment, so recapture with the dispatch hook.
    if (!original()) return describe("voice edit dispatch anchor", "hooked capture failed", error);
    const int dispatches = state.pasteCalls.load();
    const Attempt lateRangeChange = insert(target, "must not reach either range");
    environment = testEnvironment(true);
    setEnvironment(environment);
    if (lateRangeChange.status != -1 || state.pasteCalls.load() != dispatches || textOf(host.richEdit) != L"same same")
        return describe("voice edit dispatch anchor", "a changed range escaped the final mutation check");
    if (!original()) return describe("voice edit replace all", "capture failed", error);
    if (!refusedWithoutEffects(JSTI_INSERTION_REPLACE_FIELD))
        return describe("voice edit replace all", "whole-field replacement bypassed the range anchor");
    for (const unsigned flag : {JSTI_INSERTION_ORIGINAL_APP, JSTI_INSERTION_CURRENT_APP,
                                JSTI_INSERTION_ONLY_ORIGINAL_FRONT}) {
        if (!original()) return describe("voice edit app switch", "capture failed", error);
        if (!refusedWithoutEffects(flag))
            return describe("voice edit app switch", "destination policy bypassed the anchor");
    }
    if (!original()) return describe("voice edit cancellation", "capture failed", error);
    jsti_insertion_cancel(target.value);
    if (!refusedWithoutEffects())
        return describe("voice edit cancellation", "a cancelled target retained write authority");
    if (!original()) return describe("voice edit read only", "capture failed", error);
    SendMessageW(host.richEdit, EM_SETREADONLY, TRUE, 0);
    const bool readOnlyRefused = refusedWithoutEffects();
    SendMessageW(host.richEdit, EM_SETREADONLY, FALSE, 0);
    if (!readOnlyRefused) return describe("voice edit read only", "a read-only field accepted a mutation");
    SendMessageW(host.richEdit, EM_SETREADONLY, TRUE, 0);
    const bool readOnlyCaptured = capture();
    SendMessageW(host.richEdit, EM_SETREADONLY, FALSE, 0);
    if (readOnlyCaptured) return describe("voice edit read only", "a read-only field admitted instruction capture");
    if (!original()) return describe("voice edit password", "capture failed", error);
    const LONG_PTR style = GetWindowLongPtrW(host.richEdit, GWL_STYLE);
    SetWindowLongPtrW(host.richEdit, GWL_STYLE, style | ES_PASSWORD);
    const bool passwordRefused = refusedWithoutEffects();
    SetWindowLongPtrW(host.richEdit, GWL_STYLE, style);
    if (!passwordRefused) return describe("voice edit password", "a password field accepted a mutation");
    setText(host.richEdit, L"same same");
    select(host.richEdit, 0, 4);
    if (!capture(false) || !refusedWithoutEffects())
        return describe("voice edit unacknowledged capture", "write authority preceded the bounded selection read");
    target.destroy();
    if (!state.release.value) state.release.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!state.release.value) return "Could not create the voice-edit cancellation gate.";
    ResetEvent(state.release.value);
    state.hookCalls = 0;
    state.blockOnCall = -1;
    struct ReleaseVoiceEditGate {
        Fixture &state;
        ~ReleaseVoiceEditGate() { SetEvent(state.release.value); }
    } release{state};
    environment.beforeAutomation = &blockingHook;
    environment.destroyWaitMs = 0;
    setEnvironment(environment);
    if (!capture(false) || !waitForHook(1))
        return describe("voice edit blocked capture", "the provider gate was not entered", error);
    jsti_insertion_cancel(target.value);
    if (jsti_selection_read(target.value, selected, sizeof(selected), error, sizeof(error)) != -1 || selected[0])
        return describe("voice edit blocked capture", "a cancelled provider retained selection authority");
    SetEvent(state.release.value);
    target.destroy();
    if (!waitForWorkersToExit(5000)) return "A voice-edit worker outlived its retired target.";
    return {};
}
} // namespace jsti::textoutput::selftest

using namespace jsti::textoutput::selftest;

int jsti_text_output_self_test(char *error, size_t capacity) {
    std::lock_guard<std::mutex> lock(selfTestMutex);
    std::string failure = checkPureHelpers();
    if (!failure.empty()) return jsti::fail(failure, error, capacity);
    try {
        failure = checkSelectionRangeBudget();
        if (!failure.empty()) return jsti::fail(failure, error, capacity);
        auto state = std::make_unique<Fixture>();
        fixture = state.get();
        EnvironmentGuard environmentGuard;
        if (!state->host.start(failure)) { fixture = nullptr; return jsti::fail(failure, error, capacity); }
        state->foreground = state->host.window;
        failure = checkNativePaths(*state);
        if (failure.empty()) failure = checkAppSwitchPolicies(*state);
        if (failure.empty()) failure = checkCorrectionLearning(*state);
        if (failure.empty()) failure = checkAutomationPaths(*state);
        if (failure.empty()) failure = checkLifetimes(*state);
        if (failure.empty()) failure = checkClipboardRacesAndCancellation(*state);
        if (failure.empty()) failure = checkCapturedProcessAndWorkerBounds(*state);
        if (failure.empty()) failure = checkDeferredFocusAndUncertainTimeout(*state);
        if (failure.empty()) failure = checkSelectionSources(*state);
        if (failure.empty()) failure = checkVoiceEditAnchors(*state);
        if (state->release.value) SetEvent(state->release.value);
        if (!waitForWorkersToExit(10000)) {
            // A worker that never exited may still call the seams; keep the
            // fixture alive rather than free memory under it.
            state.release();
            if (failure.empty()) failure = "An insertion worker outlived its target.";
            return jsti::fail(failure, error, capacity);
        }
        state->host.stop();
        fixture = nullptr;
        if (!failure.empty()) return jsti::fail(failure, error, capacity);
    } catch (const std::exception &) {
        return jsti::fail("The text output self-test could not allocate its fixtures.", error, capacity);
    }
    if (error && capacity) error[0] = 0;
    return 0;
}
