// Target identity: paste keystrokes, integrity levels, captured focus identity and native Edit insertion.
#include "WindowsTextOutputParts.hpp"

namespace jsti::textoutput {
namespace {

// ---- keyboard ----------------------------------------------------------------

bool modifiersHeld() {
    for (const int key : {VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN}) {
        if (GetAsyncKeyState(key) & 0x8000) return true;
    }
    return false;
}

} // namespace

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

namespace {

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

} // namespace

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

bool ownApplication(HWND window) {
    DWORD process = 0;
    return window && GetWindowThreadProcessId(window, &process) && process == GetCurrentProcessId();
}

bool sameApplication(HWND first, HWND second) {
    DWORD firstProcess = 0, secondProcess = 0;
    return first && second && GetWindowThreadProcessId(first, &firstProcess) &&
        GetWindowThreadProcessId(second, &secondProcess) && firstProcess == secondProcess;
}

bool verifyIdentity(const Environment &environment, const Identity &identity, std::string &error,
                    bool backgroundNative) {
    DWORD process = 0;
    const DWORD thread = GetWindowThreadProcessId(identity.focus, &process);
    GUITHREADINFO info{};
    info.cbSize = sizeof(info);
    if (!identity.window || !identity.focus || !IsWindow(identity.window) || !IsWindow(identity.focus) ||
        process != identity.process || thread != identity.thread ||
        (!backgroundNative && (environment.foregroundWindow() != identity.window || !GetGUIThreadInfo(thread, &info) ||
        info.hwndFocus != identity.focus)) || GetAncestor(identity.focus, GA_ROOT) != identity.window) {
        error = movedMessage;
        return false;
    }
    return true;
}

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
                            const std::function<bool()> &mayMutate, DWORD *learningCaret) {
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
        DWORD fullStart = 0, fullEnd = 0;
        if (learningCaret && verified && caret == selectionStart + text.size() &&
            SendMessageTimeoutW(focus, EM_GETSEL, reinterpret_cast<WPARAM>(&fullStart),
                reinterpret_cast<LPARAM>(&fullEnd), flags, 1000, &ignored) &&
            fullStart == caret && fullEnd == caret) *learningCaret = caret;
    }
    return true;
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

} // namespace jsti::textoutput
