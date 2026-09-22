#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
// UI Automation GUIDs are defined in this translation unit (selectany) so the
// link never depends on which interface identifiers an import library ships.
#include <initguid.h>
#include "WindowsTextOutputInternal.hpp"
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

// ---- environment -----------------------------------------------------------

HWND realForeground() { return GetForegroundWindow(); }
void realSleep(DWORD milliseconds) { Sleep(milliseconds); }
HRESULT realFocusedElement(IUIAutomation *automation, HWND, IUIAutomationElement **element) {
    return automation->GetFocusedElement(element);
}
unsigned realSendPaste(std::string &error);
bool prepareRealPaste(std::string &error);
void releaseRealPasteKeys(unsigned sent);
Clipboard *systemClipboard();

std::mutex environmentMutex;
Environment overriddenEnvironment;
bool environmentOverridden = false;

Environment currentEnvironment() {
    std::lock_guard<std::mutex> lock(environmentMutex);
    return environmentOverridden ? overriddenEnvironment : defaultEnvironment();
}

// ---- worker accounting -------------------------------------------------------

std::mutex workerMutex;
std::condition_variable workerChanged;
size_t liveWorkers = 0;

struct WorkerScope {
    WorkerScope() = default; // Slot was reserved before the thread was created.
    ~WorkerScope() {
        { std::lock_guard<std::mutex> lock(workerMutex); --liveWorkers; }
        workerChanged.notify_all();
    }
};

bool reserveWorker() {
    std::lock_guard<std::mutex> lock(workerMutex);
    if (liveWorkers >= 4) return false;
    ++liveWorkers;
    return true;
}

// ---- clipboard ---------------------------------------------------------------

struct SystemClipboard final : Clipboard {
    bool open(HWND owner) override {
        for (int attempt = 0; attempt < 10; ++attempt) {
            if (OpenClipboard(owner)) return true;
            Sleep(20);
        }
        return false;
    }
    void close() override { CloseClipboard(); }
    bool empty() override { return EmptyClipboard() != FALSE; }
    UINT next(UINT format) override { return EnumClipboardFormats(format); }
    HANDLE get(UINT format) override { return GetClipboardData(format); }
    bool set(UINT format, HGLOBAL data) override { return SetClipboardData(format, data) != nullptr; }
    DWORD sequence() override { return GetClipboardSequenceNumber(); }
};

Clipboard *systemClipboard() {
    static SystemClipboard clipboard;
    return &clipboard;
}

struct ClipboardItem {
    UINT format = 0;
    std::vector<uint8_t> bytes;
};
struct ClipboardSnapshot {
    std::vector<ClipboardItem> items;
    bool complete = true;
};
constexpr size_t formatByteLimit = size_t(16) << 20;
constexpr size_t totalByteLimit = size_t(32) << 20;
constexpr size_t formatCountLimit = 64;

HGLOBAL globalBytes(const void *data, size_t size) {
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
    if (!memory) return nullptr;
    void *destination = GlobalLock(memory);
    if (!destination) { GlobalFree(memory); return nullptr; }
    std::memcpy(destination, data, size);
    GlobalUnlock(memory);
    return memory;
}

// Formats whose clipboard handle is not global memory, or which the system
// synthesizes from CF_UNICODETEXT, are not copied byte-wise.
bool preservableFormat(UINT format, bool unicodeTextPresent) {
    switch (format) {
    case CF_BITMAP: case CF_METAFILEPICT: case CF_PALETTE: case CF_ENHMETAFILE: case CF_OWNERDISPLAY:
    case CF_DSPBITMAP: case CF_DSPMETAFILEPICT: case CF_DSPENHMETAFILE:
        return false;
    case CF_TEXT: case CF_OEMTEXT: case CF_LOCALE:
        return !unicodeTextPresent;
    default:
        return !(format >= CF_PRIVATEFIRST && format <= CF_PRIVATELAST) &&
            !(format >= CF_GDIOBJFIRST && format <= CF_GDIOBJLAST);
    }
}

struct ClipboardClose {
    Clipboard &clipboard;
    ~ClipboardClose() { clipboard.close(); }
};

bool snapshotClipboard(Clipboard &clipboard, ClipboardSnapshot &snapshot, std::string &error) {
    (void)error; // Clipboard is already owned for the complete snapshot/replace transaction.
    bool unicodeText = false;
    for (UINT format = clipboard.next(0); format; format = clipboard.next(format)) {
        if (format == CF_UNICODETEXT) unicodeText = true;
    }
    size_t total = 0;
    for (UINT format = clipboard.next(0); format; format = clipboard.next(format)) {
        if (!preservableFormat(format, unicodeText)) {
            if (!(unicodeText && (format == CF_TEXT || format == CF_OEMTEXT || format == CF_LOCALE))) snapshot.complete = false;
            continue;
        }
        if (snapshot.items.size() >= formatCountLimit) { snapshot.complete = false; break; }
        const HANDLE handle = clipboard.get(format);
        if (!handle) { snapshot.complete = false; continue; }
        const SIZE_T size = GlobalSize(handle);
        if (!size || size > formatByteLimit || total + size > totalByteLimit) { snapshot.complete = false; continue; }
        const void *data = GlobalLock(handle);
        if (!data) { snapshot.complete = false; continue; }
        ClipboardItem item;
        item.format = format;
        item.bytes.assign(static_cast<const uint8_t *>(data), static_cast<const uint8_t *>(data) + size);
        GlobalUnlock(handle);
        total += size;
        snapshot.items.push_back(std::move(item));
    }
    return true;
}

