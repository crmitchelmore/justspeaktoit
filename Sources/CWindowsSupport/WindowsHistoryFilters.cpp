#include "include/CWindowsSupport.h"
#include "WindowsHistoryFilters.hpp"
#include "WindowsWindowChrome.hpp"
#include <commctrl.h>
#include <cstdio>
#include <mutex>
#include <vector>

namespace {
enum Control { modelsID = 610, errorsID, fromID, throughID, resetID, applyID };
struct Model { std::string id; std::wstring name; bool selected; };
struct Configuration {
    std::vector<Model> models;
    bool errors = false;
    std::string from, through;
};
std::mutex mutex;
Configuration configuration;
HWND panelWindow = nullptr;
struct Panel {
    Configuration config;
    std::function<void(const std::string &)> apply;
    HBRUSH background = nullptr;
    ~Panel() { if (background) DeleteObject(background); }
};
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
std::string json(const std::string &value) {
    std::string result = "\"";
    for (unsigned char byte : value) {
        if (byte == '"' || byte == '\\') { result += '\\'; result += static_cast<char>(byte); }
        else if (byte < 32) {
            char escaped[7]{};
            std::snprintf(escaped, sizeof(escaped), "\\u%04x", byte);
            result += escaped;
        } else result += static_cast<char>(byte);
    }
    return result + '"';
}
void date(HWND window, int id, const std::string &day) {
    SYSTEMTIME value{};
    unsigned year = 0, month = 0, number = 0;
    if (day.empty() || std::sscanf(day.c_str(), "%u-%u-%u", &year, &month, &number) != 3) {
        DateTime_SetSystemtime(GetDlgItem(window, id), GDT_NONE, &value);
        return;
    }
    value.wYear = static_cast<WORD>(year);
    value.wMonth = static_cast<WORD>(month);
    value.wDay = static_cast<WORD>(number);
    DateTime_SetSystemtime(GetDlgItem(window, id), GDT_VALID, &value);
}
std::string day(HWND window, int id) {
    SYSTEMTIME value{};
    if (DateTime_GetSystemtime(GetDlgItem(window, id), &value) != GDT_VALID) return {};
    char text[16]{};
    std::snprintf(text, sizeof(text), "%04u-%02u-%02u", value.wYear, value.wMonth, value.wDay);
    return text;
}
std::string payload(HWND window, const Panel &panel) {
    std::string models = "[";
    bool first = true;
    for (size_t index = 0; index < panel.config.models.size(); ++index) {
        if (SendDlgItemMessageW(window, modelsID, LB_GETSEL, index, 0) <= 0) continue;
        if (!first) models += ',';
        models += json(panel.config.models[index].id);
        first = false;
    }
    const bool errors = SendDlgItemMessageW(window, errorsID, BM_GETCHECK, 0, 0) == BST_CHECKED;
    return "{\"models\":" + models + "],\"errorsOnly\":" + (errors ? "true" : "false")
        + ",\"fromDay\":" + json(day(window, fromID)) + ",\"throughDay\":" + json(day(window, throughID)) + "}";
}
void layout(HWND window) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int margin = scale(window, 16), width = bounds.right - 2 * margin;
    auto place = [&](int id, int top, int height) {
        MoveWindow(GetDlgItem(window, id), margin, top, width, height, TRUE);
    };
    const int listHeight = std::max(scale(window, 48),
        std::min(scale(window, 152), static_cast<int>(bounds.bottom) - scale(window, 284)));
    place(601, scale(window, 16), scale(window, 24));
    place(modelsID, scale(window, 44), listHeight);
    int top = scale(window, 44) + listHeight + scale(window, 12);
    place(errorsID, top, scale(window, 30)); top += scale(window, 40);
    place(602, top, scale(window, 22)); top += scale(window, 26);
    place(fromID, top, scale(window, 30)); top += scale(window, 40);
    place(603, top, scale(window, 22)); top += scale(window, 26);
    place(throughID, top, scale(window, 30)); top += scale(window, 48);
    const int gap = scale(window, 8), half = (width - gap) / 2;
    MoveWindow(GetDlgItem(window, resetID), margin, top, half, scale(window, 32), TRUE);
    MoveWindow(GetDlgItem(window, applyID), margin + half + gap, top, half, scale(window, 32), TRUE);
    for (HWND child = GetWindow(window, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
        SendMessageW(child, WM_SETFONT,
            reinterpret_cast<WPARAM>(jsti::chrome::font(jsti::chrome::Font::body, GetDpiForWindow(window))), TRUE);
    }
}
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto *panel = reinterpret_cast<Panel *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        auto *input = static_cast<Panel *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        panel = new Panel;
        panel->config = std::move(input->config);
        panel->apply = std::move(input->apply);
        panel->background = input->background;
        input->background = nullptr;
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(panel));
    }
    if (!panel) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: {
        auto add = [&](const wchar_t *kind, const wchar_t *label, DWORD style, int id) {
            return CreateWindowExW(0, kind, label, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10,
                window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        };
        if (!add(L"STATIC", L"&Models (none selected means all)", 0, 601) ||
            !add(L"LISTBOX", L"", LBS_MULTIPLESEL | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_BORDER | WS_TABSTOP, modelsID) ||
            !add(L"BUTTON", L"Only recordings with &errors", BS_AUTOCHECKBOX | WS_TABSTOP, errorsID) ||
            !add(L"STATIC", L"&From (unchecked means no start date)", 0, 602) ||
            !add(DATETIMEPICK_CLASSW, L"", DTS_SHOWNONE | WS_TABSTOP, fromID) ||
            !add(L"STATIC", L"&Through (unchecked means no end date)", 0, 603) ||
            !add(DATETIMEPICK_CLASSW, L"", DTS_SHOWNONE | WS_TABSTOP, throughID) ||
            !add(L"BUTTON", L"&Reset filters", BS_PUSHBUTTON | WS_TABSTOP, resetID) ||
            !add(L"BUTTON", L"&Apply filters", BS_DEFPUSHBUTTON | WS_TABSTOP, applyID)) return -1;
        for (size_t index = 0; index < panel->config.models.size(); ++index) {
            const auto &model = panel->config.models[index];
            SendDlgItemMessageW(window, modelsID, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(model.name.c_str()));
            SendDlgItemMessageW(window, modelsID, LB_SETSEL, model.selected, index);
        }
        SendDlgItemMessageW(window, errorsID, BM_SETCHECK, panel->config.errors ? BST_CHECKED : BST_UNCHECKED, 0);
        date(window, fromID, panel->config.from); date(window, throughID, panel->config.through);
        layout(window);
        return 0;
    }
    case WM_SIZE: layout(window); return 0;
    case WM_ERASEBKGND: {
        RECT bounds{}; GetClientRect(window, &bounds);
        FillRect(reinterpret_cast<HDC>(wparam), &bounds, panel->background);
        return 1;
    }
    case WM_DPICHANGED: {
        const auto *bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        layout(window);
        return 0;
    }
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORLISTBOX:
    case WM_CTLCOLORBTN: {
        const auto &palette = jsti::chrome::palette();
        SetTextColor(reinterpret_cast<HDC>(wparam), palette.text);
        SetBkColor(reinterpret_cast<HDC>(wparam), palette.card);
        return reinterpret_cast<LRESULT>(panel->background);
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; }
        if ((LOWORD(wparam) == applyID || LOWORD(wparam) == IDOK || LOWORD(wparam) == resetID) &&
            IsWindowEnabled(GetDlgItem(window, applyID))) {
            const std::string value = LOWORD(wparam) == resetID
                ? "{\"models\":[],\"errorsOnly\":false,\"fromDay\":\"\",\"throughDay\":\"\"}" : payload(window, *panel);
            panel->apply(value);
            DestroyWindow(window);
        }
        return 0;
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_NCDESTROY:
        if (panelWindow == window) panelWindow = nullptr;
        SetWindowLongPtrW(window, GWLP_USERDATA, 0);
        delete panel;
        break;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

extern "C" int jsti_window_set_history_filters(
    const JSTIHistoryFilterModel *models, size_t count, int errors, const char *from, const char *through
) {
    if (count && !models) return -1;
    Configuration replacement;
    replacement.errors = errors != 0;
    replacement.from = from ? from : "";
    replacement.through = through ? through : "";
    for (size_t index = 0; index < count; ++index) {
        if (!models[index].id || !models[index].name) return -1;
        std::wstring name;
        if (!jsti::wide(models[index].name, name)) return -1;
        replacement.models.push_back({models[index].id, std::move(name), models[index].selected != 0});
    }
    { std::lock_guard<std::mutex> lock(mutex); configuration = std::move(replacement); }
    return jsti_window_update(nullptr, nullptr, -1);
}

std::wstring jsti_history_filters_label() {
    std::lock_guard<std::mutex> lock(mutex);
    size_t count = configuration.errors + !configuration.from.empty() + !configuration.through.empty();
    for (const auto &model : configuration.models) count += model.selected;
    return count ? L"Fil&ters (" + std::to_wstring(count) + L")" : L"Fil&ters...";
}

bool jsti_history_filters_active() {
    std::lock_guard<std::mutex> lock(mutex);
    if (configuration.errors || !configuration.from.empty() || !configuration.through.empty()) return true;
    return std::any_of(configuration.models.begin(), configuration.models.end(), [](const Model &model) {
        return model.selected;
    });
}

void jsti_history_filters_enabled(bool enabled) {
    if (!panelWindow) return;
    for (int id : {modelsID, errorsID, fromID, throughID, resetID, applyID}) {
        EnableWindow(GetDlgItem(panelWindow, id), enabled);
    }
}

bool jsti_history_filters_message(MSG *message) {
    return panelWindow && IsDialogMessageW(panelWindow, message);
}

static bool openHistoryFilters(
    HWND owner, std::function<void(const std::string &)> apply, bool visible, std::string &error
) {
    if (panelWindow) {
        if (visible) { SetFocus(panelWindow); return true; }
        error = "History filter self-test requires a closed filter panel.";
        return false;
    }
    INITCOMMONCONTROLSEX common{sizeof(common), ICC_DATE_CLASSES};
    InitCommonControlsEx(&common);
    WNDCLASSW type{};
    type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakHistoryFilters"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        error = "Could not create History filter controls.";
        return false;
    }
    Panel input;
    { std::lock_guard<std::mutex> lock(mutex); input.config = configuration; }
    input.apply = std::move(apply);
    input.background = CreateSolidBrush(jsti::chrome::palette().card);
    RECT ownerBounds{}, work{};
    GetWindowRect(owner, &ownerBounds);
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (GetMonitorInfoW(MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST), &monitor)) work = monitor.rcWork;
    else if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) {
        error = "Could not determine the screen size for History filters.";
        return false;
    }
    const int width = std::min(scale(owner, 440), static_cast<int>(work.right - work.left));
    const int height = std::min(scale(owner, 468), static_cast<int>(work.bottom - work.top));
    const int left = std::max(work.left, std::min(ownerBounds.right - width, work.right - width));
    const int top = std::max(work.top, std::min(ownerBounds.top + scale(owner, 80), work.bottom - height));
    panelWindow = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT, type.lpszClassName, L"Filter History",
        WS_POPUP | WS_CAPTION | WS_SYSMENU, left, top, width, height, owner, nullptr, type.hInstance, &input);
    if (!panelWindow) {
        error = "Could not open History filters.";
        return false;
    }
    if (visible) {
        ShowWindow(panelWindow, SW_SHOWNORMAL);
        SetFocus(GetDlgItem(panelWindow, modelsID));
    }
    return true;
}

