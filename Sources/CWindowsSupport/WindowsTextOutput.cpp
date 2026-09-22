#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"

int jsti_target_capture(JSTITextTarget *target, char *error, size_t capacity) {
    if (!target) return jsti::fail("No text target supplied.", error, capacity);
    *target = {};
    const HWND window = GetForegroundWindow();
    DWORD process = 0;
    const DWORD thread = GetWindowThreadProcessId(window, &process);
    GUITHREADINFO info{};
    info.cbSize = sizeof(info);
    if (!window || !thread || process == GetCurrentProcessId() || !GetGUIThreadInfo(thread, &info) || !info.hwndFocus) {
        return jsti::fail("No external text field is focused. The transcript will remain available to copy.", error, capacity);
    }
    target->window = reinterpret_cast<uintptr_t>(window);
    target->focused_control = reinterpret_cast<uintptr_t>(info.hwndFocus);
    target->process_id = process;
    target->thread_id = thread;
    return 0;
}

int jsti_target_insert_text(const JSTITextTarget *target, const char *text, char *error, size_t capacity) {
    std::wstring value;
    if (!target || !target->window || !target->focused_control || !jsti::wide(text, value)) {
        return jsti::fail("No valid captured text field. Copy the transcript instead.", error, capacity);
    }
    const HWND window = reinterpret_cast<HWND>(target->window);
    const HWND focus = reinterpret_cast<HWND>(target->focused_control);
    DWORD process = 0;
    const DWORD thread = GetWindowThreadProcessId(focus, &process);
    GUITHREADINFO info{};
    info.cbSize = sizeof(info);
    if (!IsWindow(window) || !IsWindow(focus) || process != target->process_id || thread != target->thread_id ||
        GetForegroundWindow() != window || !GetGUIThreadInfo(thread, &info) || info.hwndFocus != focus ||
        GetAncestor(focus, GA_ROOT) != window || !IsWindowUnicode(focus)) {
        return jsti::fail("The original text field is no longer focused. Copy the transcript instead.", error, capacity);
    }
    wchar_t className[128]{};
    GetClassNameW(focus, className, 128);
    const bool supported = _wcsicmp(className, L"Edit") == 0 ||
        _wcsicmp(className, L"RichEdit20W") == 0 || _wcsicmp(className, L"RICHEDIT50W") == 0;
    if (!supported || !IsWindowEnabled(focus) || (GetWindowLongPtrW(focus, GWL_STYLE) & (ES_READONLY | ES_PASSWORD))) {
        return jsti::fail("This application does not expose a supported editable text field. Copy the transcript instead.", error, capacity);
    }
    // EM_REPLACESEL is sent to the captured HWND, never whichever application
    // receives global keyboard input. Do not fall back to SendInput/WM_PASTE.
    DWORD_PTR result = 0;
    SetLastError(ERROR_SUCCESS);
    if (!SendMessageTimeoutW(focus, EM_REPLACESEL, TRUE, reinterpret_cast<LPARAM>(value.c_str()),
                             SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT, 1000, &result)) {
        return jsti::fail(jsti::systemError("Inserting into the original text field"), error, capacity);
    }
    return 0;
}

int jsti_clipboard_write(const char *text, char *error, size_t capacity) {
    std::wstring value;
    if (!jsti::wide(text, value)) return jsti::fail("Clipboard text is not valid UTF-8.", error, capacity);
    const size_t bytes = (value.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!memory) return jsti::fail(jsti::systemError("Allocating clipboard text"), error, capacity);
    void *destination = GlobalLock(memory);
    if (!destination) {
        const DWORD code = GetLastError();
        GlobalFree(memory);
        return jsti::fail(jsti::systemError("Locking clipboard text", code), error, capacity);
    }
    std::memcpy(destination, value.c_str(), bytes);
    GlobalUnlock(memory);
    // A real HWND is required for EmptyClipboard ownership before SetClipboardData.
    HWND owner = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!owner) {
        const DWORD code = GetLastError();
        GlobalFree(memory);
        return jsti::fail(jsti::systemError("Creating clipboard owner", code), error, capacity);
    }
    if (!OpenClipboard(owner)) {
        const DWORD code = GetLastError();
        DestroyWindow(owner); GlobalFree(memory);
        return jsti::fail(jsti::systemError("Opening clipboard", code), error, capacity);
    }
    const bool success = EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, memory);
    const DWORD code = GetLastError();
    CloseClipboard();
    DestroyWindow(owner);
    if (!success) { GlobalFree(memory); return jsti::fail(jsti::systemError("Writing clipboard", code), error, capacity); }
    return 0; // The system owns memory after SetClipboardData succeeds.
}
