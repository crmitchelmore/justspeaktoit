#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "WindowsTextOutputInternal.hpp"
#include <atomic>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

// Deterministic checks for the insertion adapter. Synthetic hidden Edit and
// RichEdit controls live on a helper UI thread inside this process; the
// adapter's environment seams substitute that window for the foreground
// window, an in-memory clipboard for the system clipboard and a stub that
// emulates an application's paste handler for SendInput. Nothing here sends
// real input, reads or writes the user's clipboard or touches another app.

namespace {
using namespace jsti::textoutput;

std::mutex selfTestMutex;

// ---- synthetic host ------------------------------------------------------------

constexpr UINT taskMessage = WM_APP + 41;
struct Task {
    void (*function)(void *);
    void *context;
};

LRESULT CALLBACK hostProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case taskMessage: {
        auto *task = reinterpret_cast<Task *>(lParam);
        if (task && task->function) task->function(task->context);
        return 0;
    }
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
    default: return DefWindowProcW(window, message, wParam, lParam);
    }
}

struct SyntheticHost {
    std::thread thread;
    std::mutex mutex;
    std::condition_variable changed;
    bool ready = false;
    std::string failure;
    DWORD threadID = 0;
    HWND window = nullptr, edit = nullptr, second = nullptr, multiline = nullptr;
    HWND password = nullptr, readOnly = nullptr, richEdit = nullptr;

    ~SyntheticHost() { stop(); }

    bool start(std::string &error) {
        thread = std::thread([this] { pump(); });
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [this] { return ready; });
        if (!failure.empty()) { error = failure; lock.unlock(); stop(); return false; }
        return true;
    }

    void stop() {
        if (!thread.joinable()) return;
        if (window) PostMessageW(window, WM_CLOSE, 0, 0);
        thread.join();
        window = nullptr;
    }

    template<class Function> void run(Function &&function) {
        Task task{[](void *context) { (*static_cast<Function *>(context))(); }, &function};
        SendMessageW(window, taskMessage, 0, reinterpret_cast<LPARAM>(&task));
    }

    HWND focused() {
        GUITHREADINFO info{};
        info.cbSize = sizeof(info);
        return GetGUIThreadInfo(threadID, &info) ? info.hwndFocus : nullptr;
    }

    bool focus(HWND control) {
        run([&] { SetFocus(control); });
        if (focused() == control) return true;
        // Some sessions refuse focus inside a never-shown window; show it
        // off-screen without activation and retry once.
        run([&] {
            ShowWindow(window, SW_SHOWNOACTIVATE);
            SetFocus(control);
        });
        return focused() == control;
    }

