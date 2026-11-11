// Text output self-test: Pure helpers, the selection range budget, app-switch policies and the native Edit/RichEdit paths.
#include "WindowsTextOutputSelfTestSupport.hpp"

namespace jsti::textoutput::selftest {

std::string checkSelectionRangeBudget() {
    if (maximumSelectedTextUnits != 200000) return "The native selection staging limit changed.";
    std::wstring text;
    if (!appendSelectedRange(text, L"") || !text.empty() ||
        !appendSelectedRange(text, L"first") || !appendSelectedRange(text, L"") ||
        !appendSelectedRange(text, L"second") || text != L"first\nsecond")
        return "Empty selected ranges introduced separators or dropped selected text.";
    text.assign(199998, L'x');
    if (!appendSelectedRange(text, L"y") || text.size() != 200000 ||
        text.substr(199998) != L"\ny" || !appendSelectedRange(text, L"") || text.size() != 200000)
        return "An exact-limit selection or its trailing empty range was rejected.";
    const std::wstring maximum = text;
    if (appendSelectedRange(text, L"z") || text != maximum)
        return "An oversized selection was accepted or partially appended.";
    text.assign(199999, L'x');
    const std::wstring beforeSeparator = text;
    if (appendSelectedRange(text, L"y") || text != beforeSeparator)
        return "The inter-range separator escaped the selection budget.";
    text.clear();
    if (!appendSelectedRange(text, std::wstring(200000, L'x')) || text.size() != 200000)
        return "A single exact-limit range was rejected.";
    text.clear();
    if (appendSelectedRange(text, std::wstring(200001, L'x')) || !text.empty() ||
        appendSelectedRange(text, std::wstring(L"x\0y", 3)) || !text.empty())
        return "An oversized or embedded-NUL range was accepted or partially appended.";
    return {};
}

std::string checkPureHelpers() {
    INPUT inputs[4];
    pasteInputs(inputs);
    const WORD keys[4] = {VK_CONTROL, 'V', 'V', VK_CONTROL};
    for (size_t index = 0; index < 4; ++index) {
        const bool release = index >= 2;
        if (inputs[index].type != INPUT_KEYBOARD || inputs[index].ki.wVk != keys[index] ||
            ((inputs[index].ki.dwFlags & KEYEVENTF_KEYUP) != 0) != release) {
            return describe("paste inputs", "the Ctrl+V sequence is not Ctrl down, V down, V up, Ctrl up");
        }
    }
    if (normalizedForComparison(L"  Hello\r\n  world​  !") != L"Hello world !") {
        return describe("normalisation", "line endings, whitespace runs and zero-width marks were not folded");
    }
    if (!containsNormalized(L"first\r\nsecond line", L"first second") || containsNormalized(L"abc", L"") ||
        containsNormalized(L"abc", L"abd")) {
        return describe("normalisation", "containment did not compare visible words");
    }
    JSTIInsertionResult result{};
    char error[256]{};
    if (jsti_insertion_insert(nullptr, "text", 0, &result, error, sizeof(error)) != -1 || result.method != JSTI_INSERTION_METHOD_NONE) {
        return describe("null target", "a missing target was not rejected");
    }
    if (jsti_insertion_learning(nullptr, "text", nullptr, 0, error, sizeof(error)) != -1) {
        return describe("learning null target", "a missing owned range was not rejected");
    }
    jsti_insertion_destroy(nullptr);
    return {};
}

std::string checkAppSwitchPolicies(Fixture &state) {
    SyntheticHost destination;
    std::string error;
    if (!destination.start(error)) return describe("app-switch destination", "setup failed", error.c_str());
    Environment environment = testEnvironment(true);
    environment.ownApplication = &fakeOwnApplication;
    environment.sameApplication = &fakeSameApplication;
    Target target;
    auto prepare = [&] {
        state.foreground = state.host.window;
        state.switchForegroundIsOwn = false;
        state.switchForegroundSameApp = false;
        setEnvironment(environment);
        setText(state.host.edit, L"original");
        setText(destination.edit, L"destination");
        select(state.host.edit, 8, 8);
        select(destination.edit, 11, 11);
        if (!state.host.focus(state.host.edit)) {
            error = "Could not focus the synthetic original field.";
            return false;
        }
        if (!capture(target, error)) return false;
        // UIA can attach the synthetic GUI queues: capture before moving focus.
        if (!destination.focus(destination.edit)) {
            error = "Could not focus the synthetic destination field.";
            return false;
        }
        state.pendingTarget = target.value;
        return true;
    };
    const int beforePaste = state.pasteCalls.load();

    if (!prepare()) return describe("app-switch original", "capture failed", error.c_str());
    state.foreground = destination.window;
    auto attempt = insert(target, " text", JSTI_INSERTION_ORIGINAL_APP);
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_NATIVE_EDIT ||
        textOf(state.host.edit) != L"original text" || textOf(destination.edit) != L"destination")
        return describe("app-switch original", "background native delivery touched the wrong destination", attempt.error);