int restoreOpenClipboard(Clipboard &clipboard, const ClipboardSnapshot &snapshot) {
    bool success = clipboard.empty();
    for (const ClipboardItem &item : snapshot.items) {
        if (!success) break;
        HGLOBAL memory = globalBytes(item.bytes.data(), item.bytes.size());
        if (!memory) { success = false; break; }
        if (!clipboard.set(item.format, memory)) { GlobalFree(memory); success = false; }
    }
    if (!success) return JSTI_INSERTION_CLIPBOARD_RESTORE_FAILED;
    return snapshot.complete ? JSTI_INSERTION_CLIPBOARD_RESTORED : JSTI_INSERTION_CLIPBOARD_RESTORED_PARTIALLY;
}

bool placeText(Clipboard &clipboard, HWND owner, const std::wstring &text, bool excludeFromHistory,
               DWORD &sequenceAfter, std::string &error, ClipboardSnapshot *replaced = nullptr, int *failureState = nullptr,
               const std::function<bool()> &mayWrite = {}) {
    HGLOBAL memory = globalBytes(text.c_str(), (text.size() + 1) * sizeof(wchar_t));
    if (!memory) { error = systemError("Allocating clipboard text"); return false; }
    if (!clipboard.open(owner)) {
        const DWORD code = GetLastError();
        GlobalFree(memory);
        error = systemError("Opening the clipboard", code);
        return false;
    }
    ClipboardClose close{clipboard};
    ClipboardSnapshot snapshot;
    if (!snapshotClipboard(clipboard, snapshot, error)) { GlobalFree(memory); return false; }
    if (mayWrite && !mayWrite()) {
        GlobalFree(memory);
        error = "The pending clipboard operation was cancelled.";
        return false;
    }
    if (!clipboard.empty()) {
        GlobalFree(memory);
        error = systemError("Preparing the clipboard");
        return false;
    }
    if (!clipboard.set(CF_UNICODETEXT, memory)) {
        GlobalFree(memory);
        error = systemError("Writing the clipboard");
        const int restored = restoreOpenClipboard(clipboard, snapshot);
        if (failureState) *failureState = restored;
        return false;
    }
    if (excludeFromHistory) {
        const UINT markers[] = {excludeFromMonitoringFormat(), excludeFromHistoryFormat(), excludeFromCloudFormat()};
        for (const UINT marker : markers) {
            if (!marker) continue;
            const DWORD zero = 0;
            HGLOBAL flag = globalBytes(&zero, sizeof(zero));
            if (flag && !clipboard.set(marker, flag)) GlobalFree(flag);
        }
    }
    // Capture our sequence while ownership is still held; a copy immediately
    // after CloseClipboard must never be mistaken for our own write.
    sequenceAfter = clipboard.sequence();
    if (replaced) *replaced = std::move(snapshot);
    return true;
}

int restoreClipboard(Clipboard &clipboard, HWND owner, const ClipboardSnapshot &snapshot, DWORD expectedSequence) {
    if (!clipboard.open(owner)) return JSTI_INSERTION_CLIPBOARD_RESTORE_FAILED;
    ClipboardClose close{clipboard};
    // OpenClipboard can wait. Check only after acquiring ownership, so a copy
    // during that wait is preserved rather than overwritten by stale data.
    if (clipboard.sequence() != expectedSequence) return JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE;
    return restoreOpenClipboard(clipboard, snapshot);
}

// ---- keyboard ----------------------------------------------------------------

bool modifiersHeld() {
    for (const int key : {VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN}) {
        if (GetAsyncKeyState(key) & 0x8000) return true;
    }
    return false;
}

bool prepareRealPaste(std::string &error) {
    for (int attempt = 0; attempt < 50 && modifiersHeld(); ++attempt) Sleep(20);
    if (modifiersHeld()) {
        error = "Shift, Alt or the Windows key is held down, so the paste shortcut was not sent. Copy the transcript instead.";
        return false;
    }
    return true;
}

unsigned realSendPaste(std::string &error) {
    INPUT inputs[4];
    pasteInputs(inputs);
    SetLastError(ERROR_SUCCESS);
    const unsigned sent = SendInput(4, inputs, sizeof(INPUT));
    if (sent != 4) error = systemError("Sending the paste shortcut");
    return sent;
}

void releaseRealPasteKeys(unsigned sent) {
    if (sent == 0 || sent >= 4) return;
    INPUT releases[2]{};
    unsigned count = 0;
    if (sent == 2) { releases[count].type = INPUT_KEYBOARD; releases[count].ki.wVk = 'V';
        releases[count++].ki.dwFlags = KEYEVENTF_KEYUP; }
    releases[count].type = INPUT_KEYBOARD; releases[count].ki.wVk = VK_CONTROL;
    releases[count++].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(count, releases, sizeof(INPUT));
}

// ---- integrity ---------------------------------------------------------------

bool integrityLevel(HANDLE process, DWORD &level) {
    jsti::Handle token;
    if (!OpenProcessToken(process, TOKEN_QUERY, &token.value)) return false;
    DWORD size = 0;
    GetTokenInformation(token.value, TokenIntegrityLevel, nullptr, 0, &size);
    if (!size) return false;
    std::vector<uint8_t> buffer(size);
    if (!GetTokenInformation(token.value, TokenIntegrityLevel, buffer.data(), size, &size)) return false;
    const PSID sid = reinterpret_cast<TOKEN_MANDATORY_LABEL *>(buffer.data())->Label.Sid;
    if (!sid || !IsValidSid(sid)) return false;
    const UCHAR count = *GetSidSubAuthorityCount(sid);
    if (!count) return false;
    level = *GetSidSubAuthority(sid, count - 1);
    return true;
}

