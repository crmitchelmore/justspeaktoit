// Clipboard snapshot, guarded placement and restore for the paste fallback and copy-only output.
#include "WindowsTextOutputParts.hpp"

namespace jsti::textoutput {
namespace {

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

} // namespace

Clipboard *systemClipboard() {
    static SystemClipboard clipboard;
    return &clipboard;
}

namespace {

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

} // namespace

bool placeText(Clipboard &clipboard, HWND owner, const std::wstring &text, bool excludeFromHistory,
               DWORD &sequenceAfter, std::string &error, ClipboardSnapshot *replaced, int *failureState,
               const std::function<bool()> &mayWrite) {
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

bool copyTextToClipboard(const Environment &environment, const std::wstring &text,
                         const std::function<bool()> &mayWrite, int &clipboardState, std::string &error) {
    clipboardState = JSTI_INSERTION_CLIPBOARD_UNTOUCHED;
    OwnerWindow owner;
    if (!owner.handle) { error = systemError("Creating clipboard owner", owner.error); return false; }
    DWORD sequence = 0;
    if (!placeText(*environment.clipboard(), owner.handle, text, false, sequence, error, nullptr, &clipboardState,
                   mayWrite)) return false;
    clipboardState = JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT;
    return true;
}

} // namespace jsti::textoutput
