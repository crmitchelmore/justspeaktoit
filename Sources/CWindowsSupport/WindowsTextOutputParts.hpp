// Private to the text-output translation units (WindowsTextOutput*.cpp): the
// types, messages and helpers more than one of them uses. Never part of the C ABI.
#pragma once
#include "include/CWindowsSupport.h"
#include "WindowsTextOutputInternal.hpp"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace jsti::textoutput {

constexpr const char *noFieldMessage =
    "No external text field is focused. The transcript will remain available to copy.";
constexpr const char *movedMessage = "The original text field is no longer focused. Copy the transcript instead.";
constexpr const char *changedMessage =
    "The focused field changed since recording started. Copy the transcript instead.";
constexpr const char *unsupportedMessage =
    "This application does not expose a supported editable text field. Copy the transcript instead.";
constexpr const char *passwordMessage = "The focused field is a password field; automatic insertion is refused.";
constexpr const char *readOnlyMessage = "The focused field is read-only; automatic insertion is refused.";
constexpr const char *disabledMessage = "The focused field is disabled; automatic insertion is refused.";
constexpr const char *privilegeMessage =
    "The target application runs with higher privileges than Just Speak to It, so Windows blocks input into it. "
    "Copy the transcript instead.";
constexpr const char *timeoutMessage =
    "Automatic insertion timed out waiting for the target application. Copy the transcript instead.";

template<class T> struct Ref {
    T *value = nullptr;
    Ref() = default;
    Ref(const Ref &) = delete;
    Ref &operator=(const Ref &) = delete;
    ~Ref() { reset(); }
    T *operator->() const { return value; }
    explicit operator bool() const { return value != nullptr; }
    T **put() { reset(); return &value; }
    void reset() { if (value) { value->Release(); value = nullptr; } }
    void retain(T *other) { reset(); value = other; if (value) value->AddRef(); }
};

struct BStr {
    BSTR value = nullptr;
    ~BStr() { if (value) SysFreeString(value); }
    std::wstring str() const { return value ? std::wstring(value, SysStringLen(value)) : std::wstring(); }
};

// Message-only window used as the clipboard owner; a real HWND is required
// for EmptyClipboard ownership before SetClipboardData.
struct OwnerWindow {
    HWND handle = nullptr;
    DWORD error = ERROR_SUCCESS;
    OwnerWindow() {
        handle = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                 GetModuleHandleW(nullptr), nullptr);
        if (!handle) error = GetLastError();
    }
    ~OwnerWindow() { if (handle) DestroyWindow(handle); }
    OwnerWindow(const OwnerWindow &) = delete;
    OwnerWindow &operator=(const OwnerWindow &) = delete;
};

unsigned realSendPaste(std::string &error);
bool prepareRealPaste(std::string &error);
void releaseRealPasteKeys(unsigned sent);
Clipboard *systemClipboard();

// ---- worker accounting -------------------------------------------------------

// The live-worker count is private to WindowsTextOutput.cpp, which reserves a
// slot before it creates a worker thread. Releasing it wakes waitForWorkersToExit.
void releaseWorker();

struct WorkerScope {
    WorkerScope() = default; // Slot was reserved before the thread was created.
    ~WorkerScope() { releaseWorker(); }
    WorkerScope(const WorkerScope &) = delete;
    WorkerScope &operator=(const WorkerScope &) = delete;
};

struct ClipboardItem {
    UINT format = 0;
    std::vector<uint8_t> bytes;
};
struct ClipboardSnapshot {
    std::vector<ClipboardItem> items;
    bool complete = true;
};
bool placeText(Clipboard &clipboard, HWND owner, const std::wstring &text, bool excludeFromHistory,
               DWORD &sequenceAfter, std::string &error, ClipboardSnapshot *replaced = nullptr, int *failureState = nullptr,
               const std::function<bool()> &mayWrite = {});

int restoreClipboard(Clipboard &clipboard, HWND owner, const ClipboardSnapshot &snapshot, DWORD expectedSequence);

// UIPI silently drops SendInput and rejects window messages sent to a higher
// integrity process. Fail closed when that is certain; an undeterminable
// level is allowed through and reported by the operation itself.
bool integrityAllows(DWORD processID, std::string &error);

