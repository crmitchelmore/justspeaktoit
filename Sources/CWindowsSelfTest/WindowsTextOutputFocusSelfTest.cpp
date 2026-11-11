// Text output self-test: Captured-process and worker bounds, deferred focus, correction learning and selection sources.
#include "WindowsTextOutputSelfTestSupport.hpp"

namespace jsti::textoutput::selftest {

std::string checkCapturedProcessAndWorkerBounds(Fixture &state) {
    SyntheticHost &host = state.host;
    Environment environment = testEnvironment(false);
    setEnvironment(environment);
    Target target;
    std::string error;
    if (!host.focus(host.edit) || !capture(target, error)) return describe("captured process", "capture failed", error.c_str());
    size_t required = 0;
    char message[256]{};
    if (jsti_insertion_executable_path(target.value, nullptr, 0, &required, message, sizeof(message)) != 2 || required < 2) {
        return describe("captured process", "size query failed", message);
    }
    char shortBuffer[1] = {'x'};
    if (jsti_insertion_executable_path(target.value, shortBuffer, 1, &required, message, sizeof(message)) != 2 || shortBuffer[0]) {
        return describe("captured process", "short-buffer contract failed", message);
    }
    std::vector<char> path(required);
    if (jsti_insertion_executable_path(target.value, path.data(), path.size(), &required, message, sizeof(message)) != 0 ||
        std::strlen(path.data()) + 1 != required) return describe("captured process", "path query failed", message);
    const std::string original(path.data());
    std::vector<char> foregroundPath(131073);
    const size_t workers = liveWorkerCount();
    if (jsti_foreground_executable_path(foregroundPath.data(), foregroundPath.size(), message, sizeof(message)) != 0 ||
        original != foregroundPath.data() || liveWorkerCount() != workers) {
        return describe("foreground profile", "app lookup changed workers or returned another process", message);
    }
    if (jsti_foreground_executable_path(shortBuffer, 1, message, sizeof(message)) != -1 || shortBuffer[0]) {
        return describe("foreground profile", "short-buffer failure was not explicit", message);
    }
    environment.allowCurrentProcess = false;
    setEnvironment(environment);
    if (jsti_foreground_executable_path(foregroundPath.data(), foregroundPath.size(), message, sizeof(message)) != 0 ||
        foregroundPath[0]) return describe("foreground profile", "the app matched its own process", message);
    environment.allowCurrentProcess = true;
    setEnvironment(environment);
    state.foreground = GetDesktopWindow();
    jsti_insertion_cancel(target.value);
    const int status = jsti_insertion_executable_path(target.value, path.data(), path.size(), &required, message, sizeof(message));
    state.foreground = host.window;
    if (status != 0 || original != path.data()) return describe("captured process", "getter followed changed focus", message);
    target.destroy();
    if (!waitForWorkersToExit(10000)) return describe("worker bounds", "earlier workers did not exit");
    if (!state.release.value) state.release.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!state.release.value) return describe("worker bounds", "release event failed");
    ResetEvent(state.release.value);
    environment.beforeAutomation = &blockingHook;
    environment.destroyWaitMs = 100;
    state.blockOnCall = -1;
    state.hookCalls = 0;
    setEnvironment(environment);
    std::vector<std::unique_ptr<Target>> targets;
    for (int index = 0; index < 7; ++index) {
        auto next = std::make_unique<Target>();
        if (!capture(*next, error)) { SetEvent(state.release.value); return describe("worker bounds", "capture failed", error.c_str()); }
        targets.push_back(std::move(next));
    }
    const size_t peak = liveWorkerCount();
    Attempt attempt = insert(*targets.back(), "queued");
    SetEvent(state.release.value);
    targets.clear();
    if (peak != 4 || attempt.status != -1 || !contains(attempt.error, "workers are busy") || !waitForWorkersToExit(10000)) {
        return describe("worker bounds", "worker admission or drain was not bounded", attempt.error);
    }
    state.blockOnCall = 0;
    setEnvironment(testEnvironment(false));
    return {};
}