// UIPI silently drops SendInput and rejects window messages sent to a higher
// integrity process. Fail closed when that is certain; an undeterminable
// level is allowed through and reported by the operation itself.
bool integrityAllows(DWORD processID, std::string &error) {
    DWORD ours = 0;
    if (!integrityLevel(GetCurrentProcess(), ours)) return true;
    jsti::Handle process;
    process.value = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processID);
    if (!process.value) {
        if (GetLastError() == ERROR_ACCESS_DENIED) { error = privilegeMessage; return false; }
        return true;
    }
    DWORD theirs = 0;
    if (!integrityLevel(process.value, theirs)) {
        if (GetLastError() == ERROR_ACCESS_DENIED) { error = privilegeMessage; return false; }
        return true;
    }
    if (theirs > ours) { error = privilegeMessage; return false; }
    return true;
}

// ---- identity and native controls ---------------------------------------------

struct Identity {
    HWND window = nullptr;
    HWND focus = nullptr;
    DWORD process = 0;
    DWORD thread = 0;
};

bool captureIdentity(const Environment &environment, Identity &identity, std::string &error) {
    const HWND window = environment.foregroundWindow();
    DWORD process = 0;
    const DWORD thread = window ? GetWindowThreadProcessId(window, &process) : 0;
    GUITHREADINFO info{};
    info.cbSize = sizeof(info);
    if (!window || !thread || (process == GetCurrentProcessId() && !environment.allowCurrentProcess) ||
        !GetGUIThreadInfo(thread, &info) || !info.hwndFocus) {
        error = noFieldMessage;
        return false;
    }
    identity.window = window;
    identity.focus = info.hwndFocus;
    identity.process = process;
    identity.thread = thread;
    return true;
}

bool verifyIdentity(const Environment &environment, const Identity &identity, std::string &error) {
    DWORD process = 0;
    const DWORD thread = GetWindowThreadProcessId(identity.focus, &process);
    GUITHREADINFO info{};
    info.cbSize = sizeof(info);
    if (!identity.window || !identity.focus || !IsWindow(identity.window) || !IsWindow(identity.focus) ||
        process != identity.process || thread != identity.thread ||
        environment.foregroundWindow() != identity.window || !GetGUIThreadInfo(thread, &info) ||
        info.hwndFocus != identity.focus || GetAncestor(identity.focus, GA_ROOT) != identity.window) {
        error = movedMessage;
        return false;
    }
    return true;
}

enum class NativeKind { NotNative, Editable, Password, ReadOnly, Disabled };

NativeKind classifyNative(HWND focus) {
    wchar_t className[128]{};
    GetClassNameW(focus, className, 128);
    static const wchar_t *const classes[] = {L"Edit", L"RichEdit20W", L"RICHEDIT50W", L"RICHEDIT60W", L"RichEditD2DPT"};
    bool native = false;
    for (const auto known : classes) if (_wcsicmp(className, known) == 0) { native = true; break; }
    // ANSI edit windows would receive lossy text; they use the guarded paste.
    if (!native || !IsWindowUnicode(focus)) return NativeKind::NotNative;
    const LONG_PTR style = GetWindowLongPtrW(focus, GWL_STYLE);
    if (style & ES_PASSWORD) return NativeKind::Password;
    if (style & ES_READONLY) return NativeKind::ReadOnly;
    if (!IsWindowEnabled(focus)) return NativeKind::Disabled;
    return NativeKind::Editable;
}

const char *refusal(NativeKind kind) {
    switch (kind) {
    case NativeKind::Password: return passwordMessage;
    case NativeKind::ReadOnly: return readOnlyMessage;
    case NativeKind::Disabled: return disabledMessage;
    default: return unsupportedMessage;
    }
}

// EM_REPLACESEL is sent to the captured HWND, never to whichever application
// receives global keyboard input. Verification uses the packed EM_GETSEL
// result: the caret must land after the former selection start and at most
// one UTF-16 unit per inserted unit later (RichEdit folds CRLF).
bool nativeReplaceSelection(HWND focus, const std::wstring &text, bool replaceField, bool &verified, std::string &error,
                            const std::function<bool()> &mayMutate = {}) {
    constexpr UINT flags = SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT;
    verified = false;
    DWORD_PTR ignored = 0;
    if (replaceField && mayMutate && !mayMutate()) return false;
    if (replaceField && !SendMessageTimeoutW(focus, EM_SETSEL, 0, static_cast<LPARAM>(-1), flags, 1000, &ignored)) {
        error = systemError("Selecting the original text field");
        return false;
    }
    DWORD_PTR before = 0;
    const bool haveBefore = SendMessageTimeoutW(focus, EM_GETSEL, 0, 0, flags, 1000, &before) != 0 &&
        static_cast<DWORD>(before) != static_cast<DWORD>(-1);
    DWORD_PTR result = 0;
    if (mayMutate && !mayMutate()) return false;
    SetLastError(ERROR_SUCCESS);
    if (!SendMessageTimeoutW(focus, EM_REPLACESEL, TRUE, reinterpret_cast<LPARAM>(text.c_str()), flags, 1000, &result)) {
        error = systemError("Inserting into the original text field");
        return false;
    }
    DWORD_PTR after = 0;
    if (haveBefore && SendMessageTimeoutW(focus, EM_GETSEL, 0, 0, flags, 1000, &after) &&
        static_cast<DWORD>(after) != static_cast<DWORD>(-1)) {
        const DWORD selectionStart = LOWORD(static_cast<DWORD>(before));
        const DWORD caret = LOWORD(static_cast<DWORD>(after));
        const DWORD caretEnd = HIWORD(static_cast<DWORD>(after));
        verified = caret == caretEnd && caret > selectionStart && caret <= selectionStart + text.size();
    }
    return true;
}

// ---- UI Automation -------------------------------------------------------------