private:
    HWND child(const wchar_t *className, DWORD style, int identifier) {
        return CreateWindowExW(0, className, L"", WS_CHILD | WS_VISIBLE | style, 8, 8 + identifier * 28, 360, 24,
                               window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(identifier)),
                               GetModuleHandleW(nullptr), nullptr);
    }

    void pump() {
        threadID = GetCurrentThreadId();
        std::string problem;
        WNDCLASSEXW windowClass{};
        windowClass.cbSize = sizeof(windowClass);
        windowClass.lpfnWndProc = hostProcedure;
        windowClass.hInstance = GetModuleHandleW(nullptr);
        windowClass.lpszClassName = L"JSTITextOutputSelfTestHost";
        if (!RegisterClassExW(&windowClass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
            problem = jsti::systemError("Registering the synthetic host class");
        }
        if (problem.empty() && !LoadLibraryExW(L"Msftedit.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) {
            problem = jsti::systemError("Loading the RichEdit library");
        }
        if (problem.empty()) {
            window = CreateWindowExW(WS_EX_TOOLWINDOW, windowClass.lpszClassName, L"Just Speak to It insertion self-test",
                                     WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, -32000, -32000, 400, 240, nullptr, nullptr,
                                     windowClass.hInstance, nullptr);
            if (!window) problem = jsti::systemError("Creating the synthetic host window");
        }
        if (problem.empty()) {
            edit = child(L"EDIT", ES_AUTOHSCROLL, 1);
            second = child(L"EDIT", ES_AUTOHSCROLL, 2);
            multiline = child(L"EDIT", ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN, 3);
            password = child(L"EDIT", ES_PASSWORD | ES_AUTOHSCROLL, 4);
            readOnly = child(L"EDIT", ES_READONLY | ES_AUTOHSCROLL, 5);
            richEdit = child(L"RICHEDIT50W", ES_MULTILINE, 6);
            if (!edit || !second || !multiline || !password || !readOnly || !richEdit) {
                problem = jsti::systemError("Creating synthetic text controls");
            }
        }
        {
            std::lock_guard<std::mutex> lock(mutex);
            failure = problem;
            ready = true;
        }
        changed.notify_all();
        if (!problem.empty()) { if (window) DestroyWindow(window); return; }
        MSG message;
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
};

// ---- fake clipboard ------------------------------------------------------------

struct FakeClipboard final : Clipboard {
    std::mutex mutex;
    std::map<UINT, std::vector<uint8_t>> items;
    std::vector<HGLOBAL> borrowed;
    DWORD sequenceNumber = 100;
    bool isOpen = false;
    int opens = 0;

    bool open(HWND) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (isOpen) return false;
        isOpen = true;
        ++opens;
        return true;
    }
    void close() override {
        std::lock_guard<std::mutex> lock(mutex);
        for (HGLOBAL handle : borrowed) GlobalFree(handle);
        borrowed.clear();
        isOpen = false;
    }
    bool empty() override {
        std::lock_guard<std::mutex> lock(mutex);
        if (!isOpen) return false;
        items.clear();
        ++sequenceNumber;
        return true;
    }
    UINT next(UINT format) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (!isOpen || items.empty()) return 0;
        if (!format) return items.begin()->first;
        const auto following = items.upper_bound(format);
        return following == items.end() ? 0 : following->first;
    }
    HANDLE get(UINT format) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (!isOpen) return nullptr;
        const auto found = items.find(format);
        if (found == items.end()) return nullptr;
        HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, found->second.size());
        if (!handle) return nullptr;
        void *destination = GlobalLock(handle);
        if (!destination) { GlobalFree(handle); return nullptr; }
        std::memcpy(destination, found->second.data(), found->second.size());
        GlobalUnlock(handle);
        borrowed.push_back(handle);
        return handle;
    }
    bool set(UINT format, HGLOBAL data) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (!isOpen || !data) return false;
        const SIZE_T size = GlobalSize(data);
        const void *source = GlobalLock(data);
        if (!source) return false;
        items[format].assign(static_cast<const uint8_t *>(source), static_cast<const uint8_t *>(source) + size);
        GlobalUnlock(data);
        GlobalFree(data);
        ++sequenceNumber;
        return true;
    }
    DWORD sequence() override {
        std::lock_guard<std::mutex> lock(mutex);
        return sequenceNumber;
    }

    // Test-side helpers that bypass open/close, like another application.
    void preload(const std::wstring &text, UINT customFormat, const std::vector<uint8_t> &custom) {
        std::lock_guard<std::mutex> lock(mutex);
        items.clear();
        const auto *bytes = reinterpret_cast<const uint8_t *>(text.c_str());
        items[CF_UNICODETEXT].assign(bytes, bytes + (text.size() + 1) * sizeof(wchar_t));
        if (customFormat) items[customFormat] = custom;
        ++sequenceNumber;
    }
    void userWrites(const std::wstring &text) { preload(text, 0, {}); }
    std::wstring unicodeText() {
        std::lock_guard<std::mutex> lock(mutex);
        const auto found = items.find(CF_UNICODETEXT);
        if (found == items.end() || found->second.size() < sizeof(wchar_t)) return {};
        std::wstring text(reinterpret_cast<const wchar_t *>(found->second.data()), found->second.size() / sizeof(wchar_t));
        const size_t terminator = text.find(L'\0');
        return terminator == std::wstring::npos ? text : text.substr(0, terminator);
    }
    bool has(UINT format) {
        std::lock_guard<std::mutex> lock(mutex);
        return items.count(format) != 0;
    }
    std::vector<uint8_t> bytes(UINT format) {
        std::lock_guard<std::mutex> lock(mutex);
        const auto found = items.find(format);
        return found == items.end() ? std::vector<uint8_t>() : found->second;
    }
    size_t count() {
        std::lock_guard<std::mutex> lock(mutex);
        return items.size();
    }
};

// ---- seams ---------------------------------------------------------------------

struct Fixture {
    SyntheticHost host;
    FakeClipboard clipboard;
    HWND foreground = nullptr;
    HWND resolveOverride = nullptr;
    enum class PasteMode { Insert, Fail, Ignore, InsertThenUserCopies } pasteMode = PasteMode::Insert;
    std::atomic<int> pasteCalls{0};
    bool markersSeen = false;
    std::wstring pastedText;
    // Blocking hook for timeout/lifetime checks.
    jsti::Handle release;
    std::atomic<int> hookCalls{0};
    int blockOnCall = 0;
};
Fixture *fixture = nullptr;

