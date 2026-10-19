#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "WindowsOnboarding.hpp"
#include <appmodel.h>
#include <shellapi.h>
#include <mutex>
#include <new>
#include <vector>

bool jsti_text_output_available();
void jsti_show_text_output(HWND owner);
int jsti_window_recording_state();

namespace {
constexpr wchar_t consentKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone";

// "Allow" or "Deny" under a ConsentStore key; anything else is unknown.
int32_t consent(HKEY root, const std::wstring &key) {
    wchar_t value[16]{};
    DWORD size = sizeof(value);
    if (RegGetValueW(root, key.c_str(), L"Value", RRF_RT_REG_SZ, nullptr, value, &size) != ERROR_SUCCESS) return -1;
    if (_wcsicmp(value, L"Allow") == 0) return 1;
    if (_wcsicmp(value, L"Deny") == 0) return 0;
    return -1;
}

// LetAppsAccessMicrophone: 0 user in control, 1 force allow, 2 force deny.
int32_t microphonePolicy() {
    DWORD value = 0, size = sizeof(value);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Policies\\Microsoft\\Windows\\AppPrivacy",
                     L"LetAppsAccessMicrophone", RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS) return -1;
    return value == 2 ? 0 : value == 1 ? 1 : -1;
}

int32_t elevated() {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return -1;
    TOKEN_ELEVATION elevation{};
    DWORD size = 0;
    const BOOL read = GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &size);
    CloseHandle(token);
    return read ? (elevation.TokenIsElevated ? 1 : 0) : -1;
}

// Windows shows notifications unless the account turned them off.
int32_t notifications() {
    DWORD value = 1, size = sizeof(value);
    const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications", L"ToastEnabled", RRF_RT_REG_DWORD,
        nullptr, &value, &size);
    if (status == ERROR_FILE_NOT_FOUND) return 1;
    return status == ERROR_SUCCESS ? (value ? 1 : 0) : -1;
}

