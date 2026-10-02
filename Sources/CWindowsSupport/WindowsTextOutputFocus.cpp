#include "WindowsTextOutputInternal.hpp"
#include <atomic>
#include <oleacc.h>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace jsti::textoutput {
namespace {
// One bounded OS-event observer, without UI Automation calls or field content.
// A target becomes stale on any focus transition, including transitions between
// virtual controls sharing an HWND. Provider latency cannot hide that transition.
std::atomic<uint64_t> focusRevision{1};
std::mutex focusEventMutex;
FocusEvent lastFocusEvent;
void CALLBACK focusChanged(HWINEVENTHOOK, DWORD event, HWND window, LONG object, LONG child, DWORD thread, DWORD) {
    std::lock_guard<std::mutex> lock(focusEventMutex);
    const uint64_t revision = focusRevision.fetch_add(1, std::memory_order_relaxed) + 1;
    lastFocusEvent = event == EVENT_OBJECT_FOCUS ? FocusEvent{window, thread, object, child, revision} : FocusEvent{};
}
struct FocusObserver {
    std::mutex mutex;
    std::condition_variable changed;
    std::thread worker;
    DWORD threadID = 0;
    bool ready = false;
    bool available = false;
    FocusObserver() : worker([this] { run(); }) {}
    ~FocusObserver() {
        DWORD identifier;
        { std::unique_lock<std::mutex> lock(mutex); changed.wait(lock, [&] { return ready; }); identifier = threadID; }
        if (identifier) PostThreadMessageW(identifier, WM_QUIT, 0, 0);
        if (worker.joinable()) worker.join();
    }
    void run() {
        MSG message{};
        PeekMessageW(&message, nullptr, 0, 0, PM_NOREMOVE);
        const HWINEVENTHOOK focus = SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS,
                                                   nullptr, focusChanged, 0, 0, WINEVENT_OUTOFCONTEXT);
        const HWINEVENTHOOK foreground = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
                                                        nullptr, focusChanged, 0, 0, WINEVENT_OUTOFCONTEXT);
        {
            std::lock_guard<std::mutex> lock(mutex);
            threadID = GetCurrentThreadId();
            available = focus && foreground;
            ready = true;
        }
        changed.notify_all();
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if (focus) UnhookWinEvent(focus);
        if (foreground) UnhookWinEvent(foreground);
    }
    uint64_t revision() {
        std::unique_lock<std::mutex> lock(mutex);
        if (!changed.wait_for(lock, std::chrono::milliseconds(100), [&] { return ready; }) || !available) return 0;
        return focusRevision.load(std::memory_order_relaxed);
    }
};
FocusObserver &focusObserver() { static FocusObserver observer; return observer; }
}
uint64_t observedFocusRevision() {
    try { return focusObserver().revision(); }
    catch (...) { return 0; }
}
bool observedFocusEvent(FocusEvent &event) {
    if (!observedFocusRevision()) return false;
    std::lock_guard<std::mutex> lock(focusEventMutex);
    event = lastFocusEvent;
    return event.window && event.revision != 0;
}
HRESULT resolveObservedFocusEvent(IUIAutomation *automation, const FocusEvent &event, IUIAutomationElement **element) {
    *element = nullptr;
    jsti::COM<IAccessible> accessible;
    VARIANT child;
    VariantInit(&child);
    const HRESULT resolved = AccessibleObjectFromEvent(event.window, static_cast<DWORD>(event.object),
                                                       static_cast<DWORD>(event.child), &accessible.value, &child);
    HRESULT result = E_FAIL;
    if (SUCCEEDED(resolved) && accessible.value && child.vt == VT_I4) {
        result = automation->ElementFromIAccessible(accessible.value, child.lVal, element);
    }
    VariantClear(&child);
    return result;
}
} // namespace jsti::textoutput