HWND fakeForeground() { return fixture->foreground; }
Clipboard *fakeClipboard() { return &fixture->clipboard; }
void shortSleep(DWORD milliseconds) { Sleep(std::min<DWORD>(milliseconds, 10)); }

HRESULT elementFromCapturedHandle(IUIAutomation *automation, HWND focus, IUIAutomationElement **element) {
    const HWND handle = fixture->resolveOverride ? fixture->resolveOverride : focus;
    return automation->ElementFromHandle(handle, element);
}

// Emulates the target application's paste handler: read the clipboard the
// adapter prepared and insert it at the focused control's selection.
bool stubSendPaste(std::string &error) {
    Fixture &state = *fixture;
    ++state.pasteCalls;
    state.markersSeen = state.clipboard.has(excludeFromMonitoringFormat()) &&
        state.clipboard.has(excludeFromHistoryFormat()) && state.clipboard.has(excludeFromCloudFormat());
    state.pastedText = state.clipboard.unicodeText();
    if (state.pasteMode == Fixture::PasteMode::Fail) { error = "Synthetic keystroke failure."; return false; }
    if (state.pasteMode == Fixture::PasteMode::Ignore) return true;
    const HWND focus = state.host.focused();
    DWORD_PTR result = 0;
    SendMessageTimeoutW(focus, EM_REPLACESEL, TRUE, reinterpret_cast<LPARAM>(state.pastedText.c_str()),
                        SMTO_ABORTIFHUNG | SMTO_BLOCK, 2000, &result);
    if (state.pasteMode == Fixture::PasteMode::InsertThenUserCopies) state.clipboard.userWrites(L"user copied meanwhile");
    return true;
}

void blockingHook(void *) {
    Fixture &state = *fixture;
    if (++state.hookCalls == state.blockOnCall) WaitForSingleObject(state.release.value, 30000);
}

struct EnvironmentGuard {
    ~EnvironmentGuard() { resetEnvironment(); }
};

struct Target {
    JSTIInsertionTarget *value = nullptr;
    ~Target() { jsti_insertion_destroy(value); }
    void destroy() { jsti_insertion_destroy(value); value = nullptr; }
};

Environment testEnvironment(bool nativeDirectPath) {
    Environment environment = defaultEnvironment();
    environment.foregroundWindow = &fakeForeground;
    environment.clipboard = &fakeClipboard;
    environment.sendPaste = &stubSendPaste;
    environment.sleep = &shortSleep;
    environment.focusedElement = &elementFromCapturedHandle;
    environment.allowCurrentProcess = true;
    environment.nativeDirectPath = nativeDirectPath;
    environment.insertTimeoutMs = 8000;
    environment.verifyTimeoutMs = 2000;
    environment.verifyIntervalMs = 10;
    environment.unverifiedSettleMs = 0;
    environment.destroyWaitMs = 3000;
    environment.providerTimeoutMs = 2000;
    return environment;
}

// ---- helpers -------------------------------------------------------------------

std::wstring textOf(HWND control) {
    const int length = GetWindowTextLengthW(control);
    std::wstring text(static_cast<size_t>(length) + 1, L'\0');
    const int copied = GetWindowTextW(control, &text[0], length + 1);
    text.resize(static_cast<size_t>(std::max(copied, 0)));
    return text;
}

void setText(HWND control, const wchar_t *text) { SendMessageW(control, WM_SETTEXT, 0, reinterpret_cast<LPARAM>(text)); }
void select(HWND control, int start, int end) { SendMessageW(control, EM_SETSEL, static_cast<WPARAM>(start), static_cast<LPARAM>(end)); }

std::string describe(const char *step, const char *problem, const char *detail = "") {
    return std::string(step) + ": " + problem + (detail && *detail ? std::string(" (") + detail + ")" : std::string());
}

bool contains(const char *text, const char *needle) { return std::string(text ? text : "").find(needle) != std::string::npos; }

struct Attempt {
    int status = -1;
    JSTIInsertionResult result{};
    char error[512]{};
};

Attempt insert(Target &target, const char *text, unsigned flags = 0) {
    Attempt attempt;
    attempt.status = jsti_insertion_insert(target.value, text, flags, &attempt.result, attempt.error, sizeof(attempt.error));
    return attempt;
}