enum { listID = 1900, introID, detailID, remedyID, checkID, summaryID };
constexpr UINT refreshMessage = WM_APP + 89;
struct Row { std::wstring title, status, detail, guidance, remediation; int32_t page = 0; bool blocking = false; };
struct Configuration {
    std::vector<Row> rows;
    std::wstring summary;
    JSTIPermissionsCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex mutex;
Configuration current;
HWND panelWindow = nullptr;
struct Panel { std::vector<Row> rows; HFONT font = nullptr; int selected = 0; bool awaitingReturn = false; };
int px(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void check(HWND window) {
    JSTIPermissionsCallback callback;
    void *context;
    { std::lock_guard<std::mutex> lock(mutex); callback = current.callback; context = current.context; }
    if (!callback) return;
    SetDlgItemTextW(window, summaryID, L"Checking...");
    callback(JSTI_PERMISSIONS_COMMAND_CHECK, context);
}

void layout(HWND window) {
    RECT rect{};
    GetClientRect(window, &rect);
    const int margin = px(window, 20), gap = px(window, 10), row = px(window, 32);
    const int width = rect.right - margin * 2, bottom = rect.bottom - margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(introID, margin, margin, width, px(window, 40));
    const int listTop = margin + px(window, 48);
    const int detailTop = std::max(listTop + px(window, 120), bottom - row * 2 - gap * 3 - px(window, 150));
    move(listID, margin, listTop, width, detailTop - listTop - gap);
    move(detailID, margin, detailTop, width, px(window, 110));
    const int buttons = detailTop + px(window, 110) + gap;
    move(remedyID, margin, buttons, px(window, 260), row);
    move(checkID, margin + px(window, 270), buttons, px(window, 140), row);
    move(summaryID, margin, buttons + row + gap, width, px(window, 40));
    move(IDCANCEL, rect.right - margin - px(window, 100), bottom - row, px(window, 100), row);
}

void selected(HWND window, Panel &panel) {
    const bool valid = panel.selected >= 0 && static_cast<size_t>(panel.selected) < panel.rows.size();
    const Row *row = valid ? &panel.rows[static_cast<size_t>(panel.selected)] : nullptr;
    const std::wstring detail = row ? row->detail + L"\r\n\r\n" + row->guidance : L"";
    SetDlgItemTextW(window, detailID, detail.c_str());
    HWND remedy = GetDlgItem(window, remedyID);
    const bool canRemedy = row && row->page != JSTI_SETTINGS_NONE && !row->remediation.empty();
    SetWindowTextW(remedy, canRemedy ? row->remediation.c_str() : L"Nothing to change");
    EnableWindow(remedy, canRemedy);
}

void refresh(HWND window, Panel &panel) {
    std::wstring summary;
    { std::lock_guard<std::mutex> lock(mutex); panel.rows = current.rows; summary = current.summary; }
    SendDlgItemMessageW(window, listID, LB_RESETCONTENT, 0, 0);
    for (const Row &row : panel.rows) {
        const std::wstring line = (row.blocking ? L"! " : L"") + row.title + L" \u2014 " + row.status;
        SendDlgItemMessageW(window, listID, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(line.c_str()));
    }
    if (panel.rows.empty()) panel.selected = -1;
    else panel.selected = std::min(std::max(0, panel.selected), static_cast<int>(panel.rows.size()) - 1);
    SendDlgItemMessageW(window, listID, LB_SETCURSEL, panel.selected, 0);
    SetDlgItemTextW(window, summaryID, summary.c_str());
    selected(window, panel);
}

bool controls(HWND window, Panel &panel) {
    auto add = [&](const wchar_t *type, const wchar_t *label, int id, DWORD style) {
        return CreateWindowExW(0, type, label, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
    };
    const bool okay = add(L"STATIC", L"What Windows lets Just Speak to It do. Items marked ! stop dictation from "
            L"working; the rest are optional.", introID, SS_LEFT)
        && add(L"LISTBOX", L"", listID, LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP | WS_BORDER)
        && add(L"STATIC", L"", detailID, SS_LEFT)
        && add(L"BUTTON", L"Nothing to change", remedyID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"BUTTON", L"Check &again", checkID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"STATIC", L"", summaryID, SS_LEFT)
        && add(L"BUTTON", L"Close", IDCANCEL, BS_DEFPUSHBUTTON | WS_TABSTOP);
    if (!okay) return false;
    panel.font = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE,
        FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (panel.font) EnumChildWindows(window, [](HWND child, LPARAM font) -> BOOL {
        SendMessageW(child, WM_SETFONT, static_cast<WPARAM>(font), TRUE); return TRUE;
    }, reinterpret_cast<LPARAM>(panel.font));
    refresh(window, panel);
    layout(window);
    return true;
}

// The row's fix. A system page is checked again when the user comes back.
void remedy(HWND window, Panel &panel) {
    if (panel.selected < 0 || static_cast<size_t>(panel.selected) >= panel.rows.size()) return;
    const int32_t page = panel.rows[static_cast<size_t>(panel.selected)].page;
    HWND owner = GetWindow(window, GW_OWNER);
    switch (page) {
    case JSTI_SETTINGS_MICROPHONE: case JSTI_SETTINGS_NOTIFICATIONS: case JSTI_SETTINGS_STARTUP_APPS:
        if (jsti_open_system_settings(page) == 0) panel.awaitingReturn = true;
        else SetDlgItemTextW(window, summaryID, L"Windows Settings could not be opened.");
        return;
    case JSTI_SETTINGS_GENERAL:
        jsti_window_show_page(JSTI_PAGE_GENERAL);
        return;
    case JSTI_SETTINGS_TEXT_OUTPUT:
        if (!owner || !jsti_text_output_available() || !IsWindowEnabled(owner) || jsti_window_recording_state()) {
            SetDlgItemTextW(window, summaryID, L"Text output can be changed when no recording is running.");
            return;
        }
        EnableWindow(window, FALSE);
        jsti_show_text_output(owner);
        if (!IsWindow(window)) return;
        EnableWindow(window, TRUE);
        SetActiveWindow(window);
        check(window);
        return;
    default: return;
    }
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto *panel = reinterpret_cast<Panel *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        panel = static_cast<Panel *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(panel));
    }
    if (!panel) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: return controls(window, *panel) ? 0 : -1;
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const auto *rect = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top,
            SWP_NOACTIVATE | SWP_NOZORDER);
        layout(window);
        return 0;
    }
    case WM_GETMINMAXINFO:
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {px(window, 560), px(window, 520)};
        return 0;
    case WM_ACTIVATE:
        if (LOWORD(wparam) != WA_INACTIVE && panel->awaitingReturn) {
            panel->awaitingReturn = false;
            check(window);
        }
        break;
    case refreshMessage: refresh(window, *panel); return 0;
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case IDCANCEL: DestroyWindow(window); return 0;
        case checkID: check(window); return 0;
        case remedyID: remedy(window, *panel); return 0;
        case listID:
            if (HIWORD(wparam) == LBN_SELCHANGE) {
                panel->selected = static_cast<int>(SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0));
                selected(window, *panel);
            }
            return 0;
        }
        break;
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_NCDESTROY: {
        { std::lock_guard<std::mutex> lock(mutex); if (panelWindow == window) panelWindow = nullptr; }
        if (panel->font) DeleteObject(panel->font);
        SetWindowLongPtrW(window, GWLP_USERDATA, 0);
        delete panel;
        return DefWindowProcW(window, message, wparam, lparam);
    }
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