void jsti_show_history_filters(HWND owner, std::function<void(const std::string &)> apply) {
    std::string error;
    if (openHistoryFilters(owner, std::move(apply), true, error)) return;
    std::wstring message;
    jsti::wide(error.c_str(), message);
    MessageBoxW(owner, message.c_str(), L"History filters", MB_OK | MB_ICONERROR);
}

bool jsti_history_filters_self_test(HWND owner, std::string &error) {
    Configuration original;
    {
        std::lock_guard<std::mutex> lock(mutex);
        original = configuration;
        configuration = {};
        configuration.models = {{"model/a", L"Model A", false}, {"model/\"quoted\"\n", L"Model B", false}};
    }
    bool passed = openHistoryFilters(owner, [](const std::string &) {}, false, error);
    if (passed) {
        auto *panel = reinterpret_cast<Panel *>(GetWindowLongPtrW(panelWindow, GWLP_USERDATA));
        SYSTEMTIME value{};
        passed = SendDlgItemMessageW(panelWindow, modelsID, LB_GETCOUNT, 0, 0) == 2 &&
            DateTime_GetSystemtime(GetDlgItem(panelWindow, fromID), &value) == GDT_NONE &&
            DateTime_GetSystemtime(GetDlgItem(panelWindow, throughID), &value) == GDT_NONE;
        SendDlgItemMessageW(panelWindow, modelsID, LB_SETSEL, TRUE, 1);
        SendDlgItemMessageW(panelWindow, errorsID, BM_SETCHECK, BST_CHECKED, 0);
        date(panelWindow, fromID, "2026-03-08"); date(panelWindow, throughID, "2026-03-08");
        passed = passed && payload(panelWindow, *panel) ==
            "{\"models\":[\"model/\\\"quoted\\\"\\u000a\"],\"errorsOnly\":true,"
            "\"fromDay\":\"2026-03-08\",\"throughDay\":\"2026-03-08\"}";
        jsti_history_filters_enabled(false);
        passed = passed && !IsWindowEnabled(GetDlgItem(panelWindow, applyID)) &&
            !IsWindowEnabled(GetDlgItem(panelWindow, modelsID));
        DestroyWindow(panelWindow);
        if (!passed) error = "History filter controls lost model identities, dates, escaping or busy-state gating.";
    }
    { std::lock_guard<std::mutex> lock(mutex); configuration = std::move(original); }
    return passed;
}