struct Patterns {
    Ref<IUIAutomationValuePattern> value;
    Ref<IUIAutomationTextPattern> text;
};

void fetchPatterns(IUIAutomationElement *element, Patterns &patterns) {
    Ref<IUnknown> unknown;
    if (SUCCEEDED(element->GetCurrentPattern(UIA_ValuePatternId, unknown.put())) && unknown) {
        unknown->QueryInterface(IID_IUIAutomationValuePattern, reinterpret_cast<void **>(patterns.value.put()));
    }
    if (SUCCEEDED(element->GetCurrentPattern(UIA_TextPatternId, unknown.put())) && unknown) {
        unknown->QueryInterface(IID_IUIAutomationTextPattern, reinterpret_cast<void **>(patterns.text.put()));
    }
}

struct Facts {
    CONTROLTYPEID type = 0;
    bool password = false;
    bool enabled = false;
    bool readOnly = true;
    bool passwordKnown = false;
    bool enabledKnown = false;
    bool readOnlyKnown = false;
};

Facts inspect(IUIAutomationElement *element, const Patterns &patterns) {
    Facts facts;
    element->get_CurrentControlType(&facts.type);
    BOOL flag = FALSE;
    if (SUCCEEDED(element->get_CurrentIsPassword(&flag))) { facts.passwordKnown = true; facts.password = flag != FALSE; }
    flag = TRUE;
    if (SUCCEEDED(element->get_CurrentIsEnabled(&flag))) { facts.enabledKnown = true; facts.enabled = flag != FALSE; }
    if (patterns.value) {
        flag = FALSE;
        if (SUCCEEDED(patterns.value->get_CurrentIsReadOnly(&flag))) { facts.readOnlyKnown = true; facts.readOnly = flag != FALSE; }
    }
    if (!facts.readOnlyKnown && patterns.text) {
        Ref<IUIAutomationTextRange> range;
        VARIANT value;
        VariantInit(&value);
        if (SUCCEEDED(patterns.text->get_DocumentRange(range.put())) && range &&
            SUCCEEDED(range->GetAttributeValue(UIA_IsReadOnlyAttributeId, &value)) && value.vt == VT_BOOL) {
            facts.readOnlyKnown = true;
            facts.readOnly = value.boolVal != VARIANT_FALSE;
        }
        VariantClear(&value);
    }
    return facts;
}

bool editable(const Facts &facts, const Patterns &patterns) {
    if (!facts.passwordKnown || !facts.enabledKnown || !facts.readOnlyKnown ||
        facts.password || !facts.enabled || facts.readOnly) return false;
    if (facts.type == UIA_EditControlTypeId || facts.type == UIA_DocumentControlTypeId ||
        facts.type == UIA_ComboBoxControlTypeId) return true;
    return patterns.text && patterns.value && !facts.readOnly;
}

// The nearest ancestor with a native window handle. Browser and XAML text
// fields report no handle of their own; their host window must be the
// captured focus window.
HWND nearestWindow(IUIAutomation *automation, IUIAutomationElement *element) {
    Ref<IUIAutomationTreeWalker> walker;
    if (FAILED(automation->get_RawViewWalker(walker.put())) || !walker) return nullptr;
    Ref<IUIAutomationElement> current;
    current.retain(element);
    for (int depth = 0; depth < 64 && current; ++depth) {
        UIA_HWND handle = nullptr;
        if (SUCCEEDED(current->get_CurrentNativeWindowHandle(&handle)) && handle) return static_cast<HWND>(handle);
        Ref<IUIAutomationElement> parent;
        if (FAILED(walker->GetParentElement(current.value, parent.put())) || !parent) return nullptr;
        current.retain(parent.value);
    }
    return nullptr;
}

bool elementBelongs(IUIAutomation *automation, IUIAutomationElement *element, const Identity &identity) {
    int process = 0;
    if (FAILED(element->get_CurrentProcessId(&process)) || static_cast<DWORD>(process) != identity.process) return false;
    const HWND handle = nearestWindow(automation, element);
    if (!handle) return false;
    return (handle == identity.focus || IsChild(identity.focus, handle) || IsChild(handle, identity.focus)) &&
        GetAncestor(handle, GA_ROOT) == identity.window;
}

bool selectionRange(IUIAutomationTextPattern *text, Ref<IUIAutomationTextRange> &range) {
    Ref<IUIAutomationTextRangeArray> ranges;
    if (FAILED(text->GetSelection(ranges.put())) || !ranges) return false;
    int length = 0;
    if (FAILED(ranges->get_Length(&length)) || length < 1) return false;
    return SUCCEEDED(ranges->GetElement(0, range.put())) && range;
}

bool wholeDocumentSelected(IUIAutomationTextPattern *text) {
    Ref<IUIAutomationTextRange> selection, document;
    if (!selectionRange(text, selection) || FAILED(text->get_DocumentRange(document.put())) || !document) return false;
    int start = 1, end = 1;
    if (FAILED(selection->CompareEndpoints(TextPatternRangeEndpoint_Start, document.value,
                                           TextPatternRangeEndpoint_Start, &start)) ||
        FAILED(selection->CompareEndpoints(TextPatternRangeEndpoint_End, document.value,
                                           TextPatternRangeEndpoint_End, &end))) return false;
    BStr content;
    const bool nonEmpty = SUCCEEDED(document->GetText(1, &content.value)) && content.value && SysStringLen(content.value) > 0;
    return nonEmpty && start == 0 && end == 0;
}

