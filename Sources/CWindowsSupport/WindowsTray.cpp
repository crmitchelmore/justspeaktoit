#include "WindowsTray.hpp"

#include <shellapi.h>
#include <windowsx.h>

namespace jsti::tray {
namespace {

constexpr UINT iconID = 1, callbackMessage = WM_APP + 1;
constexpr wchar_t className[] = L"JSTINotificationArea";

HWND host = nullptr, mainWindow = nullptr;
HICON idleIcon = nullptr, recordingIcon = nullptr;
bool added = false, registered = false;
int shownRecording = 0;
std::wstring shownSummary;
UINT taskbarCreated = 0;

std::wstring tip(int recording) {
    switch (recording) {
    case 1: return L"Just Speak to It: recording";
    case 2: return L"Just Speak to It: transcribing";
    default: return L"Just Speak to It";
    }
}

NOTIFYICONDATAW iconData() {
    NOTIFYICONDATAW data{};
    data.cbSize = sizeof(data);
    data.hWnd = host;
    data.uID = iconID;
    data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    data.uCallbackMessage = callbackMessage;
    data.hIcon = shownRecording == 1 && recordingIcon ? recordingIcon : idleIcon;
    wcsncpy_s(data.szTip, tip(shownRecording).c_str(), _TRUNCATE);
    return data;
}

bool addIcon() {
    NOTIFYICONDATAW data = iconData();
    added = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
    if (added) {
        data.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &data);
    }
    return added;
}

void showMenu(POINT anchor) {
    HMENU menu = buildMenu(shownRecording, shownSummary);
    if (!menu) return;
    // The owner must be foreground for the menu to close on an outside click.
    SetForegroundWindow(host);
    const UINT alignment = GetSystemMetrics(SM_MENUDROPALIGNMENT) ? TPM_RIGHTALIGN : TPM_LEFTALIGN;
    const UINT chosen = static_cast<UINT>(TrackPopupMenuEx(
        menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | alignment, anchor.x, anchor.y, host,
        nullptr));
    PostMessageW(host, WM_NULL, 0, 0);
    DestroyMenu(menu);
    if (chosen != none && mainWindow) PostMessageW(mainWindow, commandMessage, chosen, 0);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == callbackMessage) {
        switch (LOWORD(lparam)) {
        case NIN_SELECT: case NIN_KEYSELECT:
            if (mainWindow) PostMessageW(mainWindow, commandMessage, open, 0);
            return 0;
        case WM_CONTEXTMENU:
            showMenu(POINT{GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)});
            return 0;
        default: return 0;
        }
    }
    // Explorer restarted: its new notification area needs the icon again.
    if (taskbarCreated && message == taskbarCreated) {
        addIcon();
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

} // namespace

HMENU buildMenu(int recording, const std::wstring &summary) {
    HMENU menu = CreatePopupMenu();
    if (!menu) return nullptr;
    const wchar_t *status = recording == 1 ? L"Recording…" : recording == 2 ? L"Transcribing…" : L"Ready to dictate";
    const wchar_t *action = recording == 1 ? L"Stop Recording" : recording == 2 ? L"Cancel Transcription"
                                                                              : L"Start Recording";
    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, status);
    if (!summary.empty()) AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, summary.c_str());
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, toggle, action);
    AppendMenuW(menu, MF_STRING, open, L"Open Just Speak to It");
    AppendMenuW(menu, MF_STRING, settings, L"Settings…");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, quit, L"Quit Just Speak to It");
    SetMenuDefaultItem(menu, open, FALSE);
    return menu;
}

bool add(HWND owner, HICON idle, HICON recording) {
    mainWindow = owner;
    idleIcon = idle;
    recordingIcon = recording;
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    if (!registered) {
        WNDCLASSW type{};
        type.lpfnWndProc = procedure;
        type.hInstance = instance;
        type.lpszClassName = className;
        registered = RegisterClassW(&type) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
        if (!registered) return false;
    }
    if (!taskbarCreated) taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    // A hidden top-level window, so it hears TaskbarCreated and can own the menu.
    if (!host) host = CreateWindowExW(WS_EX_TOOLWINDOW, className, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
    return host && addIcon();
}

void remove() {
    if (added) {
        NOTIFYICONDATAW data = iconData();
        Shell_NotifyIconW(NIM_DELETE, &data);
    }
    added = false;
    if (host) DestroyWindow(host);
    host = nullptr;
    mainWindow = nullptr;
    if (registered) UnregisterClassW(className, GetModuleHandleW(nullptr));
    registered = false;
}

void setState(int recording, const std::wstring &summary) {
    shownSummary = summary;
    if (recording == shownRecording) return;
    shownRecording = recording;
    if (!added) return;
    NOTIFYICONDATAW data = iconData();
    data.uFlags &= ~NIF_MESSAGE;
    Shell_NotifyIconW(NIM_MODIFY, &data);
}

bool selfTest(std::string &failure) {
    auto label = [](HMENU menu, UINT position) {
        wchar_t text[128] = {};
        GetMenuStringW(menu, position, text, 128, MF_BYPOSITION);
        return std::wstring(text);
    };
    const std::pair<int, const wchar_t *> expected[] = {
        {0, L"Start Recording"}, {1, L"Stop Recording"}, {2, L"Cancel Transcription"}};
    for (const auto &[recording, action] : expected) {
        HMENU menu = buildMenu(recording, L"5 sessions · 01m 40s · $0.01");
        const bool ok = menu && GetMenuItemCount(menu) == 8 && label(menu, 3) == action &&
                        GetMenuItemID(menu, 3) == toggle && GetMenuItemID(menu, 7) == quit &&
                        (GetMenuState(menu, 0, MF_BYPOSITION) & MF_GRAYED) &&
                        label(menu, 1) == L"5 sessions · 01m 40s · $0.01" &&
                        GetMenuDefaultItem(menu, FALSE, 0) == open;
        if (menu) DestroyMenu(menu);
        if (!ok) {
            failure = "Notification area: the menu does not offer the expected commands.";
            return false;
        }
    }
    HMENU bare = buildMenu(0, L"");
    const bool summaryHidden = bare && GetMenuItemCount(bare) == 7;
    if (bare) DestroyMenu(bare);
    if (!summaryHidden) failure = "Notification area: an empty summary still shows a line.";
    return summaryHidden;
}

} // namespace jsti::tray
