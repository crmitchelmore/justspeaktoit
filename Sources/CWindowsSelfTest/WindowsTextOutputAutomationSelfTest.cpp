// Text output self-test: UI Automation paths, target lifetimes, clipboard races and cancellation.
#include "WindowsTextOutputSelfTestSupport.hpp"

namespace jsti::textoutput::selftest {

std::string checkAutomationPaths(Fixture &state) {
    SyntheticHost &host = state.host;
    // App-switch cases share this host but leave a different sibling value.
    setText(host.second, L"other");
    setEnvironment(testEnvironment(false));
    Target target;
    std::string error;
    const UINT customFormat = RegisterClipboardFormatW(L"JustSpeakToIt.TextOutputSelfTest");
    const std::vector<uint8_t> customBytes = {1, 2, 3, 4, 5};

    // 10. Empty field: Value pattern equals insertion.
    setText(host.edit, L"");
    if (!host.focus(host.edit)) return describe("uia value", "could not focus the synthetic Edit control");
    state.clipboard.preload(L"previous text", customFormat, customBytes);
    const DWORD untouchedSequence = state.clipboard.sequence();
    if (!capture(target, error)) return describe("uia value", "capture failed", error.c_str());
    Attempt attempt = insert(target, "first words");
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_UIA_VALUE || attempt.result.verified != 1 ||
        attempt.result.identity != JSTI_INSERTION_IDENTITY_FIELD) {
        return describe("uia value", "an empty field was not filled through the Value pattern", attempt.error);
    }
    if (textOf(host.edit) != L"first words") return describe("uia value", "the field does not contain the text");
    if (state.clipboard.sequence() != untouchedSequence || state.pasteCalls.load() != 0) {
        return describe("uia value", "the clipboard or keyboard was used for a Value pattern insertion");
    }