// Reads the field through the Value pattern, else the whole document text
// (bounded). readable stays false when neither is available.
bool readField(const Patterns &patterns, std::wstring &content, bool &readable) {
    readable = false;
    if (patterns.value) {
        BStr value;
        if (SUCCEEDED(patterns.value->get_CurrentValue(&value.value))) { content = value.str(); readable = true; return true; }
    }
    if (patterns.text) {
        Ref<IUIAutomationTextRange> document;
        BStr text;
        if (SUCCEEDED(patterns.text->get_DocumentRange(document.put())) && document &&
            SUCCEEDED(document->GetText(2000000, &text.value))) { content = text.str(); readable = true; return true; }
    }
    return false;
}

size_t occurrences(const std::wstring &haystack, const std::wstring &needle) {
    if (needle.empty()) return 0;
    size_t count = 0;
    for (size_t position = haystack.find(needle); position != std::wstring::npos;
         position = haystack.find(needle, position + needle.size())) ++count;
    return count;
}

std::string automationError(const char *operation, HRESULT code) {
    return std::string(operation) + " failed (HRESULT 0x" + [code] {
        char digits[16]{};
        const unsigned long value = static_cast<unsigned long>(static_cast<uint32_t>(code));
        const char *hex = "0123456789ABCDEF";
        for (int index = 7; index >= 0; --index) digits[7 - index] = hex[(value >> (index * 4)) & 0xF];
        return std::string(digits);
    }() + ").";
}

// ---- target state and worker -------------------------------------------------

struct State {
    Environment environment;
    Identity identity;
    std::mutex mutex;
    std::condition_variable changed;
    bool shutdown = false;
    bool insertRequested = false;
    bool insertBusy = false;
    bool insertFinished = false;
    bool abandoned = false;
    bool mutationStarted = false;
    uint64_t focusRevision = 0;
    FocusEvent focusEvent;
    jsti::Handle process;
    std::wstring text;
    unsigned flags = 0;
    JSTIInsertionResult result{};
    std::string error;
    int status = -1;
    jsti::Handle exited;
};

class Worker {
    std::shared_ptr<State> state;
    Ref<IUIAutomation> automation;
    Ref<IUIAutomationElement> captured;

    bool abandoned() {
        std::lock_guard<std::mutex> lock(state->mutex);
        return state->abandoned || state->shutdown;
    }

    bool focusUnchanged() {
        return state->focusRevision != 0 && state->environment.focusRevision &&
            state->environment.focusRevision() == state->focusRevision;
    }

    bool verifyField(std::string &error) {
        if (!focusUnchanged() || !captured) { error = changedMessage; return false; }
        if (!verifyIdentity(state->environment, state->identity, error)) return false;
        Ref<IUIAutomationElement> current;
        BOOL same = FALSE;
        if (FAILED(state->environment.focusedElement(automation.value, state->identity.focus, current.put())) || !current ||
            FAILED(automation->CompareElements(captured.value, current.value, &same)) || !same) {
            error = changedMessage;
            return false;
        }
        Patterns patterns;
        fetchPatterns(current.value, patterns);
        const Facts facts = inspect(current.value, patterns);
        if (!editable(facts, patterns)) { error = unsupportedMessage; return false; }
        return true;
    }