    if (!prepare()) return describe("app-switch original field", "capture failed", error.c_str());
    setText(state.host.second, L"other field");
    if (!state.host.focus(state.host.second)) return describe("app-switch original field", "could not move field focus");
    attempt = insert(target, " text", JSTI_INSERTION_ORIGINAL_APP);
    if (attempt.status != 0 || textOf(state.host.edit) != L"original text" ||
        textOf(state.host.second) != L"other field")
        return describe("app-switch original field", "the newly focused field replaced the captured destination", attempt.error);

    if (!prepare()) return describe("app-switch strict", "capture failed", error.c_str());
    state.foreground = destination.window;
    attempt = insert(target, "clipboard", JSTI_INSERTION_ONLY_ORIGINAL_FRONT);
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_CLIPBOARD || attempt.result.verified ||
        state.clipboard.unicodeText() != L"clipboard" || textOf(state.host.edit) != L"original" ||
        textOf(destination.edit) != L"destination")
        return describe("app-switch strict", "copy-only delivery inserted or claimed confirmation", attempt.error);

    if (!prepare()) return describe("app-switch same app", "capture failed", error.c_str());
    state.foreground = destination.window;
    state.switchForegroundSameApp = true;
    attempt = insert(target, " text", JSTI_INSERTION_ONLY_ORIGINAL_FRONT);
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_NATIVE_EDIT ||
        textOf(state.host.edit) != L"original text" || textOf(destination.edit) != L"destination")
        return describe("app-switch same app", "another window of the same app was treated as another app", attempt.error);

    if (!prepare()) return describe("app-switch current", "capture failed", error.c_str());
    state.foreground = destination.window;
    attempt = insert(target, " text", JSTI_INSERTION_CURRENT_APP);
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_NATIVE_EDIT ||
        textOf(state.host.edit) != L"original" || textOf(destination.edit) != L"destination text")
        return describe("app-switch current", "did not use the captured delivery-time field", attempt.error);
    char learningError[256]{};
    if (jsti_insertion_learning(target.value, " text", nullptr, 0, learningError, sizeof(learningError)) != -1)
        return describe("app-switch learning", "redirect granted the original field correction authority");

    if (!prepare()) return describe("app-switch sensitive destination", "capture failed", error.c_str());
    if (!destination.focus(destination.password))
        return describe("app-switch sensitive destination", "could not focus the synthetic password field");
    state.foreground = destination.window;
    attempt = insert(target, " text", JSTI_INSERTION_CURRENT_APP);
    if (attempt.status != -1 || textOf(state.host.edit) != L"original" ||
        textOf(destination.edit) != L"destination")
        return describe("app-switch sensitive destination", "a password destination was not refused", attempt.error);

    if (!prepare()) return describe("app-switch own UI", "capture failed", error.c_str());
    state.foreground = destination.window;
    state.switchForegroundIsOwn = true;
    attempt = insert(target, " text", JSTI_INSERTION_CURRENT_APP);
    if (attempt.status != 0 || textOf(state.host.edit) != L"original text" ||
        textOf(destination.edit) != L"destination")
        return describe("app-switch own UI", "own UI became a new delivery destination", attempt.error);

    if (!prepare()) return describe("app-switch strict own UI", "capture failed", error.c_str());
    state.foreground = destination.window;
    state.switchForegroundIsOwn = true;
    attempt = insert(target, "clipboard", JSTI_INSERTION_ONLY_ORIGINAL_FRONT);
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_CLIPBOARD ||
        textOf(state.host.edit) != L"original")
        return describe("app-switch strict own UI", "own UI bypassed strict original-front policy", attempt.error);

    environment.nativeDirectPath = false;
    if (!prepare()) return describe("app-switch unsupported background", "capture failed", error.c_str());
    state.foreground = destination.window;
    attempt = insert(target, "clipboard", JSTI_INSERTION_ORIGINAL_APP);
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_CLIPBOARD ||
        textOf(state.host.edit) != L"original" || textOf(destination.edit) != L"destination")
        return describe("app-switch unsupported background", "unsafe background UIA/paste was attempted", attempt.error);
    environment.nativeDirectPath = true;

    for (auto hook : {&switchAgainBeforeRedirect, &changeRevisionBeforeRedirect, &cancelBeforeRedirect}) {
        environment.beforeRedirectedInsert = hook;
        if (!prepare()) return describe("app-switch second focus/cancel", "capture failed", error.c_str());
        state.foreground = destination.window;
        attempt = insert(target, " text", JSTI_INSERTION_CURRENT_APP);
        if (attempt.status != -1 || attempt.result.method != JSTI_INSERTION_METHOD_NONE ||
            textOf(state.host.edit) != L"original" || textOf(destination.edit) != L"destination")
            return describe("app-switch second focus/cancel", "a changed or cancelled child still inserted", attempt.error);
    }
    environment.beforeRedirectedInsert = nullptr;

    if (!prepare()) return describe("app-switch clipboard failure", "capture failed", error.c_str());
    state.foreground = destination.window;
    state.clipboard.failUnicodeSet = true;
    attempt = insert(target, "clipboard", JSTI_INSERTION_ONLY_ORIGINAL_FRONT);
    if (attempt.status != -1 || attempt.result.method != JSTI_INSERTION_METHOD_NONE ||
        textOf(state.host.edit) != L"original" || textOf(destination.edit) != L"destination")
        return describe("app-switch clipboard failure", "a failed copy reported success", attempt.error);

    if (!prepare()) return describe("app-switch stale", "capture failed", error.c_str());
    HWND stale = nullptr;
    state.host.run([&] {
        stale = CreateWindowExW(0, L"EDIT", L"stale", WS_CHILD | WS_VISIBLE, 0, 0, 100, 20,
                               state.host.window, nullptr, GetModuleHandleW(nullptr), nullptr);
    });
    if (!stale || !state.host.focus(stale) || !capture(target, error))
        return describe("app-switch stale", "could not capture a disposable field", error.c_str());
    state.host.run([&] { DestroyWindow(stale); });
    state.foreground = destination.window;
    attempt = insert(target, " text", JSTI_INSERTION_CURRENT_APP);
    if (attempt.status != -1 || textOf(destination.edit) != L"destination")
        return describe("app-switch stale", "a destroyed original field authorized an unrelated insert", attempt.error);
    state.foreground = state.host.window;
    state.pendingTarget = nullptr;
    state.switchForegroundIsOwn = false;
    state.switchForegroundSameApp = false;
    if (state.pasteCalls != beforePaste) return describe("app-switch native policy", "unexpected paste-key dispatch");
    setEnvironment(testEnvironment(true));
    return {};
}

