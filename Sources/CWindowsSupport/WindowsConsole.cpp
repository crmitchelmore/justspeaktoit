#include "include/CWindowsSupport.h"

#include <windows.h>

#include <cstdio>

namespace {

bool usable(HANDLE handle) { return handle != nullptr && handle != INVALID_HANDLE_VALUE; }

void bind(DWORD which, FILE *stream, const char *path, const wchar_t *widePath) {
    FILE *reopened = nullptr;
    if (freopen_s(&reopened, path, "w", stream) != 0) return;
    HANDLE handle = CreateFileW(widePath, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_EXISTING, 0, nullptr);
    if (usable(handle)) SetStdHandle(which, handle);
}

}  // namespace

// SpeakWindows.exe links as a GUI-subsystem image so a Start menu launch opens
// no console. Such a launch has no stdout/stderr, and Foundation traps when
// writing to a missing handle, so every missing stream gets a valid sink:
// the parent's console for command-line runs, otherwise NUL. Redirected
// handles (CI, pipes) are left as they are.
extern "C" int32_t jsti_console_prepare(int32_t attach_parent) {
    const bool out = usable(GetStdHandle(STD_OUTPUT_HANDLE));
    const bool err = usable(GetStdHandle(STD_ERROR_HANDLE));
    if (out && err) return 0;
    const bool attached = attach_parent != 0 && AttachConsole(ATTACH_PARENT_PROCESS);
    const char *path = attached ? "CONOUT$" : "NUL";
    const wchar_t *widePath = attached ? L"CONOUT$" : L"NUL";
    if (!out) bind(STD_OUTPUT_HANDLE, stdout, path, widePath);
    if (!err) bind(STD_ERROR_HANDLE, stderr, path, widePath);
    return attached ? 1 : 0;
}