    // 11. Caret inside existing text: guarded paste with clipboard restore.
    setText(host.edit, L"Hello world");
    select(host.edit, 5, 5);
    if (!capture(target, error)) return describe("uia paste", "capture failed", error.c_str());
    attempt = insert(target, " dear");
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_PASTE || attempt.result.verified != 1 ||
        attempt.result.identity != JSTI_INSERTION_IDENTITY_FIELD || attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_RESTORED) {
        return describe("uia paste", "the paste path did not report a verified, restored insertion", attempt.error);
    }
    if (state.pasteCalls.load() != 1 || state.pastedText != L" dear" || !state.markersSeen) {
        return describe("uia paste", "the paste stub did not see one history-excluded transcript on the clipboard");
    }
    if (textOf(host.edit) != L"Hello dear world") return describe("uia paste", "the text was not pasted at the caret");
    const std::vector<uint8_t> restored = state.clipboard.bytes(customFormat);
    if (state.clipboard.unicodeText() != L"previous text" || restored.size() < customBytes.size() ||
        !std::equal(customBytes.begin(), customBytes.end(), restored.begin()) || state.clipboard.count() != 2) {
        return describe("uia paste", "the previous clipboard content was not restored exactly");
    }

    // 12. Password and read-only refusal through UI Automation, clipboard untouched.
    if (!host.focus(host.password)) return describe("uia password", "could not focus the password control");
    if (!capture(target, error)) return describe("uia password", "capture failed", error.c_str());
    const DWORD beforeRefusals = state.clipboard.sequence();
    attempt = insert(target, "secret");
    if (attempt.status != -1 || !contains(attempt.error, "password") || !textOf(host.password).empty()) {
        return describe("uia password", "a password field was not refused", attempt.error);
    }
    if (!host.focus(host.readOnly)) return describe("uia read-only", "could not focus the read-only control");
    if (!capture(target, error)) return describe("uia read-only", "capture failed", error.c_str());
    attempt = insert(target, "change");
    if (attempt.status != -1 || !contains(attempt.error, "read-only") || textOf(host.readOnly) != L"fixed") {
        return describe("uia read-only", "a read-only field was not refused", attempt.error);
    }
    if (state.clipboard.sequence() != beforeRefusals || state.pasteCalls.load() != 1) {
        return describe("uia refusal", "a refused field still touched the clipboard or keyboard");
    }

    // 13. Same window, different element: field identity mismatch. The host
    // window element belongs to the captured window tree (a sibling control
    // would already fail the window check), but is not the captured element.
    if (!host.focus(host.edit)) return describe("uia identity", "could not focus the first control");
    if (!capture(target, error)) return describe("uia identity", "capture failed", error.c_str());
    state.resolveOverride = host.window;
    attempt = insert(target, "late");
    state.resolveOverride = nullptr;
    if (attempt.status != -1 || !contains(attempt.error, "changed") ||
        attempt.result.method != JSTI_INSERTION_METHOD_NONE || attempt.result.verified ||
        state.clipboard.sequence() != beforeRefusals || textOf(host.edit) != L"Hello dear world" ||
        textOf(host.second) != L"other" || state.pasteCalls.load() != 1) {
        return describe("uia identity", "a different focused element was not rejected", attempt.error);
    }
    // A sibling control that is not inside the captured focus window is
    // rejected by the window check before any pattern is consulted.
    if (!capture(target, error)) return describe("uia sibling", "capture failed", error.c_str());
    state.resolveOverride = host.second;
    attempt = insert(target, "late");
    state.resolveOverride = nullptr;
    if (attempt.status != -1 || !contains(attempt.error, "no longer focused") ||
        attempt.result.method != JSTI_INSERTION_METHOD_NONE || attempt.result.verified ||
        state.clipboard.sequence() != beforeRefusals || textOf(host.second) != L"other" ||
        state.pasteCalls.load() != 1) {
        return describe("uia sibling", "an element outside the captured control was not rejected", attempt.error);
    }

    // 14. Whole selection: the Value pattern is exact when the Text pattern
    // proves the selection spans the document; otherwise the guarded paste
    // replaces the selection through the application. Both must end with the
    // selection replaced and the clipboard back in place.
    setText(host.edit, L"old text");
    select(host.edit, 0, -1);
    if (!capture(target, error)) return describe("uia selection", "capture failed", error.c_str());
    const int textPattern = supportsTextPattern(host.edit);
    attempt = insert(target, "new");
    const bool replacementMatches = textOf(host.edit) == L"new";
    const bool clipboardMatches = state.clipboard.unicodeText() == L"previous text";
    if (attempt.status != 0 || !replacementMatches ||
        (attempt.result.method != JSTI_INSERTION_METHOD_UIA_VALUE && attempt.result.method != JSTI_INSERTION_METHOD_PASTE) ||
        (attempt.result.method == JSTI_INSERTION_METHOD_UIA_VALUE && textPattern == 0) ||
        (attempt.result.method == JSTI_INSERTION_METHOD_PASTE && attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_RESTORED) ||
        !clipboardMatches) {
        const std::string detail = std::string(attempt.error) + " status=" + std::to_string(attempt.status) +
            " method=" + std::to_string(attempt.result.method) + " verified=" + std::to_string(attempt.result.verified) +
            " textPattern=" + std::to_string(textPattern) + " clipboard=" + std::to_string(attempt.result.clipboard) +
            " replacementMatches=" + std::to_string(replacementMatches) + " clipboardMatches=" + std::to_string(clipboardMatches);
        return describe("uia selection", "replacing a full selection did not keep insertion semantics", detail.c_str());
    }
    state.pasteCalls = 0;

    // 15. Fallback disabled.
    setText(host.edit, L"Hello");
    select(host.edit, 5, 5);
    if (!capture(target, error)) return describe("no fallback", "capture failed", error.c_str());
    const DWORD beforeDisabled = state.clipboard.sequence();
    attempt = insert(target, "!", JSTI_INSERTION_NO_PASTE_FALLBACK);
    if (attempt.status != -1 || !contains(attempt.error, "disabled") || state.clipboard.sequence() != beforeDisabled ||
        state.pasteCalls.load() != 0 || textOf(host.edit) != L"Hello") {
        return describe("no fallback", "the disabled fallback still pasted or touched the clipboard", attempt.error);
    }

    // 16. Keep the transcript on the clipboard. It remains the guarded paste's
    // own transient write, still excluded from history and cloud sync.
    if (!capture(target, error)) return describe("keep clipboard", "capture failed", error.c_str());
    attempt = insert(target, " there", JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD);
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_PASTE ||
        attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT || state.clipboard.unicodeText() != L" there" ||
        textOf(host.edit) != L"Hello there") {
        return describe("keep clipboard", "the transcript was not left on the clipboard", attempt.error);
    }
    if (!state.clipboard.has(excludeFromMonitoringFormat()) || !state.clipboard.has(excludeFromHistoryFormat()) ||
        !state.clipboard.has(excludeFromCloudFormat())) {
        return describe("keep clipboard", "the kept paste lost its history and cloud exclusion");
    }

    // 17. Multi-line text into a multi-line control.
    setText(host.multiline, L"line one\r\nline two");
    if (!host.focus(host.multiline)) return describe("multiline", "could not focus the multi-line control");
    select(host.multiline, 18, 18);
    state.clipboard.preload(L"before", 0, {});
    if (!capture(target, error)) return describe("multiline", "capture failed", error.c_str());
    attempt = insert(target, "\r\nline three");
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_PASTE || attempt.result.verified != 1 ||
        textOf(host.multiline) != L"line one\r\nline two\r\nline three" || state.clipboard.unicodeText() != L"before") {
        return describe("multiline", "multi-line text was not pasted and verified", attempt.error);
    }

    // 18. Keystroke delivery failure restores the clipboard and reports an error.
    if (!host.focus(host.edit)) return describe("paste failure", "could not focus the first control");
    select(host.edit, 5, 5);
    state.clipboard.preload(L"keep me", customFormat, customBytes);
    state.pasteMode = Fixture::PasteMode::Fail;
    if (!capture(target, error)) return describe("paste failure", "capture failed", error.c_str());
    attempt = insert(target, "lost");
    state.pasteMode = Fixture::PasteMode::Insert;
    if (attempt.status != -1 || !contains(attempt.error, "Synthetic") || attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_RESTORED ||
        state.clipboard.unicodeText() != L"keep me" || !state.clipboard.has(customFormat) || textOf(host.edit) != L"Hello there") {
        return describe("paste failure", "a failed keystroke did not restore the clipboard", attempt.error);
    }

    // 19. The application ignores the paste: unverified, transcript left available.
    Environment quick = testEnvironment(false);
    quick.verifyTimeoutMs = 100;
    setEnvironment(quick);
    state.pasteMode = Fixture::PasteMode::Ignore;
    if (!capture(target, error)) return describe("ignored paste", "capture failed", error.c_str());
    attempt = insert(target, "ignored");
    state.pasteMode = Fixture::PasteMode::Insert;
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_PASTE || attempt.result.verified != 0 ||
        attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT || state.clipboard.unicodeText() != L"ignored" ||
        textOf(host.edit) != L"Hello there") {
        return describe("ignored paste", "an unverifiable paste was not reported honestly", attempt.error);
    }
    setEnvironment(testEnvironment(false));

    // 20. Another application changes the clipboard meanwhile: never overwrite it.
    state.clipboard.preload(L"mine", 0, {});
    state.pasteMode = Fixture::PasteMode::InsertThenUserCopies;
    if (!capture(target, error)) return describe("clipboard changed", "capture failed", error.c_str());
    attempt = insert(target, "!");
    state.pasteMode = Fixture::PasteMode::Insert;
    if (attempt.status != 0 || attempt.result.verified != 1 || attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE ||
        state.clipboard.unicodeText() != L"user copied meanwhile" || textOf(host.edit) != L"Hello! there") {
        return describe("clipboard changed", "a clipboard changed by another app was overwritten", attempt.error);
    }
    return {};
}

