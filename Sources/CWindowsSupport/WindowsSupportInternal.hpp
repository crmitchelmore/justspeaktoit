#pragma once

#ifndef _WIN32
#error CWindowsSupport must only be included in Windows builds.
#endif

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <limits>

namespace jsti {
// Exclusive private staging file, opened read/write with DELETE access so a
// failed producer can remove its own file by handle rather than following a
// mutable pathname. The caller owns the handle; INVALID_HANDLE_VALUE fails.
HANDLE createPrivateFileHandle(const char *path, std::string &error);

inline int fail(const std::string &message, char *error, size_t capacity) {
    if (error && capacity) {
        const size_t count = std::min(message.size(), capacity - 1);
        std::memcpy(error, message.data(), count);
        error[count] = 0;
    }
    return -1;
}

inline std::string systemError(const char *operation, DWORD code = GetLastError()) {
    // Numeric native codes are stable and never contain user data or credentials.
    return std::string(operation) + " failed (Windows error " + std::to_string(code) + ").";
}

inline bool wide(const char *text, std::wstring &result) {
    if (!text) return false;
    const size_t length = std::strlen(text);
    if (length > static_cast<size_t>((std::numeric_limits<int>::max)())) return false;
    if (!length) { result.clear(); return true; }
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, static_cast<int>(length), nullptr, 0);
    if (!size) return false;
    result.resize(size);
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, static_cast<int>(length), &result[0], size) != 0;
}

inline std::string utf8(const std::wstring &text) {
    if (text.empty()) return {};
    if (text.size() > static_cast<size_t>((std::numeric_limits<int>::max)())) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                                       static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (!size) return {};
    std::string result(size, 0);
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                        &result[0], size, nullptr, nullptr);
    return result;
}

struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle() = default;
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;
};

template<class T> struct COM {
    T *value = nullptr;
    ~COM() { if (value) value->Release(); }
    T *operator->() const { return value; }
    COM() = default;
    COM(const COM &) = delete;
    COM &operator=(const COM &) = delete;
};
} // namespace jsti
