#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <atomic>
#include <cstdlib>

namespace {
constexpr size_t maximumBytes = 1048576;
std::atomic<bool> readerActive{false};
struct ReaderLease {
    ~ReaderLease() { readerActive.store(false); }
};
struct ClipboardLease {
    ~ClipboardLease() { CloseClipboard(); }
};
struct TextLease {
    HANDLE memory;
    ~TextLease() { GlobalUnlock(memory); }
};
}

int jsti_voice_command_clipboard_read(char **text, char *error, size_t capacity) {
    if (!text) return jsti::fail("Missing clipboard snapshot destination.", error, capacity);
    *text = nullptr;
    if (readerActive.exchange(true))
        return jsti::fail("A native clipboard read is still pending.", error, capacity);
    ReaderLease reader;
    if (!OpenClipboard(nullptr)) return jsti::fail(jsti::systemError("Reading clipboard"), error, capacity);
    ClipboardLease clipboard;
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return 1;
    HANDLE memory = GetClipboardData(CF_UNICODETEXT);
    if (!memory) return jsti::fail(jsti::systemError("Reading clipboard text"), error, capacity);
    const size_t units = GlobalSize(memory) / sizeof(wchar_t);
    const auto value = static_cast<const wchar_t *>(GlobalLock(memory));
    if (!value) return jsti::fail(jsti::systemError("Locking clipboard text"), error, capacity);
    TextLease lock{memory};
    size_t count = 0;
    while (count < units && count <= maximumBytes && value[count]) ++count;
    if (count >= units || count > maximumBytes)
        return jsti::fail("Clipboard text is too large or invalid.", error, capacity);
    if (!count) return 1;
    const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, static_cast<int>(count),
        nullptr, 0, nullptr, nullptr);
    if (bytes <= 0 || static_cast<size_t>(bytes) > maximumBytes)
        return jsti::fail("Clipboard text is too large or invalid.", error, capacity);
    auto output = static_cast<char *>(std::malloc(static_cast<size_t>(bytes) + 1));
    if (!output) return jsti::fail("Could not allocate clipboard snapshot.", error, capacity);
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, static_cast<int>(count),
        output, bytes, nullptr, nullptr) != bytes) {
        std::free(output);
        return jsti::fail("Clipboard text is not valid Unicode.", error, capacity);
    }
    output[bytes] = 0;
    *text = output;
    return 0;
}

void jsti_voice_command_clipboard_free(char *text) { std::free(text); }