std::string checkLifetimes(Fixture &state) {
    SyntheticHost &host = state.host;
    Target target;
    std::string error;
    state.release.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!state.release.value) return describe("lifetime", jsti::systemError("Creating the release event").c_str());

    // 21. A provider that never answers: the caller times out, the abandoned
    // job neither pastes nor keeps the clipboard, and the worker still exits.
    Environment blocked = testEnvironment(false);
    blocked.beforeAutomation = &blockingHook;
    blocked.insertTimeoutMs = 300;
    setEnvironment(blocked);
    state.hookCalls = 0;
    state.blockOnCall = 2;
    state.pasteCalls = 0;
    setText(host.edit, L"Hello");
    if (!host.focus(host.edit)) return describe("timeout", "could not focus the first control");
    select(host.edit, 5, 5);
    state.clipboard.preload(L"kept", 0, {});
    if (!capture(target, error)) return describe("timeout", "capture failed", error.c_str());
    const ULONGLONG started = GetTickCount64();
    Attempt attempt = insert(target, "late");
    const ULONGLONG elapsed = GetTickCount64() - started;
    if (attempt.status != -1 || !contains(attempt.error, "timed out") || elapsed > 3000) {
        return describe("timeout", "a blocked provider did not produce a bounded timeout", attempt.error);
    }
    attempt = insert(target, "again");
    if (attempt.status != -1 || !contains(attempt.error, "cancelled")) {
        return describe("timeout", "a second insertion was accepted while the worker was still busy", attempt.error);
    }
    SetEvent(state.release.value);
    target.destroy();
    if (!waitForWorkersToExit(10000)) return describe("timeout", "the worker did not exit after the provider returned");
    if (state.pasteCalls.load() != 0 || textOf(host.edit) != L"Hello" || state.clipboard.unicodeText() != L"kept") {
        return describe("timeout", "an abandoned insertion still pasted or kept the clipboard");
    }

    // 22. Destroy while the capture is blocked: bounded, then cleaned up.
    ResetEvent(state.release.value);
    blocked.destroyWaitMs = 100;
    setEnvironment(blocked);
    state.hookCalls = 0;
    state.blockOnCall = 1;
    if (!capture(target, error)) return describe("blocked destroy", "capture failed", error.c_str());
    if (!waitForHook(1)) { SetEvent(state.release.value); return describe("blocked destroy", "provider hook did not start"); }
    const ULONGLONG destroyStarted = GetTickCount64();
    target.destroy();
    if (GetTickCount64() - destroyStarted > 2000 || liveWorkerCount() != 1) {
        return describe("blocked destroy", "destroy did not detach a blocked worker within its bound");
    }
    SetEvent(state.release.value);
    if (!waitForWorkersToExit(10000)) return describe("blocked destroy", "the detached worker did not exit");

    // 23. Native insertion never waits for a blocked background capture.
    ResetEvent(state.release.value);
    Environment nativeBlocked = testEnvironment(true);
    nativeBlocked.beforeAutomation = &blockingHook;
    setEnvironment(nativeBlocked);
    state.hookCalls = 0;
    state.blockOnCall = 1;
    if (!capture(target, error)) return describe("native during capture", "capture failed", error.c_str());
    if (!waitForHook(1)) { SetEvent(state.release.value); return describe("native during capture", "provider hook did not start"); }
    attempt = insert(target, "!");
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_NATIVE_EDIT || textOf(host.edit) != L"Hello!") {
        return describe("native during capture", "native insertion waited on the background capture", attempt.error);
    }
    SetEvent(state.release.value);
    target.destroy();
    if (!waitForWorkersToExit(10000) || liveWorkerCount() != 0) return describe("native during capture", "workers leaked");
    return {};
}