std::string checkNativePaths(Fixture &state) {
    SyntheticHost &host = state.host;
    setEnvironment(testEnvironment(true));
    Target target;
    std::string error;

    // 1. Insert at the caret of a single-line Edit.
    setText(host.edit, L"Hello world");
    if (!host.focus(host.edit)) return describe("native caret", "could not focus the synthetic Edit control");
    select(host.edit, 5, 5);
    if (!capture(target, error)) return describe("native caret", "capture failed", error.c_str());
    Attempt attempt = insert(target, " dear");
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_NATIVE_EDIT || attempt.result.verified != 1 ||
        attempt.result.identity != JSTI_INSERTION_IDENTITY_WINDOW || attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_UNTOUCHED) {
        return describe("native caret", "insertion did not report a verified native edit", attempt.error);
    }
    if (textOf(host.edit) != L"Hello dear world") return describe("native caret", "text was not inserted at the caret");
    const LRESULT selection = SendMessageW(host.edit, EM_GETSEL, 0, 0);
    if (LOWORD(selection) != 10 || HIWORD(selection) != 10) return describe("native caret", "the caret did not follow the insertion");

    // 2. Replace a selection with text containing a surrogate pair (RichEdit).
    // RichEdit binds a fallback font the first time it meets an emoji, which
    // on a cold machine can outlast the insertion's one-second timeout; bind
    // it once, untimed, so the step measures insertion rather than font load.
    setText(host.richEdit, L"\xD83C\xDF99 caf\x00E9");
    setText(host.richEdit, L"\x03B1\x03B2\x03B3");
    if (!host.focus(host.richEdit)) return describe("surrogates", "could not focus the synthetic RichEdit control");
    select(host.richEdit, 1, 2);
    if (!capture(target, error)) return describe("surrogates", "capture failed", error.c_str());
    attempt = insert(target, "\xF0\x9F\x8E\x99 caf\xC3\xA9");
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_NATIVE_EDIT) {
        return describe("surrogates", "RichEdit insertion failed", attempt.error);
    }
    if (textOf(host.richEdit) != L"\x03B1\xD83C\xDF99 caf\x00E9\x03B3") {
        return describe("surrogates", "the selection was not replaced with the exact UTF-16 sequence");
    }

    // 3. Explicit replace-field flag.
    if (!capture(target, error)) return describe("replace field", "capture failed", error.c_str());
    attempt = insert(target, "replaced", JSTI_INSERTION_REPLACE_FIELD);
    if (attempt.status != 0 || textOf(host.richEdit) != L"replaced") {
        return describe("replace field", "the whole field was not replaced", attempt.error);
    }

    // 4. Password and read-only refusal, new and legacy entrypoints.
    if (!host.focus(host.password)) return describe("password", "could not focus the password control");
    if (!capture(target, error)) return describe("password", "capture failed", error.c_str());
    attempt = insert(target, "secret");
    if (attempt.status != -1 || !contains(attempt.error, "password") || !textOf(host.password).empty()) {
        return describe("password", "a password field was not refused", attempt.error);
    }
    JSTITextTarget legacy{};
    char legacyError[256]{};
    if (jsti_target_capture(&legacy, legacyError, sizeof(legacyError)) != 0 ||
        jsti_target_insert_text(&legacy, "secret", legacyError, sizeof(legacyError)) != -1 ||
        !contains(legacyError, "password") || !textOf(host.password).empty()) {
        return describe("password", "the legacy entrypoint did not refuse a password field", legacyError);
    }
    setText(host.readOnly, L"fixed");
    if (!host.focus(host.readOnly)) return describe("read-only", "could not focus the read-only control");
    if (!capture(target, error)) return describe("read-only", "capture failed", error.c_str());
    attempt = insert(target, "change");
    if (attempt.status != -1 || !contains(attempt.error, "read-only") || textOf(host.readOnly) != L"fixed") {
        return describe("read-only", "a read-only field was not refused", attempt.error);
    }

    // 5. Focus moved to another control after capture.
    if (!host.focus(host.edit)) return describe("stale focus", "could not focus the first control");
    if (!capture(target, error)) return describe("stale focus", "capture failed", error.c_str());
    setText(host.second, L"other");
    if (!host.focus(host.second)) return describe("stale focus", "could not move focus to the second control");
    attempt = insert(target, "late");
    if (attempt.status != -1 || !contains(attempt.error, "no longer focused") ||
        textOf(host.edit) != L"Hello dear world" || textOf(host.second) != L"other") {
        return describe("stale focus", "a moved focus was not rejected", attempt.error);
    }

    // 6. Foreground window changed after capture.
    if (!host.focus(host.edit)) return describe("foreground", "could not refocus the first control");
    if (!capture(target, error)) return describe("foreground", "capture failed", error.c_str());
    state.foreground = GetDesktopWindow();
    attempt = insert(target, "late");
    state.foreground = host.window;
    if (attempt.status != -1 || !contains(attempt.error, "no longer focused") || textOf(host.edit) != L"Hello dear world") {
        return describe("foreground", "a changed foreground window was not rejected", attempt.error);
    }

    // 7. Legacy direct entrypoint still inserts into a native control.
    setText(host.edit, L"ab");
    select(host.edit, 1, 1);
    if (jsti_target_capture(&legacy, legacyError, sizeof(legacyError)) != 0 ||
        jsti_target_insert_text(&legacy, "X", legacyError, sizeof(legacyError)) != 0 || textOf(host.edit) != L"aXb") {
        return describe("legacy insert", "the retained entrypoint did not insert at the caret", legacyError);
    }

    // 8. Invalid text.
    if (!capture(target, error)) return describe("invalid text", "capture failed", error.c_str());
    attempt = insert(target, "\xFF");
    if (attempt.status != -1 || !contains(attempt.error, "UTF-8")) return describe("invalid text", "invalid UTF-8 was accepted");
    attempt = insert(target, "");
    if (attempt.status != -1 || textOf(host.edit) != L"aXb") return describe("invalid text", "empty text was accepted");

    // 9. A control disabled after capture is refused (or focus left it).
    state.host.run([&] { EnableWindow(host.edit, FALSE); });
    attempt = insert(target, "off");
    state.host.run([&] { EnableWindow(host.edit, TRUE); });
    if (attempt.status != -1 || textOf(host.edit) != L"aXb") return describe("disabled", "a disabled field accepted text", attempt.error);
    return {};
}

} // namespace jsti::textoutput::selftest
