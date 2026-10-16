#include "WindowsAppIcon.hpp"
#include "WindowsTray.hpp"

namespace jsti::appIcon {
namespace {
constexpr WORD idleResource = 101, recordingResource = 102;
HICON largeIcon = nullptr, smallIcon = nullptr, recordingIcon = nullptr;

HICON load(WORD resource, int size) {
    return reinterpret_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(resource),
                                              IMAGE_ICON, size, size, LR_DEFAULTCOLOR));
}
}

bool refresh(HWND window, UINT dpi, std::string &failure) {
    const int largeSize = GetSystemMetricsForDpi(SM_CXICON, dpi);
    const int smallSize = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
    HICON nextLarge = load(idleResource, largeSize);
    HICON nextSmall = load(idleResource, smallSize);
    HICON nextRecording = load(recordingResource, smallSize);
    if (!nextLarge || !nextSmall || !nextRecording) {
        if (nextLarge) DestroyIcon(nextLarge);
        if (nextSmall) DestroyIcon(nextSmall);
        if (nextRecording) DestroyIcon(nextRecording);
        failure = "Could not load the canonical application icon resources.";
        return false;
    }
    if (window) {
        SendMessageW(window, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(nextLarge));
        SendMessageW(window, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(nextSmall));
        jsti::tray::setIcons(nextSmall, nextRecording);
    }
    destroy();
    largeIcon = nextLarge; smallIcon = nextSmall; recordingIcon = nextRecording;
    return true;
}

HICON largeHandle() { return largeIcon; }
HICON smallHandle() { return smallIcon; }
HICON recordingHandle() { return recordingIcon; }

void destroy() {
    if (largeIcon) DestroyIcon(largeIcon);
    if (smallIcon) DestroyIcon(smallIcon);
    if (recordingIcon) DestroyIcon(recordingIcon);
    largeIcon = smallIcon = recordingIcon = nullptr;
}

bool selfTest(HWND window, std::string &failure) {
    if (reinterpret_cast<HICON>(SendMessageW(window, WM_GETICON, ICON_BIG, 0)) != largeIcon ||
        reinterpret_cast<HICON>(SendMessageW(window, WM_GETICON, ICON_SMALL, 0)) != smallIcon ||
        !largeIcon || !smallIcon || !recordingIcon) {
        failure = "The window/taskbar did not retain the canonical application icons.";
        return false;
    }
    for (const WORD resource : {idleResource, recordingResource}) {
        for (const int size : {16, 20, 24, 32, 40, 48, 64, 128, 256}) {
            HICON icon = load(resource, size);
            ICONINFO info{};
            BITMAP bitmap{};
            const bool ok = icon && GetIconInfo(icon, &info) && info.hbmColor &&
                GetObjectW(info.hbmColor, sizeof(bitmap), &bitmap) && bitmap.bmWidth == size &&
                bitmap.bmHeight == size && bitmap.bmBitsPixel == 32;
            if (info.hbmColor) DeleteObject(info.hbmColor);
            if (info.hbmMask) DeleteObject(info.hbmMask);
            if (icon) DestroyIcon(icon);
            if (!ok) {
                failure = "Canonical app icon resources failed a native size/alpha bitmap check.";
                return false;
            }
        }
    }
    return true;
}
}