std::string checkDeferredFocusAndUncertainTimeout(Fixture &state) {
    SyntheticHost &host = state.host;
    Target target;
    std::string error;
    Environment environment = testEnvironment(false);
    environment.beforeAutomation = &blockingHook;
    state.blockOnCall = 1;
    state.hookCalls = 0;
    ResetEvent(state.release.value);
    setEnvironment(environment);
    setText(host.edit, L"before");
    if (!host.focus(host.edit) || !capture(target, error)) return describe("delayed focus", "capture failed", error.c_str());
    const ULONGLONG deadline = GetTickCount64() + 2000;
    while (state.hookCalls == 0 && GetTickCount64() < deadline) Sleep(1);
    ++state.focusRevision; // A virtual field moved while provider resolution was blocked.
    SetEvent(state.release.value);
    state.pasteCalls = 0;
    Attempt attempt = insert(target, "late");
    if (attempt.status != -1 || state.pasteCalls != 0 || textOf(host.edit) != L"before") {
        return describe("delayed focus", "a field resolved after a focus transition was accepted", attempt.error);
    }
    target.destroy();
    setEnvironment(testEnvironment(false));
    state.failFocusResolution = true;
    if (!capture(target, error)) { state.failFocusResolution = false; return describe("failed focus", "capture failed"); }
    attempt = insert(target, "late");
    target.destroy();
    state.failFocusResolution = false;
    if (attempt.status != -1 || state.pasteCalls != 0) return describe("failed focus", "failed UIA capture fell back to an HWND");

    environment = testEnvironment(false);
    environment.insertTimeoutMs = 200;
    setEnvironment(environment);
    state.pasteMode = Fixture::PasteMode::BlockAfterInsert;
    ResetEvent(state.release.value);
    select(host.edit, 6, 6);
    if (!capture(target, error)) return describe("uncertain timeout", "capture failed", error.c_str());
    attempt = insert(target, " appended");
    SetEvent(state.release.value);
    target.destroy();
    state.pasteMode = Fixture::PasteMode::Insert;
    if (attempt.status != 1 || attempt.result.method != JSTI_INSERTION_METHOD_PASTE ||
        textOf(host.edit) != L"before appended" || !waitForWorkersToExit(10000)) {
        return describe("uncertain timeout", "a submitted operation was reported as nothing inserted", attempt.error);
    }
    return {};
}

std::string checkCorrectionLearning(Fixture &state) {
    setEnvironment(testEnvironment(true));
    SyntheticHost &host = state.host;
    Target target;
    std::string reason;
    char error[512]{}, edited[32769]{};
    auto arm = [&] {
        return jsti_insertion_learning(target.value, "Susie", nullptr, 0, error, sizeof(error));
    };
    auto sample = [&] {
        return jsti_insertion_learning(target.value, nullptr, edited, sizeof(edited), error, sizeof(error));
    };
    auto prepare = [&] {
        setText(host.richEdit, L"Left  right");
        if (!host.focus(host.richEdit)) return false;
        select(host.richEdit, 5, 5);
        return capture(target, reason);
    };
    if (!prepare()) return describe("learning capture", "synthetic capture failed", reason.c_str());
    if (arm() != -1) return describe("learning acknowledgement", "an unacknowledged target was observed");
    Attempt attempt = insert(target, "Susie");
    if (attempt.status != 0 || attempt.result.verified != 1) {
        return describe("learning insertion", "synthetic native insertion was not confirmed", attempt.error);
    }
    const int supported = supportsTextPattern(host.richEdit);
    if (supported < 0) return describe("learning capability", "TextPattern capability could not be established");
    if (!supported) {
        if (arm() != -1) return describe("learning unsupported", "a field without TextPattern was observed");
        return {};
    }
    if (arm() != 0) return describe("learning range", "the acknowledged span was not retained", error);
    select(host.richEdit, 7, 8);
    SendMessageW(host.richEdit, EM_REPLACESEL, TRUE, reinterpret_cast<LPARAM>(L"z"));
    if (sample() != 0 || std::strcmp(edited, "Suzie") != 0) {
        return describe("learning exact span", "readback included unrelated field content or lost its range", error);
    }
    if (sample() != -1 || arm() != -1) return describe("learning one-shot", "a consumed lease was reused");

    if (!prepare() || insert(target, "Susie").status != 0 || arm() != 0) {
        return describe("learning password", "setup failed", error);
    }
    const LONG_PTR savedStyle = GetWindowLongPtrW(host.richEdit, GWL_STYLE);
    SetWindowLongPtrW(host.richEdit, GWL_STYLE, savedStyle | ES_PASSWORD);
    const int sensitive = sample();
    SetWindowLongPtrW(host.richEdit, GWL_STYLE, savedStyle);
    if (sensitive != -1) return describe("learning password", "a password control was observed");

    if (!prepare() || insert(target, "Susie").status != 0) return describe("learning caret", "setup failed");
    select(host.richEdit, 5, 5);
    if (arm() != -1) return describe("learning caret", "a moved caret was mistaken for the insertion receipt");

    if (!prepare() || insert(target, "Susie").status != 0 || arm() != 0) {
        return describe("learning context", "setup failed", error);
    }
    select(host.richEdit, 0, 1);
    SendMessageW(host.richEdit, EM_REPLACESEL, TRUE, reinterpret_cast<LPARAM>(L"R"));
    if (sample() != -1) return describe("learning context", "an unrelated prefix edit was learned");

    if (!prepare() || insert(target, "Susie").status != 0 || arm() != 0) {
        return describe("learning focus", "setup failed", error);
    }
    ++state.focusRevision;
    if (sample() != -1) return describe("learning focus", "a focus transition retained observation authority");

    if (!prepare() || insert(target, "Susie").status != 0 || arm() != 0) {
        return describe("learning identity", "setup failed", error);
    }
    state.resolveOverride = host.edit;
    const int otherControl = sample();
    state.resolveOverride = nullptr;
    if (otherControl != -1) return describe("learning identity", "another UIA control was read");

    if (!prepare() || insert(target, "Susie").status != 0 || arm() != 0) {
        return describe("learning window", "setup failed", error);
    }
    state.foreground = GetDesktopWindow();
    const int otherWindow = sample();
    state.foreground = host.window;
    if (otherWindow != -1) return describe("learning window", "another foreground window retained authority");

    if (!prepare() || insert(target, "Susie").status != 0 || arm() != 0) {
        return describe("learning cancellation", "setup failed", error);
    }
    jsti_insertion_cancel(target.value);
    if (sample() != -1) return describe("learning cancellation", "a cancelled target returned text");
    return {};
}

