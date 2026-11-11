// Shared fixture for the text output self-test files: a synthetic host window on
// a helper UI thread, an in-memory clipboard, the adapter's environment seams and
// small helpers. Nothing here sends real input or touches the user's clipboard.
#pragma once

#include "CWindowsSelfTest.h"
#include "CWindowsSupport.h"
#include "../CWindowsSupport/WindowsSupportInternal.hpp"
#include "../CWindowsSupport/WindowsTextOutputInternal.hpp"
#include <richedit.h>
#include <atomic>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace jsti::textoutput::selftest {
using namespace jsti::textoutput;

inline std::mutex selfTestMutex;

// ---- synthetic host ------------------------------------------------------------

constexpr UINT taskMessage = WM_APP + 41;
struct Task {
    void (*function)(void *);
    void *context;
};

inline LRESULT CALLBACK hostProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
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
    int closes = 0;
    int changeOnOpen = 0;
    int changeOnClose = 0;
    bool failUnicodeSet = false;
    void replaceLocked(const std::wstring &text) {
        items.clear();
        const auto *bytes = reinterpret_cast<const uint8_t *>(text.c_str());
        items[CF_UNICODETEXT].assign(bytes, bytes + (text.size() + 1) * sizeof(wchar_t));
        ++sequenceNumber;
    }

    bool open(HWND) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (isOpen) return false;
        isOpen = true;
        if (++opens == changeOnOpen) replaceLocked(L"new copy at acquisition");
        return true;
    }
    void close() override {
        std::lock_guard<std::mutex> lock(mutex);
        for (HGLOBAL handle : borrowed) GlobalFree(handle);
        borrowed.clear();
        isOpen = false;
        if (++closes == changeOnClose) replaceLocked(L"new copy after close");
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
        if (format == CF_UNICODETEXT && failUnicodeSet) { failUnicodeSet = false; return false; }
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
    enum class PasteMode { Insert, Fail, Ignore, InsertThenUserCopies, Partial, BlockAfterInsert } pasteMode = PasteMode::Insert;
    enum class PrepareMode { Ready, Cancel, MoveFocus } prepareMode = PrepareMode::Ready;
    JSTIInsertionTarget *pendingTarget = nullptr;
    bool failFocusResolution = false;
    std::atomic<int> pasteCalls{0};
    std::atomic<uint64_t> focusRevision{1};
    std::atomic<unsigned> releasedKeys{0};
    bool markersSeen = false;
    bool switchForegroundIsOwn = false;
    bool switchForegroundSameApp = false;
    std::wstring pastedText;
    // Blocking hook for timeout/lifetime checks.
    jsti::Handle release;
    std::atomic<int> hookCalls{0};
    int blockOnCall = 0;
};
inline Fixture *fixture = nullptr;

inline HWND fakeForeground() { return fixture->foreground; }
inline bool fakeOwnApplication(HWND) { return fixture->switchForegroundIsOwn; }
inline bool fakeSameApplication(HWND first, HWND second) { return first == second || fixture->switchForegroundSameApp; }
inline void switchAgainBeforeRedirect(void *) {
    fixture->foreground = fixture->host.window;
    ++fixture->focusRevision;
}
inline void changeRevisionBeforeRedirect(void *) { ++fixture->focusRevision; }
inline void cancelBeforeRedirect(void *) { jsti_insertion_cancel(fixture->pendingTarget); }
inline Clipboard *fakeClipboard() { return &fixture->clipboard; }
inline bool stubPreparePaste(std::string &) {
    if (fixture->prepareMode == Fixture::PrepareMode::Cancel) jsti_insertion_cancel(fixture->pendingTarget);
    if (fixture->prepareMode == Fixture::PrepareMode::MoveFocus) fixture->foreground = GetDesktopWindow();
    return true;
}
inline void stubReleasePasteKeys(unsigned count) { fixture->releasedKeys = count; }
inline uint64_t fakeFocusRevision() { return fixture->focusRevision.load(); }
inline bool fakeCaptureFocusEvent(FocusEvent &event) {
    event = FocusEvent{fixture->host.focused(), fixture->host.threadID, OBJID_CLIENT, 0, fixture->focusRevision.load()};
    return event.window != nullptr;
}
inline HRESULT fakeResolveFocusEvent(IUIAutomation *automation, const FocusEvent &event, IUIAutomationElement **element) {
    return fixture->failFocusResolution ? E_FAIL : automation->ElementFromHandle(event.window, element);
}
inline void shortSleep(DWORD milliseconds) { Sleep(std::min<DWORD>(milliseconds, 10)); }

inline HRESULT elementFromCapturedHandle(IUIAutomation *automation, HWND focus, IUIAutomationElement **element) {
    if (fixture->failFocusResolution) return E_FAIL;
    const HWND handle = fixture->resolveOverride ? fixture->resolveOverride : focus;
    return automation->ElementFromHandle(handle, element);
}

// Emulates the target application's paste handler: read the clipboard the
// adapter prepared and insert it at the focused control's selection.
inline unsigned stubSendPaste(std::string &error) {
    Fixture &state = *fixture;
    ++state.pasteCalls;
    state.markersSeen = state.clipboard.has(excludeFromMonitoringFormat()) &&
        state.clipboard.has(excludeFromHistoryFormat()) && state.clipboard.has(excludeFromCloudFormat());
    state.pastedText = state.clipboard.unicodeText();
    if (state.pasteMode == Fixture::PasteMode::Fail) { error = "Synthetic keystroke failure."; return 0; }
    if (state.pasteMode == Fixture::PasteMode::Ignore) return 4;
    if (state.pasteMode == Fixture::PasteMode::Partial) { error = "Synthetic partial shortcut."; return 2; }
    const HWND focus = state.host.focused();
    DWORD_PTR result = 0;
    SendMessageTimeoutW(focus, EM_REPLACESEL, TRUE, reinterpret_cast<LPARAM>(state.pastedText.c_str()),
                        SMTO_ABORTIFHUNG | SMTO_BLOCK, 2000, &result);
    if (state.pasteMode == Fixture::PasteMode::InsertThenUserCopies) state.clipboard.userWrites(L"user copied meanwhile");
    if (state.pasteMode == Fixture::PasteMode::BlockAfterInsert) WaitForSingleObject(state.release.value, 30000);
    return 4;
}