int32_t jsti_system_permissions(JSTISystemPermissions *permissions) {
    if (!permissions) return -1;
    JSTISystemPermissions result{};
    result.microphone_device = consent(HKEY_LOCAL_MACHINE, consentKey);
    result.microphone_user = consent(HKEY_CURRENT_USER, consentKey);
    wchar_t family[PACKAGE_FAMILY_NAME_MAX_LENGTH + 1]{};
    UINT32 length = PACKAGE_FAMILY_NAME_MAX_LENGTH + 1;
    result.packaged = GetCurrentPackageFamilyName(&length, family) == ERROR_SUCCESS ? 1 : 0;
    const std::wstring app = std::wstring(consentKey) + L"\\" + (result.packaged ? family : L"NonPackaged");
    result.microphone_app = consent(HKEY_CURRENT_USER, app);
    result.microphone_policy = microphonePolicy();
    result.elevated = elevated();
    result.notifications = notifications();
    *permissions = result;
    return 0;
}

int32_t jsti_open_system_settings(int32_t page) {
    const wchar_t *uri = page == JSTI_SETTINGS_MICROPHONE ? L"ms-settings:privacy-microphone"
        : page == JSTI_SETTINGS_NOTIFICATIONS ? L"ms-settings:notifications"
        : page == JSTI_SETTINGS_STARTUP_APPS ? L"ms-settings:startupapps" : nullptr;
    if (!uri) return -1;
    const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", uri, nullptr, nullptr,
                                                                SW_SHOWNORMAL));
    return opened > 32 ? 0 : -1;
}

int32_t jsti_permissions_configure(JSTIPermissionsCallback callback, void *context) {
    if (!callback) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    current.callback = callback;
    current.context = context;
    return 0;
}

void jsti_permissions_clear(void) {
    std::lock_guard<std::mutex> lock(mutex);
    current.callback = nullptr;
    current.context = nullptr;
}

int32_t jsti_permissions_set_rows(const JSTIPermissionRow *rows, size_t count, const char *summary) {
    if ((!rows && count) || count > 32 || !summary) return -1;
    try {
        std::vector<Row> copied;
        for (size_t i = 0; i < count; ++i) {
            Row row;
            if (!jsti::wide(rows[i].title, row.title) || !jsti::wide(rows[i].status, row.status) ||
                !jsti::wide(rows[i].detail, row.detail) || !jsti::wide(rows[i].guidance, row.guidance) ||
                !jsti::wide(rows[i].remediation, row.remediation)) return -1;
            row.page = rows[i].settings_page;
            row.blocking = rows[i].blocking != 0;
            copied.push_back(std::move(row));
        }
        std::wstring text;
        if (!jsti::wide(summary, text)) return -1;
        std::lock_guard<std::mutex> lock(mutex);
        current.rows = std::move(copied);
        current.summary = std::move(text);
        if (panelWindow) PostMessageW(panelWindow, refreshMessage, 0, 0);
        return 0;
    } catch (const std::exception &) { return -1; }
}

void jsti_show_permissions(HWND owner) {
    HWND existing;
    { std::lock_guard<std::mutex> lock(mutex); existing = panelWindow; }
    if (existing) {
        ShowWindow(existing, SW_SHOWNORMAL);
        SetForegroundWindow(existing);
        check(existing);
        return;
    }
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItPermissions";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        jsti_window_update(jsti::systemError("Registering the Permissions window").c_str(), nullptr, -1);
        return;
    }
    auto *panel = new (std::nothrow) Panel;
    if (!panel) return;
    // WM_NCDESTROY frees the panel, including when creation fails after WM_NCCREATE.
    HWND window = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, type.lpszClassName, L"Permissions",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME, CW_USEDEFAULT, CW_USEDEFAULT,
        px(owner, 640), px(owner, 600), owner, nullptr, type.hInstance, panel);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening the Permissions window").c_str(), nullptr, -1);
        return;
    }
    { std::lock_guard<std::mutex> lock(mutex); panelWindow = window; }
    ShowWindow(window, SW_SHOWNORMAL);
    SetFocus(GetDlgItem(window, listID));
    check(window);
}

bool jsti_permissions_message(MSG *message) {
    HWND window;
    { std::lock_guard<std::mutex> lock(mutex); window = panelWindow; }
    return window && IsDialogMessageW(window, message);
}