std::string checkClipboardRacesAndCancellation(Fixture &state) {
    SyntheticHost &host = state.host;
    setEnvironment(testEnvironment(false));
    Target target;
    std::string error;
    auto prepare = [&]() {
        setText(host.edit, L"before");
        select(host.edit, 6, 6);
        state.clipboard.preload(L"original clipboard", 0, {});
        state.pasteCalls = 0;
        state.pasteMode = Fixture::PasteMode::Insert;
        state.prepareMode = Fixture::PrepareMode::Ready;
        state.clipboard.changeOnOpen = 0;
        state.clipboard.changeOnClose = 0;
        return host.focus(host.edit) && capture(target, error);
    };
    if (!prepare()) return describe("clipboard transaction", "capture failed", error.c_str());
    state.clipboard.changeOnOpen = state.clipboard.opens + 1;
    Attempt attempt = insert(target, " appended");
    if (attempt.status != 0 || state.clipboard.unicodeText() != L"new copy at acquisition") {
        return describe("clipboard transaction", "did not restore the content actually replaced", attempt.error);
    }
    if (!prepare()) return describe("clipboard restore race", "capture failed", error.c_str());
    state.clipboard.changeOnOpen = state.clipboard.opens + 2;
    attempt = insert(target, " appended");
    if (attempt.status != 0 || attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE ||
        state.clipboard.unicodeText() != L"new copy at acquisition") {
        return describe("clipboard restore race", "overwrote a copy made while restoration acquired ownership", attempt.error);
    }
    if (!prepare()) return describe("clipboard close race", "capture failed", error.c_str());
    state.clipboard.changeOnClose = state.clipboard.closes + 1;
    attempt = insert(target, " appended");
    if (attempt.status != -1 || state.pasteCalls != 0 || textOf(host.edit) != L"before" ||
        state.clipboard.unicodeText() != L"new copy after close") {
        return describe("clipboard close race", "pasted another copy or overwrote it", attempt.error);
    }
    if (!prepare()) return describe("clipboard placement rollback", "capture failed", error.c_str());
    state.clipboard.failUnicodeSet = true;
    attempt = insert(target, " appended");
    if (attempt.status != -1 || state.pasteCalls != 0 || state.clipboard.unicodeText() != L"original clipboard" ||
        attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_RESTORED) {
        return describe("clipboard placement rollback", "failed placement lost the original clipboard", attempt.error);
    }
    if (!prepare()) return describe("late focus", "capture failed", error.c_str());
    state.prepareMode = Fixture::PrepareMode::MoveFocus;
    attempt = insert(target, " appended");
    state.foreground = host.window;
    if (attempt.status != -1 || state.pasteCalls != 0 || textOf(host.edit) != L"before" ||
        state.clipboard.unicodeText() != L"original clipboard") {
        return describe("late focus", "a moved focus during modifier preparation still pasted", attempt.error);
    }
    if (!prepare()) return describe("late cancellation", "capture failed", error.c_str());
    state.pendingTarget = target.value;
    state.prepareMode = Fixture::PrepareMode::Cancel;
    attempt = insert(target, " appended");
    state.pendingTarget = nullptr;
    if (attempt.status != -1 || state.pasteCalls != 0 || textOf(host.edit) != L"before" ||
        state.clipboard.unicodeText() != L"original clipboard") {
        return describe("late cancellation", "cancel during modifier preparation still pasted", attempt.error);
    }
    if (!prepare()) return describe("partial shortcut", "capture failed", error.c_str());
    state.pasteMode = Fixture::PasteMode::Partial;
    state.releasedKeys = 0;
    attempt = insert(target, " appended");
    if (attempt.status != 1 || attempt.result.method != JSTI_INSERTION_METHOD_PASTE || state.releasedKeys != 2 ||
        attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT ||
        state.clipboard.unicodeText() != L" appended") {
        return describe("partial shortcut", "partial input was misreported or old clipboard substituted", attempt.error);
    }
    state.pasteMode = Fixture::PasteMode::Insert;
    state.prepareMode = Fixture::PrepareMode::Ready;
    if (!prepare()) return describe("clipboard-only output", "capture failed", error.c_str());
    {
        // Clipboard-only output is an ordinary copy, like Copy transcript:
        // unlike the guarded paste it carries no history or cloud exclusion,
        // and it never touches the field or sends keystrokes.
        JSTIInsertionResult ordinary{};
        char ordinaryError[256]{};
        if (jsti_insertion_copy_text(target.value, "copied only", &ordinary, ordinaryError, sizeof(ordinaryError)) != 0 ||
            ordinary.clipboard != JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT || state.clipboard.unicodeText() != L"copied only" ||
            state.clipboard.has(excludeFromMonitoringFormat()) || state.clipboard.has(excludeFromHistoryFormat()) ||
            state.clipboard.has(excludeFromCloudFormat()) || state.pasteCalls != 0 || textOf(host.edit) != L"before") {
            return describe("clipboard-only output", "the copy was not an ordinary clipboard write", ordinaryError);
        }
    }
    if (!prepare()) return describe("cancelled clipboard-only output", "capture failed", error.c_str());
    jsti_insertion_cancel(target.value);
    JSTIInsertionResult copied{};
    char copyError[256]{};
    if (jsti_insertion_copy_text(target.value, "cancelled copy", &copied, copyError, sizeof(copyError)) != -1 ||
        state.clipboard.unicodeText() != L"original clipboard") {
        return describe("cancelled clipboard-only output", "a cancelled request replaced the clipboard", copyError);
    }
    return {};
}

} // namespace jsti::textoutput::selftest