// ---- identity and native controls ---------------------------------------------

struct Identity {
    HWND window = nullptr;
    HWND focus = nullptr;
    DWORD process = 0;
    DWORD thread = 0;
};

bool captureIdentity(const Environment &environment, Identity &identity, std::string &error);

bool ownApplication(HWND window);

constexpr unsigned redirectedFocusFence = 1u << 6;

bool sameApplication(HWND first, HWND second);

bool verifyIdentity(const Environment &environment, const Identity &identity, std::string &error,
                    bool backgroundNative = false);

enum class NativeKind { NotNative, Editable, Password, ReadOnly, Disabled };

NativeKind classifyNative(HWND focus);

const char *refusal(NativeKind kind);

// EM_REPLACESEL is sent to the captured HWND, never to whichever application
// receives global keyboard input. Verification uses the packed EM_GETSEL
// result: the caret must land after the former selection start and at most
// one UTF-16 unit per inserted unit later (RichEdit folds CRLF).
bool nativeReplaceSelection(HWND focus, const std::wstring &text, bool replaceField, bool &verified, std::string &error,
                            const std::function<bool()> &mayMutate = {}, DWORD *learningCaret = nullptr);

// ---- UI Automation -------------------------------------------------------------

struct Patterns {
    Ref<IUIAutomationValuePattern> value;
    Ref<IUIAutomationTextPattern> text;
};

void fetchPatterns(IUIAutomationElement *element, Patterns &patterns);

struct Facts {
    CONTROLTYPEID type = 0;
    bool password = false;
    bool enabled = false;
    bool readOnly = true;
    bool passwordKnown = false;
    bool enabledKnown = false;
    bool readOnlyKnown = false;
};

Facts inspect(IUIAutomationElement *element, const Patterns &patterns);

bool editable(const Facts &facts, const Patterns &patterns);

bool elementBelongs(IUIAutomation *automation, IUIAutomationElement *element, const Identity &identity);

bool wholeDocumentSelected(IUIAutomationTextPattern *text);

// Reads the field through the Value pattern, else the whole document text
// (bounded). readable stays false when neither is available.
bool readField(const Patterns &patterns, std::wstring &content, bool &readable);

size_t occurrences(const std::wstring &haystack, const std::wstring &needle);

std::string automationError(const char *operation, HRESULT code);

// ---- target state and worker -------------------------------------------------

struct State {
    Environment environment;
    Identity identity;
    std::mutex mutex;
    std::condition_variable changed;
    bool shutdown = false;
    bool readOnlyTarget = false;
    bool voiceEditTarget = false;
    bool selectionRequested = false;
    bool selectionStarted = false;
    bool selectionFinished = false;
    bool selectionDelivered = false;
    ULONGLONG selectionDeadline = 0;
    std::wstring selectionText;
    std::string selectionError;
    int selectionStatus = -1;
    bool insertRequested = false;
    bool insertBusy = false;
    bool insertFinished = false;
    bool abandoned = false;
    bool mutationStarted = false;
    bool learningRequested = false;
    bool learningFinished = false;
    bool learningCapture = false;
    bool learningAcknowledged = false;
    bool learningStarted = false;
    bool learningWholeField = false;
    DWORD learningCaret = static_cast<DWORD>(-1);
    std::wstring learningInserted;
    std::wstring learningText;
    std::string learningError;
    int learningStatus = -1;
    uint64_t focusRevision = 0;
    FocusEvent focusEvent;
    jsti::Handle process;
    std::shared_ptr<State> redirectedOutput;
    std::weak_ptr<State> deliveryOwner;
    bool requiresDeliveryOwner = false;
    std::wstring text;
    unsigned flags = 0;
    JSTIInsertionResult result{};
    std::string error;
    int status = -1;
    jsti::Handle exited;
};

bool deliveryOwnerAvailable(const State &state, std::string &error);

void runInsertionWorker(std::shared_ptr<State> state);

} // namespace jsti::textoutput

struct JSTIInsertionTarget {
    std::shared_ptr<jsti::textoutput::State> state;
    std::thread worker;
};