bool capture(Target &target, std::string &error) {
    char buffer[512]{};
    target.destroy();
    target.value = jsti_insertion_capture(buffer, sizeof(buffer));
    if (!target.value) error = buffer;
    return target.value != nullptr;
}

// 1 when the control exposes the Text pattern, 0 when it does not, -1 when
// the probe itself could not run on this thread.
int supportsTextPattern(HWND control) {
    const HRESULT initialised = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(initialised) && initialised != RPC_E_CHANGED_MODE) return -1;
    int supported = -1;
    {
        jsti::COM<IUIAutomation> automation;
        jsti::COM<IUIAutomationElement> element;
        jsti::COM<IUnknown> pattern;
        if (SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_IUIAutomation,
                                       reinterpret_cast<void **>(&automation.value))) && automation.value &&
            SUCCEEDED(automation->ElementFromHandle(control, &element.value)) && element.value) {
            supported = SUCCEEDED(element->GetCurrentPattern(UIA_TextPatternId, &pattern.value)) && pattern.value ? 1 : 0;
        }
    }
    if (SUCCEEDED(initialised)) CoUninitialize();
    return supported;
}

// ---- steps ---------------------------------------------------------------------

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
    jsti_insertion_destroy(nullptr);
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

std::string checkAutomationPaths(Fixture &state) {
    SyntheticHost &host = state.host;
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
    if (attempt.status != -1 || !contains(attempt.error, "changed") || textOf(host.edit) != L"Hello dear world" ||
        textOf(host.second) != L"other" || state.pasteCalls.load() != 1) {
        return describe("uia identity", "a different focused element was not rejected", attempt.error);
    }
    // A sibling control that is not inside the captured focus window is
    // rejected by the window check before any pattern is consulted.
    if (!capture(target, error)) return describe("uia sibling", "capture failed", error.c_str());
    state.resolveOverride = host.second;
    attempt = insert(target, "late");
    state.resolveOverride = nullptr;
    if (attempt.status != -1 || !contains(attempt.error, "no longer focused") || textOf(host.second) != L"other" ||
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
    if (attempt.status != 0 || textOf(host.edit) != L"new" ||
        (attempt.result.method != JSTI_INSERTION_METHOD_UIA_VALUE && attempt.result.method != JSTI_INSERTION_METHOD_PASTE) ||
        (attempt.result.method == JSTI_INSERTION_METHOD_UIA_VALUE && textPattern == 0) ||
        (attempt.result.method == JSTI_INSERTION_METHOD_PASTE && attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_RESTORED) ||
        state.clipboard.unicodeText() != L"previous text") {
        return describe("uia selection", "replacing a full selection did not keep insertion semantics", attempt.error);
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

    // 16. Keep the transcript on the clipboard.
    if (!capture(target, error)) return describe("keep clipboard", "capture failed", error.c_str());
    attempt = insert(target, " there", JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD);
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_PASTE ||
        attempt.result.clipboard != JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT || state.clipboard.unicodeText() != L" there" ||
        textOf(host.edit) != L"Hello there") {
        return describe("keep clipboard", "the transcript was not left on the clipboard", attempt.error);
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
    if (attempt.status != -1 || !contains(attempt.error, "already in progress")) {
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
    attempt = insert(target, "!");
    if (attempt.status != 0 || attempt.result.method != JSTI_INSERTION_METHOD_NATIVE_EDIT || textOf(host.edit) != L"Hello!") {
        return describe("native during capture", "native insertion waited on the background capture", attempt.error);
    }
    SetEvent(state.release.value);
    target.destroy();
    if (!waitForWorkersToExit(10000) || liveWorkerCount() != 0) return describe("native during capture", "workers leaked");
    return {};
}

} // namespace

int jsti_text_output_self_test(char *error, size_t capacity) {
    std::lock_guard<std::mutex> lock(selfTestMutex);
    std::string failure = checkPureHelpers();
    if (!failure.empty()) return jsti::fail(failure, error, capacity);
    try {
        auto state = std::make_unique<Fixture>();
        fixture = state.get();
        EnvironmentGuard environmentGuard;
        if (!state->host.start(failure)) { fixture = nullptr; return jsti::fail(failure, error, capacity); }
        state->foreground = state->host.window;
        failure = checkNativePaths(*state);
        if (failure.empty()) failure = checkAutomationPaths(*state);
        if (failure.empty()) failure = checkLifetimes(*state);
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
