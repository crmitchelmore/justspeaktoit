#pragma once

// Internal seams shared by the insertion adapter and its native self-test.
// Production always uses the real Win32/UI Automation implementations; the
// self-test injects synthetic hidden windows, an in-memory clipboard and a
// keystroke stub so no test ever reaches the user's desktop or clipboard.
#include "WindowsSupportInternal.hpp"
#include <uiautomationclient.h>
#include <cstdint>
#include <string>
#include <vector>

namespace jsti::textoutput {

// Clipboard access used by the guarded paste path. Handles returned by get are
// borrowed while the clipboard is open; set takes ownership of an HGLOBAL on
// success, matching SetClipboardData.
struct Clipboard {
    virtual ~Clipboard() = default;
    virtual bool open(HWND owner) = 0;
    virtual void close() = 0;
    virtual bool empty() = 0;
    virtual UINT next(UINT format) = 0;
    virtual HANDLE get(UINT format) = 0;
    virtual bool set(UINT format, HGLOBAL data) = 0;
    virtual DWORD sequence() = 0;
};

struct FocusEvent {
    HWND window = nullptr;
    DWORD thread = 0;
    LONG object = 0;
    LONG child = 0;
    uint64_t revision = 0;
};

struct Environment {
    HWND (*foregroundWindow)() = nullptr;
    Clipboard *(*clipboard)() = nullptr;
    // Delivers Ctrl+V to the foreground thread; production uses SendInput.
    unsigned (*sendPaste)(std::string &error) = nullptr;
    bool (*preparePaste)(std::string &error) = nullptr;
    void (*releasePasteKeys)(unsigned sent) = nullptr;
    uint64_t (*focusRevision)() = nullptr;
    bool (*captureFocusEvent)(FocusEvent &event) = nullptr;
    HRESULT (*resolveFocusEvent)(IUIAutomation *automation, const FocusEvent &event,
                                 IUIAutomationElement **element) = nullptr;
    void (*sleep)(DWORD milliseconds) = nullptr;
    // Resolves the focused UI Automation element for the captured control.
    // Production uses IUIAutomation::GetFocusedElement (foreground-thread
    // focus); the self-test maps the captured HWND directly because CI has no
    // reliable foreground window.
    HRESULT (*focusedElement)(IUIAutomation *automation, HWND focus, IUIAutomationElement **element) = nullptr;
    // Optional hook run on the worker before any provider call; may block so
    // timeouts and detached cleanup can be exercised deterministically.
    void (*beforeAutomation)(void *context) = nullptr;
    void *hookContext = nullptr;
    bool allowCurrentProcess = false;
    // When false, captured controls are never classified as native, so every
    // decision (including password/read-only refusal) goes through UI
    // Automation. Self-test only.
    bool nativeDirectPath = true;
    DWORD insertTimeoutMs = 6000;
    DWORD captureWaitMs = 2000;
    DWORD verifyTimeoutMs = 1500;
    DWORD verifyIntervalMs = 50;
    DWORD unverifiedSettleMs = 400;
    DWORD destroyWaitMs = 0; // Detached state remains owned by a globally bounded worker.
    DWORD providerTimeoutMs = 2000;
};

uint64_t observedFocusRevision();
bool observedFocusEvent(FocusEvent &event);
HRESULT resolveObservedFocusEvent(IUIAutomation *automation, const FocusEvent &event, IUIAutomationElement **element);
Environment defaultEnvironment();
// Self-test only. Copied into each target at capture, so a running target is
// never affected by a later change.
void setEnvironment(const Environment &environment);
void resetEnvironment();

// Pure helpers exposed for deterministic checks.
void pasteInputs(INPUT (&inputs)[4]);
std::wstring normalizedForComparison(const std::wstring &text);
bool containsNormalized(const std::wstring &haystack, const std::wstring &needle);
// Number of insertion workers that have started and not yet exited, and a
// bounded wait for that number to reach zero.
size_t liveWorkerCount();
bool waitForWorkersToExit(DWORD timeoutMs);
// Formats placed next to a transient paste so Windows clipboard history and
// cloud sync skip the transcript. Registered on first use.
UINT excludeFromMonitoringFormat();
UINT excludeFromHistoryFormat();
UINT excludeFromCloudFormat();

} // namespace jsti::textoutput
