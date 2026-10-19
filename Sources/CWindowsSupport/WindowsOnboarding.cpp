#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "WindowsOnboarding.hpp"
#include "WindowsTray.hpp"
#include <mutex>
#include <new>

bool jsti_postprocessing_available();
void jsti_show_postprocessing(HWND owner);
bool jsti_text_output_available();
void jsti_show_text_output(HWND owner);
bool jsti_hotkey_available();
void jsti_show_hotkey_settings(HWND owner);
bool jsti_local_models_available();
void jsti_show_local_models(HWND owner);
int jsti_window_recording_state();

namespace {
enum { progressID = 2000, titleID, detailID, statusID, firstActionID, secondActionID, thirdActionID,
    backID, skipID, nextID };
constexpr UINT refreshMessage = WM_APP + 88;
struct Page {
    int32_t step = -1;
    std::wstring title, progress, detail, status, actionTitles[3];
    int32_t actions[3]{};
    bool hasPrevious = false, isLast = false, isOptional = false;
};
struct Configuration {
    Page page;
    JSTIGuideCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex mutex;
Configuration current;
HWND guideWindow = nullptr;
struct Guide { Page page; HFONT font = nullptr, titleFont = nullptr; bool awaitingReturn = false; };
int px(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void notify(int32_t command, int32_t step, int32_t value) {
    JSTIGuideCallback callback;
    void *context;
    { std::lock_guard<std::mutex> lock(mutex); callback = current.callback; context = current.context; }
    if (callback) callback(command, step, value, context);
}

void layout(HWND window) {
    auto *guide = reinterpret_cast<Guide *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (!guide) return;
    RECT rect{};
    GetClientRect(window, &rect);
    const int margin = px(window, 24), gap = px(window, 10), row = px(window, 32);
    const int width = rect.right - margin * 2, bottom = rect.bottom - margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    int y = margin;
    move(progressID, margin, y, width, px(window, 20)); y += px(window, 24);
    move(titleID, margin, y, width, px(window, 34)); y += px(window, 42);
    move(detailID, margin, y, width, px(window, 80)); y += px(window, 88);
    int visible = 0;
    for (int index = 0; index < 3; ++index) {
        if (guide->page.actionTitles[index].empty()) continue;
        move(firstActionID + index, margin, y + visible * (row + gap), std::min(width, px(window, 320)), row);
        ++visible;
    }
    y += visible * (row + gap);
    move(statusID, margin, y, width, std::max(px(window, 44), bottom - row - gap - y));
    const int button = px(window, 110);
    move(backID, margin, bottom - row, button, row);
    move(skipID, rect.right - margin - button * 2 - gap, bottom - row, button, row);
    move(nextID, rect.right - margin - button, bottom - row, button, row);
}

void refresh(HWND window, Guide &guide) {
    { std::lock_guard<std::mutex> lock(mutex); guide.page = current.page; }
    const Page &page = guide.page;
    SetDlgItemTextW(window, progressID, page.progress.c_str());
    SetDlgItemTextW(window, titleID, page.title.c_str());
    SetDlgItemTextW(window, detailID, page.detail.c_str());
    SetDlgItemTextW(window, statusID, page.status.c_str());
    for (int index = 0; index < 3; ++index) {
        HWND button = GetDlgItem(window, firstActionID + index);
        SetWindowTextW(button, page.actionTitles[index].c_str());
        ShowWindow(button, page.actionTitles[index].empty() ? SW_HIDE : SW_SHOWNA);
    }
    EnableWindow(GetDlgItem(window, backID), page.hasPrevious);
    ShowWindow(GetDlgItem(window, skipID), page.isLast ? SW_HIDE : SW_SHOWNA);
    SetDlgItemTextW(window, nextID, page.isLast ? L"&Finish" : page.isOptional ? L"&Next (skip)" : L"&Next");
    layout(window);
}

bool controls(HWND window, Guide &guide) {
    auto add = [&](const wchar_t *type, const wchar_t *label, int id, DWORD style) {
        return CreateWindowExW(0, type, label, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
    };
    const bool okay = add(L"STATIC", L"", progressID, SS_LEFT)
        && add(L"STATIC", L"Loading setup...", titleID, SS_LEFT)
        && add(L"STATIC", L"", detailID, SS_LEFT)
        && add(L"BUTTON", L"", firstActionID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"BUTTON", L"", secondActionID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"BUTTON", L"", thirdActionID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"STATIC", L"", statusID, SS_LEFT)
        && add(L"BUTTON", L"&Back", backID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"BUTTON", L"&Skip setup", skipID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"BUTTON", L"&Next", nextID, BS_DEFPUSHBUTTON | WS_TABSTOP);
    if (!okay) return false;
    const int dpi = static_cast<int>(GetDpiForWindow(window));
    guide.font = CreateFontW(-MulDiv(10, dpi, 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    guide.titleFont = CreateFontW(-MulDiv(16, dpi, 72), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (guide.font) EnumChildWindows(window, [](HWND child, LPARAM font) -> BOOL {
        SendMessageW(child, WM_SETFONT, static_cast<WPARAM>(font), TRUE); return TRUE;
    }, reinterpret_cast<LPARAM>(guide.font));
    if (guide.titleFont) {
        SendDlgItemMessageW(window, titleID, WM_SETFONT, reinterpret_cast<WPARAM>(guide.titleFont), TRUE);
    }
    refresh(window, guide);
    return true;
}

// Opens one of the app's modal settings dialogs over the main window. The
// guide is disabled meanwhile so a second dialog cannot stack on the first.
bool modal(HWND window, bool available, void (*show)(HWND)) {
    HWND owner = GetWindow(window, GW_OWNER);
    if (!owner || !available || !IsWindowEnabled(owner) || jsti_window_recording_state() != 0) {
        SetDlgItemTextW(window, statusID, L"This setting can be changed when no recording or other settings "
                                          L"window is open.");
        return false;
    }
    EnableWindow(window, FALSE);
    show(owner);
    if (!IsWindow(window)) return false;
    EnableWindow(window, TRUE);
    SetActiveWindow(window);
    return true;
}

// Native actions run here; the host then hears of every action so it can
// refresh the page's status, and performs the ones only it can.
void perform(HWND window, int index) {
    auto *guide = reinterpret_cast<Guide *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (!guide || index < 0 || index > 2) return;
    const int32_t step = guide->page.step, action = guide->page.actions[index];
    HWND owner = GetWindow(window, GW_OWNER);
    switch (action) {
    case JSTI_GUIDE_ACTION_MICROPHONE_PRIVACY:
        if (jsti_open_system_settings(JSTI_SETTINGS_MICROPHONE) != 0) {
            SetDlgItemTextW(window, statusID, L"Windows Settings could not be opened.");
        } else {
            guide->awaitingReturn = true;
        }
        break;
    case JSTI_GUIDE_ACTION_MICROPHONE_PICKER: jsti_window_show_page(JSTI_PAGE_GENERAL); break;
    case JSTI_GUIDE_ACTION_TEXT_OUTPUT:
        if (!modal(window, jsti_text_output_available(), jsti_show_text_output)) return;
        break;
    case JSTI_GUIDE_ACTION_LOCAL_MODELS:
        if (!modal(window, jsti_local_models_available(), jsti_show_local_models)) return;
        break;
    case JSTI_GUIDE_ACTION_SHORTCUT:
        if (!modal(window, jsti_hotkey_available(), jsti_show_hotkey_settings)) return;
        break;
    case JSTI_GUIDE_ACTION_POST_PROCESSING:
        if (!modal(window, jsti_postprocessing_available(), jsti_show_postprocessing)) return;
        break;
    case JSTI_GUIDE_ACTION_PERMISSIONS: if (owner) jsti_show_permissions(owner); break;
    case JSTI_GUIDE_ACTION_TEST_DICTATION:
        // As the tray's Start/Stop. The app never types into its own windows,
        // so the transcript stays in the main window, ready to copy.
        if (owner) PostMessageW(owner, jsti::tray::commandMessage, jsti::tray::toggle, 0);
        break;
    case JSTI_GUIDE_ACTION_HOST_API_KEYS: break;
    default: return;
    }
    notify(JSTI_GUIDE_COMMAND_ACTION, step, action);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto *guide = reinterpret_cast<Guide *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        guide = static_cast<Guide *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(guide));
    }
    if (!guide) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: return controls(window, *guide) ? 0 : -1;
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const auto *rect = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top,
            SWP_NOACTIVATE | SWP_NOZORDER);
        layout(window);
        return 0;
    }
    case WM_GETMINMAXINFO:
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {px(window, 560), px(window, 560)};
        return 0;
    case WM_ACTIVATE:
        // Back from Windows Settings: the host checks the step again.
        if (LOWORD(wparam) != WA_INACTIVE && guide->awaitingReturn) {
            guide->awaitingReturn = false;
            notify(JSTI_GUIDE_COMMAND_ACTION, guide->page.step, JSTI_GUIDE_ACTION_NONE);
        }
        break;
    case refreshMessage: refresh(window, *guide); return 0;
    case WM_COMMAND: {
        const int32_t step = guide->page.step;
        switch (LOWORD(wparam)) {
        case IDCANCEL: DestroyWindow(window); return 0;
        case firstActionID: case secondActionID: case thirdActionID:
            if (HIWORD(wparam) == BN_CLICKED) perform(window, LOWORD(wparam) - firstActionID);
            return 0;
        case backID: if (HIWORD(wparam) == BN_CLICKED) notify(JSTI_GUIDE_COMMAND_BACK, step, 0); return 0;
        case skipID:
            if (HIWORD(wparam) != BN_CLICKED) return 0;
            notify(JSTI_GUIDE_COMMAND_SKIP, step, 0);
            DestroyWindow(window);
            return 0;
        case nextID:
            if (HIWORD(wparam) != BN_CLICKED) return 0;
            if (!guide->page.isLast) { notify(JSTI_GUIDE_COMMAND_NEXT, step, 0); return 0; }
            notify(JSTI_GUIDE_COMMAND_FINISH, step, 0);
            DestroyWindow(window);
            return 0;
        }
        break;
    }
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_NCDESTROY: {
        { std::lock_guard<std::mutex> lock(mutex); if (guideWindow == window) guideWindow = nullptr; }
        if (guide->font) DeleteObject(guide->font);
        if (guide->titleFont) DeleteObject(guide->titleFont);
        SetWindowLongPtrW(window, GWLP_USERDATA, 0);
        delete guide;
        return DefWindowProcW(window, message, wparam, lparam);
    }
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

bool copy(const char *text, std::wstring &result) { return jsti::wide(text ? text : "", result); }
}

int32_t jsti_guide_configure(JSTIGuideCallback callback, void *context) {
    if (!callback) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    current.callback = callback;
    current.context = context;
    return 0;
}

void jsti_guide_clear(void) {
    std::lock_guard<std::mutex> lock(mutex);
    current.callback = nullptr;
    current.context = nullptr;
}

int32_t jsti_guide_set_page(const JSTIGuidePage *source) {
    if (!source) return -1;
    try {
        Page page;
        page.step = source->step;
        const char *titles[3] = {source->first_title, source->second_title, source->third_title};
        const int32_t actions[3] = {source->first_action, source->second_action, source->third_action};
        if (!copy(source->title, page.title) || !copy(source->progress, page.progress) ||
            !copy(source->detail, page.detail) || !copy(source->status, page.status)) return -1;
        for (int index = 0; index < 3; ++index) {
            if (!copy(titles[index], page.actionTitles[index])) return -1;
            page.actions[index] = page.actionTitles[index].empty() ? JSTI_GUIDE_ACTION_NONE : actions[index];
        }
        page.hasPrevious = source->has_previous != 0;
        page.isLast = source->is_last != 0;
        page.isOptional = source->is_optional != 0;
        std::lock_guard<std::mutex> lock(mutex);
        current.page = std::move(page);
        if (guideWindow) PostMessageW(guideWindow, refreshMessage, 0, 0);
        return 0;
    } catch (const std::exception &) { return -1; }
}

int32_t jsti_guide_set_status(int32_t step, const char *status) {
    std::wstring text;
    if (!copy(status, text)) return -1;
    try {
        std::lock_guard<std::mutex> lock(mutex);
        if (current.page.step != step) return 0;
        current.page.status = std::move(text);
        if (guideWindow) PostMessageW(guideWindow, refreshMessage, 0, 0);
        return 0;
    } catch (const std::exception &) { return -1; }
}

void jsti_show_guide(HWND owner) {
    HWND existing;
    { std::lock_guard<std::mutex> lock(mutex); existing = guideWindow; }
    if (existing) {
        ShowWindow(existing, SW_SHOWNORMAL);
        SetForegroundWindow(existing);
        return;
    }
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItSetupGuide";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        jsti_window_update(jsti::systemError("Registering the setup guide").c_str(), nullptr, -1);
        return;
    }
    auto *guide = new (std::nothrow) Guide;
    if (!guide) return;
    // A previous run's page is never shown; the host sends the page to open on.
    { std::lock_guard<std::mutex> lock(mutex); current.page = Page{}; }
    // WM_NCDESTROY frees the guide, including when creation fails after WM_NCCREATE.
    HWND window = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, type.lpszClassName,
        L"Set up Just Speak to It", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME,
        CW_USEDEFAULT, CW_USEDEFAULT, px(owner, 640), px(owner, 640), owner, nullptr, type.hInstance, guide);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening the setup guide").c_str(), nullptr, -1);
        return;
    }
    { std::lock_guard<std::mutex> lock(mutex); guideWindow = window; }
    ShowWindow(window, SW_SHOWNORMAL);
    SetFocus(GetDlgItem(window, nextID));
    notify(JSTI_GUIDE_COMMAND_OPENED, -1, 0);
}

bool jsti_guide_message(MSG *message) {
    HWND window;
    { std::lock_guard<std::mutex> lock(mutex); window = guideWindow; }
    return window && IsDialogMessageW(window, message);
}