inline bool waitForHook(int count) {
    const ULONGLONG deadline = GetTickCount64() + 3000;
    while (fixture->hookCalls < count && GetTickCount64() < deadline) Sleep(1);
    return fixture->hookCalls >= count;
}

inline void blockingHook(void *) {
    Fixture &state = *fixture;
    const int call = ++state.hookCalls;
    if (state.blockOnCall < 0 || call == state.blockOnCall) WaitForSingleObject(state.release.value, 30000);
}

struct EnvironmentGuard {
    ~EnvironmentGuard() { resetEnvironment(); }
};

struct Target {
    JSTIInsertionTarget *value = nullptr;
    ~Target() { jsti_insertion_destroy(value); }
    void destroy() { jsti_insertion_destroy(value); value = nullptr; }
};

inline Environment testEnvironment(bool nativeDirectPath) {
    Environment environment = defaultEnvironment();
    environment.foregroundWindow = &fakeForeground;
    environment.clipboard = &fakeClipboard;
    environment.sendPaste = &stubSendPaste;
    environment.preparePaste = &stubPreparePaste;
    environment.releasePasteKeys = &stubReleasePasteKeys;
    environment.focusRevision = &fakeFocusRevision;
    environment.captureFocusEvent = &fakeCaptureFocusEvent;
    environment.resolveFocusEvent = &fakeResolveFocusEvent;
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

inline std::wstring textOf(HWND control) {
    const int length = GetWindowTextLengthW(control);
    std::wstring text(static_cast<size_t>(length) + 1, L'\0');
    const int copied = GetWindowTextW(control, &text[0], length + 1);
    text.resize(static_cast<size_t>(std::max(copied, 0)));
    return text;
}

inline void setText(HWND control, const wchar_t *text) { SendMessageW(control, WM_SETTEXT, 0, reinterpret_cast<LPARAM>(text)); }
inline void select(HWND control, int start, int end) { SendMessageW(control, EM_SETSEL, static_cast<WPARAM>(start), static_cast<LPARAM>(end)); }

inline std::string describe(const char *step, const char *problem, const char *detail = "") {
    return std::string(step) + ": " + problem + (detail && *detail ? std::string(" (") + detail + ")" : std::string());
}

inline bool contains(const char *text, const char *needle) { return std::string(text ? text : "").find(needle) != std::string::npos; }

struct Attempt {
    int status = -1;
    JSTIInsertionResult result{};
    char error[512]{};
};

inline Attempt insert(Target &target, const char *text, unsigned flags = 0) {
    Attempt attempt;
    attempt.status = jsti_insertion_insert(target.value, text, flags, &attempt.result, attempt.error, sizeof(attempt.error));
    return attempt;
}

inline bool capture(Target &target, std::string &error) {
    char buffer[512]{};
    target.destroy();
    target.value = jsti_insertion_capture(buffer, sizeof(buffer));
    if (!target.value) error = buffer;
    return target.value != nullptr;
}

// 1 when the control exposes the Text pattern, 0 when it does not, -1 when
// the probe itself could not run on this thread.
inline int supportsTextPattern(HWND control) {
    const HRESULT initialised = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(initialised) && initialised != RPC_E_CHANGED_MODE) return -1;
    int supported = -1;
    {
        jsti::COM<IUIAutomation> automation;
        jsti::COM<IUIAutomation2> modern;
        jsti::COM<IUIAutomationElement> element;
        jsti::COM<IUnknown> pattern;
        // Match the production worker's client/proxy generation. A legacy
        // CUIAutomation capability probe cannot constrain CUIAutomation8.
        if (SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_IUIAutomation2,
                                       reinterpret_cast<void **>(&modern.value))) && modern.value) {
            modern.value->QueryInterface(IID_IUIAutomation, reinterpret_cast<void **>(&automation.value));
        } else {
            CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_IUIAutomation,
                             reinterpret_cast<void **>(&automation.value));
        }
        if (automation.value && SUCCEEDED(automation->ElementFromHandle(control, &element.value)) && element.value) {
            supported = SUCCEEDED(element->GetCurrentPattern(UIA_TextPatternId, &pattern.value)) && pattern.value ? 1 : 0;
        }
    }
    if (SUCCEEDED(initialised)) CoUninitialize();
    return supported;
}

// ---- steps (one file each group) -------------------------------------------------

std::string checkSelectionRangeBudget();
std::string checkPureHelpers();
std::string checkAppSwitchPolicies(Fixture &state);
std::string checkNativePaths(Fixture &state);
std::string checkAutomationPaths(Fixture &state);
std::string checkLifetimes(Fixture &state);
std::string checkClipboardRacesAndCancellation(Fixture &state);
std::string checkCapturedProcessAndWorkerBounds(Fixture &state);
std::string checkDeferredFocusAndUncertainTimeout(Fixture &state);
std::string checkCorrectionLearning(Fixture &state);
std::string checkSelectionSources(Fixture &state);
std::string checkVoiceEditAnchors(Fixture &state);

} // namespace jsti::textoutput::selftest