    bool beginMutation(const JSTIInsertionResult &result, std::string &error) {
        if (WaitForSingleObject(state->process.value, 0) != WAIT_TIMEOUT) {
            error = "The original application process has exited."; return false;
        }
        if (!focusUnchanged() || !verifyIdentity(state->environment, state->identity, error)) {
            error = changedMessage;
            return false;
        }
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->abandoned || state->shutdown) { error = timeoutMessage; return false; }
        state->mutationStarted = true;
        state->result = result;
        return true;
    }

    void createAutomation() {
        const Environment &environment = state->environment;
        Ref<IUIAutomation2> modern;
        if (SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_IUIAutomation2,
                                       reinterpret_cast<void **>(modern.put()))) && modern) {
            // Bound every provider round trip so a hung application cannot
            // hold the worker beyond the caller's timeout by much.
            modern->put_ConnectionTimeout(environment.providerTimeoutMs);
            modern->put_TransactionTimeout(environment.providerTimeoutMs);
            modern->QueryInterface(IID_IUIAutomation, reinterpret_cast<void **>(automation.put()));
        } else {
            CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_IUIAutomation,
                             reinterpret_cast<void **>(automation.put()));
        }
    }

    // Background capture is usable only if no focus transition occurred while
    // the provider was resolving it. Failure never downgrades a virtual field
    // to HWND-only identity.
    void captureFocus() {
        if (!automation || !focusUnchanged() || !state->focusEvent.window || !state->environment.resolveFocusEvent) return;
        Ref<IUIAutomationElement> element;
        if (FAILED(state->environment.resolveFocusEvent(automation.value, state->focusEvent, element.put())) || !element) return;
        if (focusUnchanged() && elementBelongs(automation.value, element.value, state->identity)) captured.retain(element.value);
    }

    int paste(const std::wstring &text, unsigned flags, const Patterns &patterns, JSTIInsertionResult &result, std::string &error) {
        const Environment &environment = state->environment;
        Clipboard &clipboard = *environment.clipboard();
        const bool keep = (flags & JSTI_INSERTION_KEEP_TRANSCRIPT_ON_CLIPBOARD) != 0;
        ClipboardSnapshot snapshot;
        std::wstring before;
        bool readable = false;
        readField(patterns, before, readable);
        const size_t expected = readable ? occurrences(normalizedForComparison(before), normalizedForComparison(text)) + 1 : 0;
        DWORD sequence = 0;
        {
            OwnerWindow owner;
            if (!owner.handle) { error = systemError("Creating clipboard owner", owner.error); return -1; }
            if (!placeText(clipboard, owner.handle, text, true, sequence, error, &snapshot, &result.clipboard,
                           [&] { return !abandoned(); })) return -1;
        }
        auto restore = [&]() -> int {
            if (keep) return JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT;
            OwnerWindow owner;
            return owner.handle ? restoreClipboard(clipboard, owner.handle, snapshot, sequence)
                                : JSTI_INSERTION_CLIPBOARD_RESTORE_FAILED;
        };
        // Modifier waits and all provider reads precede the final dispatch
        // guard. Cancellation/focus changes during a wait prevent the paste.
        std::string pasteError;
        if (environment.preparePaste && !environment.preparePaste(pasteError)) {
            result.clipboard = restore(); error = pasteError; return -1;
        }
        if (!verifyField(error)) { result.clipboard = restore(); return -1; }
        if (clipboard.sequence() != sequence) {
            result.clipboard = JSTI_INSERTION_CLIPBOARD_CHANGED_MEANWHILE;
            error = "The clipboard changed before paste dispatch. Copy the transcript instead.";
            return -1;
        }
        result.method = JSTI_INSERTION_METHOD_PASTE;
        result.clipboard = JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT;
        if (!beginMutation(result, error)) {
            result.method = JSTI_INSERTION_METHOD_NONE; result.clipboard = restore(); return -1;
        }
        const unsigned sent = environment.sendPaste(pasteError);
        if (sent != 4) {
            if (environment.releasePasteKeys) environment.releasePasteKeys(sent);
            error = pasteError;
            if (sent == 0) {
                result.method = JSTI_INSERTION_METHOD_NONE;
                result.clipboard = restore();
                return -1;
            }
            // Some shortcut events reached the input queue. Keep the transcript
            // available for a delayed paste; never substitute the old clipboard.
            return 1;
        }
        bool verified = false;
        if (readable) {
            const ULONGLONG deadline = GetTickCount64() + environment.verifyTimeoutMs;
            while (true) {
                std::wstring after;
                bool readableNow = false;
                if (readField(patterns, after, readableNow) &&
                    occurrences(normalizedForComparison(after), normalizedForComparison(text)) >= expected) { verified = true; break; }
                if (GetTickCount64() >= deadline) break;
                environment.sleep(environment.verifyIntervalMs);
            }
        }
        result.verified = verified ? 1 : 0;
        if (keep) { result.clipboard = JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT; return 0; }
        if (verified) { result.clipboard = restore(); return 0; }
        // The text could not be confirmed: the application may still be
        // processing or may have transformed it. Keep the transcript
        // available rather than risk a later paste of the old content.
        result.clipboard = JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT;
        return 0;
    }

    int insert(const std::wstring &text, unsigned flags, JSTIInsertionResult &result, std::string &error) {
        const Environment &environment = state->environment;
        result = {};
        result.method = JSTI_INSERTION_METHOD_NONE;
        result.identity = JSTI_INSERTION_IDENTITY_WINDOW;
        result.clipboard = JSTI_INSERTION_CLIPBOARD_UNTOUCHED;
        if (environment.beforeAutomation) environment.beforeAutomation(environment.hookContext);
        if (!automation) {
            error = "UI Automation is unavailable, so this application's text field cannot be verified. Copy the transcript instead.";
            return -1;
        }
        if (!verifyIdentity(environment, state->identity, error)) return -1;
        Ref<IUIAutomationElement> current;
        if (FAILED(environment.focusedElement(automation.value, state->identity.focus, current.put())) || !current) {
            error = "The focused field could not be identified through UI Automation. Copy the transcript instead.";
            return -1;
        }
        if (!elementBelongs(automation.value, current.value, state->identity)) { error = movedMessage; return -1; }
        if (!captured || !focusUnchanged()) { error = changedMessage; return -1; }
        if (captured) {
            BOOL same = FALSE;
            if (FAILED(automation->CompareElements(captured.value, current.value, &same)) || !same) {
                error = changedMessage;
                return -1;
            }
            result.identity = JSTI_INSERTION_IDENTITY_FIELD;
        }
        Patterns patterns;
        fetchPatterns(current.value, patterns);
        const Facts facts = inspect(current.value, patterns);
        if (facts.password) { error = passwordMessage; return -1; }
        if (!facts.enabled) { error = disabledMessage; return -1; }
        if (facts.readOnlyKnown && facts.readOnly) { error = readOnlyMessage; return -1; }
        if (!editable(facts, patterns)) { error = unsupportedMessage; return -1; }
        const bool replaceField = (flags & JSTI_INSERTION_REPLACE_FIELD) != 0;
        if (patterns.value) {
            bool useValue = replaceField;
            if (!useValue) {
                BStr value;
                if (SUCCEEDED(patterns.value->get_CurrentValue(&value.value)) && (!value.value || SysStringLen(value.value) == 0)) {
                    useValue = true;
                }
            }
            if (!useValue && patterns.text && wholeDocumentSelected(patterns.text.value)) useValue = true;
            if (useValue) {
                BStr payload;
                payload.value = SysAllocStringLen(text.data(), static_cast<UINT>(text.size()));
                if (!payload.value) { error = "Could not allocate the insertion text."; return -1; }
                if (!verifyField(error)) return -1;
                result.method = JSTI_INSERTION_METHOD_UIA_VALUE;
                if (!beginMutation(result, error)) { result.method = JSTI_INSERTION_METHOD_NONE; return -1; }
                const HRESULT set = patterns.value->SetValue(payload.value);
                if (FAILED(set)) { error = automationError("Setting the field value", set); return 1; }
                result.method = JSTI_INSERTION_METHOD_UIA_VALUE;
                std::wstring after;
                bool readable = false;
                result.verified = readField(patterns, after, readable) && containsNormalized(after, text) ? 1 : 0;
                return 0;
            }
        } else if (replaceField) {
            error = "Replacing this field requires a UI Automation Value pattern, which it does not expose. Copy the transcript instead.";
            return -1;
        }
        if (flags & JSTI_INSERTION_NO_PASTE_FALLBACK) {
            error = "This field needs the clipboard paste fallback, which is disabled. Copy the transcript instead.";
            return -1;
        }
        return paste(text, flags, patterns, result, error);
    }

