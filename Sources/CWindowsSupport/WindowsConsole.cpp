#include "include/CWindowsSupport.h"

#include <windows.h>

#include <cstdio>

namespace {

bool usable(HANDLE handle) { return handle != nullptr && handle != INVALID_HANDLE_VALUE; }

}  // namespace

// SpeakWindows.exe links as a GUI-subsystem image so a Start menu launch opens
// no console. Diagnostic flags still print: redirected handles (CI, pipes) are
// used as they are, and only missing ones are bound to the parent's console.
extern "C" int32_t jsti_console_attach_parent(void) {
    const bool out = usable(GetStdHandle(STD_OUTPUT_HANDLE));
    const bool err = usable(GetStdHandle(STD_ERROR_HANDLE));
    if (out && err) return 0;
    if (!AttachConsole(ATTACH_PARENT_PROCESS)) return 0;
    FILE *stream = nullptr;
    if (!out && freopen_s(&stream, "CONOUT$", "w", stdout) == 0) {
        SetStdHandle(STD_OUTPUT_HANDLE, CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr));
    }
    if (!err && freopen_s(&stream, "CONOUT$", "w", stderr) == 0) {
        SetStdHandle(STD_ERROR_HANDLE, CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr));
    }
    return 1;
}