std::string checkSelectionSources(Fixture &state) {
    auto &host = state.host;
    Environment environment = testEnvironment(false);
    environment.allowCurrentProcess = false;
    setEnvironment(environment);
    state.foreground = host.window;
    state.resolveOverride = nullptr;
    state.failFocusResolution = false;
    if (!host.focus(host.richEdit)) return "The selected-text fixture could not focus its RichEdit.";
    if (supportsTextPattern(host.richEdit) != 1)
        return "The selected-text RichEdit fixture did not expose its required TextPattern.";
    setText(host.richEdit, L"private prefix Speak this private suffix");
    select(host.richEdit, 15, 25);
    Target target;
    char error[512]{}, selected[128]{};
    auto captureSelection = [&] {
        target.destroy();
        target.value = jsti_selection_capture(error, sizeof(error));
        return target.value != nullptr;
    };
    auto read = [&] {
        std::memset(selected, 0, sizeof(selected));
        return jsti_selection_read(target.value, selected, sizeof(selected), error, sizeof(error));
    };
    const DWORD sequence = state.clipboard.sequence();
    const int pastes = state.pasteCalls.load();
    SendMessageW(host.richEdit, EM_SETREADONLY, TRUE, 0);
    if (!captureSelection() || read() != 0 || std::strcmp(selected, "Speak this") != 0)
        return describe("read-only selection", "did not read only the selected range", error);
    if (read() != -1 || selected[0])
        return describe("selection one-shot", "a consumed snapshot returned text again");
    SendMessageW(host.richEdit, EM_SETREADONLY, FALSE, 0);
    const Attempt forbidden = insert(target, "forbidden");
    if (forbidden.status != -1 || !contains(forbidden.error, "read-only"))
        return describe("selection authority", "a read-only target permitted insertion");
    JSTIInsertionResult result{};
    if (jsti_insertion_copy_text(target.value, "forbidden", &result, error, sizeof(error)) != -1 ||
        !contains(error, "read-only"))
        return describe("selection authority", "a read-only target permitted clipboard replacement");
    if (textOf(host.richEdit) != L"private prefix Speak this private suffix" ||
        state.clipboard.sequence() != sequence || state.pasteCalls != pastes)
        return describe("selection side effects", "text, clipboard or keyboard input changed");

    state.resolveOverride = host.second;
    if (!captureSelection()) return describe("selection identity", "capture failed", error);
    const int differentField = read();
    state.resolveOverride = nullptr;
    if (differentField != -1 || selected[0])
        return describe("selection identity", "another field supplied selected text");
    if (!captureSelection()) return describe("selection focus", "capture failed", error);
    ++state.focusRevision;
    if (read() != -1 || selected[0])
        return describe("selection focus", "a focus transition retained selection authority");
    if (!captureSelection()) return describe("selection foreground", "capture failed", error);
    state.foreground = GetDesktopWindow();
    const int differentWindow = read();
    state.foreground = host.window;
    if (differentWindow != -1 || selected[0])
        return describe("selection foreground", "a different foreground window retained authority");

    const LONG_PTR savedStyle = GetWindowLongPtrW(host.richEdit, GWL_STYLE);
    SetWindowLongPtrW(host.richEdit, GWL_STYLE, savedStyle | ES_PASSWORD);
    const bool passwordCaptured = captureSelection();
    const int passwordRead = passwordCaptured ? read() : -1;
    SetWindowLongPtrW(host.richEdit, GWL_STYLE, savedStyle);
    if (passwordRead != -1 || selected[0])
        return describe("selection password", "a password control supplied selected text");
    select(host.richEdit, 15, 15);
    if (!captureSelection() || read() != -1 || selected[0])
        return describe("selection caret", "a caret fell back to whole-field text");
    select(host.richEdit, 15, 25);
    if (!captureSelection()) return describe("selection buffer", "capture failed", error);
    char undersized[2]{'x', 0};
    if (jsti_selection_read(target.value, undersized, sizeof(undersized), error, sizeof(error)) != -1 ||
        undersized[0])
        return describe("selection buffer", "a too-small buffer returned partial text");
    if (!captureSelection()) return describe("selection cancellation", "capture failed", error);
    jsti_insertion_cancel(target.value);
    if (read() != -1 || selected[0])
        return describe("selection cancellation", "a cancelled snapshot returned text");
    target.destroy();

    SendMessageW(host.richEdit, EM_EXLIMITTEXT, 0, 200001);
    std::wstring maximum(200000, L'x');
    setText(host.richEdit, maximum.c_str());
    select(host.richEdit, 0, 200000);
    std::vector<char> bounded(600004, 0);
    if (!captureSelection() || jsti_selection_read(
        target.value, bounded.data(), bounded.size(), error, sizeof(error)) != 0 ||
        std::strlen(bounded.data()) != maximum.size())
        return describe("selection exact limit", "the 200,000-unit boundary was not preserved", error);
    maximum += L'x';
    setText(host.richEdit, maximum.c_str());
    select(host.richEdit, 0, 200001);
    if (textOf(host.richEdit).size() != maximum.size())
        return describe("selection over limit", "the fixture did not contain the required oversized selection");
    if (!captureSelection() || jsti_selection_read(
        target.value, bounded.data(), bounded.size(), error, sizeof(error)) != -1 ||
        bounded[0] || !contains(error, "200,000"))
        return describe("selection over limit", "oversized input was truncated or accepted", error);
    target.destroy();

    if (!state.release.value) state.release.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!state.release.value) return "Could not create the selected-text timeout gate.";
    ResetEvent(state.release.value);
    state.hookCalls = 0;
    state.blockOnCall = -1;
    struct ReleaseGate {
        Fixture &state;
        ~ReleaseGate() { SetEvent(state.release.value); }
    } release{state};
    environment.beforeAutomation = &blockingHook;
    environment.insertTimeoutMs = 80;
    environment.destroyWaitMs = 0;
    setEnvironment(environment);
    if (!captureSelection() || !waitForHook(1))
        return describe("selection timeout", "the provider gate was not entered", error);
    const ULONGLONG started = GetTickCount64();
    if (read() != -1 || selected[0] || GetTickCount64() - started > 2000)
        return describe("selection timeout", "a blocked provider escaped the bounded read", error);
    SetEvent(state.release.value);
    target.destroy();
    if (!waitForWorkersToExit(5000)) return "A selected-text worker outlived its cancelled request.";
    return {};
}

} // namespace jsti::textoutput::selftest