public:
    explicit Worker(std::shared_ptr<State> shared) : state(std::move(shared)) {}

    void run() {
        WorkerScope scope;
        const bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
        try {
        if (state->environment.beforeAutomation) state->environment.beforeAutomation(state->environment.hookContext);
        if (com && !abandoned()) {
            createAutomation();
            captureFocus();
        }
        while (true) {
            std::wstring text;
            unsigned flags = 0;
            {
                std::unique_lock<std::mutex> lock(state->mutex);
                state->changed.wait(lock, [&] { return state->shutdown || state->insertRequested; });
                if (state->shutdown) break;
                state->insertRequested = false;
                text = state->text;
                flags = state->flags;
            }
            JSTIInsertionResult result{};
            std::string error;
            const int status = insert(text, flags, result, error);
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->result = result;
                state->error = error;
                state->status = status;
                state->insertBusy = false;
                state->insertFinished = true;
            }
            state->changed.notify_all();
        }
        } catch (...) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->status = state->mutationStarted ? 1 : -1;
            try { state->error = "The insertion worker could not complete the operation."; } catch (...) {}
            state->insertBusy = false;
            state->insertFinished = true;
            state->shutdown = true;
            state->changed.notify_all();
        }
        captured.reset();
        automation.reset();
        if (com) CoUninitialize();
        SetEvent(state->exited.value);
    }
};

} // namespace

Environment defaultEnvironment() {
    Environment environment;
    environment.foregroundWindow = &realForeground;
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

void pasteInputs(INPUT (&inputs)[4]) {
    std::memset(inputs, 0, sizeof(inputs));
    const WORD keys[4] = {VK_CONTROL, 'V', 'V', VK_CONTROL};
    const bool release[4] = {false, false, true, true};
    for (size_t index = 0; index < 4; ++index) {
        inputs[index].type = INPUT_KEYBOARD;
        inputs[index].ki.wVk = keys[index];
        inputs[index].ki.wScan = static_cast<WORD>(MapVirtualKeyW(keys[index], MAPVK_VK_TO_VSC));
        inputs[index].ki.dwFlags = release[index] ? KEYEVENTF_KEYUP : 0;
    }
}

// Line endings, whitespace runs and zero-width marks differ between what an
// application stores and what it exposes; compare the visible words only.
std::wstring normalizedForComparison(const std::wstring &text) {
    std::wstring result;
    result.reserve(text.size());
    bool pendingSpace = false;
    for (const wchar_t character : text) {
        if (character == 0x200B || character == 0x200C || character == 0x200D || character == 0xFEFF) continue;
        const bool space = character == L' ' || character == L'\t' || character == L'\r' || character == L'\n' ||
            character == 0x000B || character == 0x000C || character == 0x00A0 || character == 0x2028 || character == 0x2029;
        if (space) { pendingSpace = !result.empty(); continue; }
        if (pendingSpace) { result.push_back(L' '); pendingSpace = false; }
        result.push_back(character);
    }
    return result;
}

bool containsNormalized(const std::wstring &haystack, const std::wstring &needle) {
    const std::wstring wanted = normalizedForComparison(needle);
    return !wanted.empty() && normalizedForComparison(haystack).find(wanted) != std::wstring::npos;
}

size_t liveWorkerCount() {
    std::lock_guard<std::mutex> lock(workerMutex);
    return liveWorkers;
}

bool waitForWorkersToExit(DWORD timeoutMs) {
    std::unique_lock<std::mutex> lock(workerMutex);
    return workerChanged.wait_for(lock, std::chrono::milliseconds(timeoutMs), [] { return liveWorkers == 0; });
}

UINT excludeFromMonitoringFormat() {
    static const UINT format = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
    return format;
}
UINT excludeFromHistoryFormat() {
    static const UINT format = RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
    return format;
}
UINT excludeFromCloudFormat() {
    static const UINT format = RegisterClipboardFormatW(L"CanUploadToCloudClipboard");
    return format;
}

} // namespace jsti::textoutput

using namespace jsti::textoutput;

struct JSTIInsertionTarget {
    std::shared_ptr<State> state;
    std::thread worker;
};

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

JSTIInsertionTarget *jsti_insertion_capture(char *error, size_t capacity) {
    try {
        const Environment environment = currentEnvironment();
        const uint64_t revision = environment.focusRevision ? environment.focusRevision() : 0;
        Identity identity;
        std::string reason;
        if (!captureIdentity(environment, identity, reason)) { jsti::fail(reason, error, capacity); return nullptr; }
        auto state = std::make_shared<State>();
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
            try { target->worker = std::thread([state] { Worker(state).run(); }); }
            catch (...) { WorkerScope releaseReservedSlot; throw; }
        }
        if (error && capacity) error[0] = 0;
        return target.release();
    } catch (const std::exception &) {
        jsti::fail("Could not allocate the insertion target.", error, capacity);
        return nullptr;
    }
}

int jsti_insertion_insert(JSTIInsertionTarget *target, const char *text, unsigned flags,
                          JSTIInsertionResult *result, char *error, size_t capacity) {
    JSTIInsertionResult local{};
    local.method = JSTI_INSERTION_METHOD_NONE;
    local.identity = JSTI_INSERTION_IDENTITY_WINDOW;
    local.clipboard = JSTI_INSERTION_CLIPBOARD_UNTOUCHED;
    if (result) *result = local;
    std::wstring value;
    if (!target || !target->state) return jsti::fail("No captured text field. Copy the transcript instead.", error, capacity);
    if (!jsti::wide(text, value)) return jsti::fail("The transcript is not valid UTF-8.", error, capacity);
    if (value.empty()) return jsti::fail("There is no transcript text to insert.", error, capacity);
    State &state = *target->state;
    const Environment &environment = state.environment;
    std::string reason;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.abandoned || state.shutdown) return jsti::fail("This insertion target was cancelled.", error, capacity);
    }
    if (WaitForSingleObject(state.process.value, 0) != WAIT_TIMEOUT) {
        return jsti::fail("The original application process has exited.", error, capacity);
    }
    if (!verifyIdentity(environment, state.identity, reason)) return jsti::fail(reason, error, capacity);
    if (!integrityAllows(state.identity.process, reason)) return jsti::fail(reason, error, capacity);
    const NativeKind kind = environment.nativeDirectPath ? classifyNative(state.identity.focus) : NativeKind::NotNative;
    if (kind == NativeKind::Password || kind == NativeKind::ReadOnly || kind == NativeKind::Disabled) {
        return jsti::fail(refusal(kind), error, capacity);
    }
    if (kind == NativeKind::Editable) {
        // Never waits on the UI Automation worker: native controls are
        // addressed directly on the caller's thread.
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            if (state.insertBusy) return jsti::fail("An insertion is already in progress.", error, capacity);
            state.insertBusy = true;
            state.mutationStarted = false;
        }
        struct BusyGuard {
            State &state;
            ~BusyGuard() { std::lock_guard<std::mutex> lock(state.mutex); state.insertBusy = false; }
        } busy{state};
        bool verified = false;
        auto mayMutate = [&] {
            if (WaitForSingleObject(state.process.value, 0) != WAIT_TIMEOUT) {
                reason = "The original application process has exited."; return false;
            }
            if (!verifyIdentity(environment, state.identity, reason)) return false;
            if (classifyNative(state.identity.focus) != NativeKind::Editable) { reason = unsupportedMessage; return false; }
            std::lock_guard<std::mutex> lock(state.mutex);
            if (state.abandoned || state.shutdown) { reason = "This insertion target was cancelled."; return false; }
            state.mutationStarted = true;
            return true;
        };
        if (!nativeReplaceSelection(state.identity.focus, value, (flags & JSTI_INSERTION_REPLACE_FIELD) != 0,
                                    verified, reason, mayMutate)) {
            jsti::fail(reason, error, capacity);
            std::lock_guard<std::mutex> lock(state.mutex);
            if (state.mutationStarted) {
                local.method = JSTI_INSERTION_METHOD_NATIVE_EDIT;
                if (result) *result = local;
                return 1;
            }
            return -1;
        }
        local.method = JSTI_INSERTION_METHOD_NATIVE_EDIT;
        local.verified = verified ? 1 : 0;
        if (result) *result = local;
        if (error && capacity) error[0] = 0;
        return 0;
    }
    if (!target->worker.joinable()) return jsti::fail("Text insertion workers are busy. Copy the transcript instead.", error, capacity);
    try {
        std::unique_lock<std::mutex> lock(state.mutex);
        if (state.abandoned || state.shutdown || state.insertBusy) {
            return jsti::fail("An insertion is already in progress for this field.", error, capacity);
        }
        state.text = value;
        state.flags = flags;
        state.insertRequested = true;
        state.insertBusy = true;
        state.insertFinished = false;
        state.mutationStarted = false;
        state.result = local;
        state.changed.notify_all();
        if (!state.changed.wait_for(lock, std::chrono::milliseconds(environment.insertTimeoutMs),
                                    [&] { return state.insertFinished; })) {
            // The worker finishes or abandons the job on its own and still
            // restores the clipboard; it must not paste after this report.
            state.abandoned = true;
            if (result) *result = state.result;
            jsti::fail(timeoutMessage, error, capacity);
            return state.mutationStarted ? 1 : -1;
        }
        if (result) *result = state.result;
        if (state.status != 0) { jsti::fail(state.error, error, capacity); return state.status; }
    } catch (const std::exception &) {
        return jsti::fail("Could not queue the insertion request.", error, capacity);
    }
    if (error && capacity) error[0] = 0;
    return 0;
}

int jsti_insertion_copy_text(JSTIInsertionTarget *target, const char *text, JSTIInsertionResult *result,
                              char *error, size_t capacity) {
    if (result) *result = {};
    if (!target || !target->state) return jsti::fail("No captured output request.", error, capacity);
    try {
        const auto state = target->state;
        std::wstring value;
        if (!jsti::wide(text, value)) return jsti::fail("Clipboard text is not valid UTF-8.", error, capacity);
        OwnerWindow owner;
        if (!owner.handle) return jsti::fail(jsti::systemError("Creating clipboard owner", owner.error), error, capacity);
        std::string reason;
        DWORD sequence = 0;
        int clipboard = JSTI_INSERTION_CLIPBOARD_UNTOUCHED;
        const bool copied = placeText(*state->environment.clipboard(), owner.handle, value, false, sequence, reason,
                                     nullptr, &clipboard, [&] {
            std::lock_guard<std::mutex> lock(state->mutex);
            return !state->abandoned && !state->shutdown;
        });
        if (result) result->clipboard = copied ? JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT : clipboard;
        if (!copied) return jsti::fail(reason, error, capacity);
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (...) { return jsti::fail("Could not copy the transcript.", error, capacity); }
}

void jsti_insertion_cancel(JSTIInsertionTarget *target) {
    if (!target || !target->state) return;
    const auto state = target->state;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->abandoned = true;
        state->shutdown = true;
    }
    state->changed.notify_all();
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
