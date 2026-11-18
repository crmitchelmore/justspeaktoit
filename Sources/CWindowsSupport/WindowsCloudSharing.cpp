// Cloud sharing consent (CloudSharing.h): the first-use question and the window that lists, and
// withdraws, the AI providers the user allowed. The host owns every answer; these windows only
// report it. Both are a provider list, its detail and a privacy policy button, so a screen reader
// and the keyboard reach every provider however many a question names.
#include "include/CWindowsSupport.h"
#include "WindowsCloudSharing.hpp"
#include "WindowsWindowChrome.hpp"
#include "WindowsWindowInternal.hpp"
#include <algorithm>
#include <mutex>
#include <vector>

namespace {
// The control IDs are the controls' automation IDs.
enum { introID = 1900, listID, detailID, policyID, withdrawID, allowID, statusID };
constexpr UINT refreshMessage = WM_APP + 131;

struct Entry { std::string id; std::wstring name, detail, policy, withdraw; };
struct Content {
    std::wstring title, intro, footer, empty, allow, notNow;
    std::vector<Entry> rows;
};

std::mutex mutex;
Content snapshotContent;       // the allowed providers, under `mutex`
Content stagedRequest;         // the waiting question, under `mutex`
std::string stagedToken;
HWND activeWithdrawal = nullptr;

struct Dialog {
    bool consent = false;
    Content content;
    std::string token;
    int selected = 0;
    bool allowed = false;
    HFONT font = nullptr;
    JSTIWindowCallback callback = nullptr;
    void *context = nullptr;
};

int px(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

bool copyRows(const JSTICloudSharingRow *rows, size_t count, std::vector<Entry> &result) {
    if ((!rows && count) || count > 64) return false;
    for (size_t index = 0; index < count; ++index) {
        Entry entry;
        entry.id = rows[index].identifier ? rows[index].identifier : "";
        if (entry.id.empty() || !jsti::wide(rows[index].name, entry.name) || entry.name.empty() ||
            !jsti::wide(rows[index].detail ? rows[index].detail : "", entry.detail) ||
            !jsti::wide(rows[index].policy_url ? rows[index].policy_url : "", entry.policy) ||
            !jsti::wide(rows[index].withdraw_label ? rows[index].withdraw_label : "", entry.withdraw)) return false;
        if (entry.withdraw.empty()) entry.withdraw = L"Withdraw " + entry.name;
        result.push_back(std::move(entry));
    }
    return true;
}

bool httpsURL(const std::wstring &url) { return url.rfind(L"https://", 0) == 0; }

const Entry *selectedEntry(const Dialog &dialog) {
    return dialog.selected >= 0 && static_cast<size_t>(dialog.selected) < dialog.content.rows.size()
        ? &dialog.content.rows[static_cast<size_t>(dialog.selected)] : nullptr;
}

void layout(HWND window) {
    RECT rect{}; GetClientRect(window, &rect);
    const int margin = px(window, 20), gap = px(window, 10), row = px(window, 32);
    const int width = rect.right - margin * 2, height = rect.bottom;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    const int bottom = height - margin - row;
    const int statusY = bottom - gap - px(window, 44);
    const int actionY = statusY - gap - row;
    const int detailY = actionY - gap - px(window, 64);
    const int listY = margin + px(window, 60);
    move(introID, margin, margin, width, px(window, 54));
    move(listID, margin, listY, width, std::max(px(window, 90), detailY - gap - listY));
    move(detailID, margin, detailY, width, px(window, 64));
    move(policyID, margin, actionY, px(window, 300), row);
    move(withdrawID, margin + px(window, 310), actionY, px(window, 280), row);
    move(statusID, margin, statusY, width, px(window, 44));
    move(IDCANCEL, rect.right - margin - px(window, 120), bottom, px(window, 120), row);
    move(allowID, rect.right - margin - px(window, 120) - gap - px(window, 160), bottom, px(window, 160), row);
}

void selection(HWND window, Dialog &dialog) {
    const Entry *entry = selectedEntry(dialog);
    SetDlgItemTextW(window, detailID, entry ? entry->detail.c_str()
        : dialog.content.empty.c_str());
    const bool link = entry && httpsURL(entry->policy);
    SetDlgItemTextW(window, policyID, entry ? (L"&Privacy policy: " + entry->name).c_str() : L"&Privacy policy");
    EnableWindow(GetDlgItem(window, policyID), link);
    if (!dialog.consent) {
        SetDlgItemTextW(window, withdrawID, entry ? entry->withdraw.c_str() : L"Withdraw");
        EnableWindow(GetDlgItem(window, withdrawID), entry != nullptr);
    }
}

void populate(HWND window, Dialog &dialog) {
    SendDlgItemMessageW(window, listID, LB_RESETCONTENT, 0, 0);
    for (const auto &row : dialog.content.rows) {
        if (SendDlgItemMessageW(window, listID, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(row.name.c_str())) < 0) {
            SetDlgItemTextW(window, statusID, L"The provider list could not be displayed."); return;
        }
    }
    if (dialog.content.rows.empty()) dialog.selected = -1;
    else dialog.selected = std::min(std::max(0, dialog.selected), static_cast<int>(dialog.content.rows.size()) - 1);
    SendDlgItemMessageW(window, listID, LB_SETCURSEL, dialog.selected, 0);
    SetDlgItemTextW(window, statusID, dialog.content.footer.c_str());
    SetDlgItemTextW(window, introID, dialog.content.intro.c_str());
    selection(window, dialog);
}

bool controls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *type, const wchar_t *label, int id, DWORD style) {
        return CreateWindowExW(0, type, label, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
    };
    // The introduction comes before the list so it names the list for a screen reader.
    bool okay = add(L"STATIC", dialog.content.intro.c_str(), introID, SS_LEFT)
        && add(L"LISTBOX", L"", listID, LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP | WS_BORDER)
        && add(L"STATIC", L"", detailID, SS_LEFT)
        && add(L"BUTTON", L"&Privacy policy", policyID, BS_PUSHBUTTON | WS_TABSTOP);
    if (dialog.consent) {
        okay = okay && add(L"BUTTON", dialog.content.allow.c_str(), allowID, BS_PUSHBUTTON | WS_TABSTOP)
            && add(L"STATIC", L"", statusID, SS_LEFT)
            && add(L"BUTTON", dialog.content.notNow.c_str(), IDCANCEL, BS_DEFPUSHBUTTON | WS_TABSTOP);
    } else {
        okay = okay && add(L"BUTTON", L"Withdraw", withdrawID, BS_PUSHBUTTON | WS_TABSTOP)
            && add(L"STATIC", L"", statusID, SS_LEFT)
            && add(L"BUTTON", L"Close", IDCANCEL, BS_DEFPUSHBUTTON | WS_TABSTOP);
    }
    if (!okay) return false;
    dialog.font = jsti::chrome::dialogFont(window);
    if (dialog.font) EnumChildWindows(window, [](HWND child, LPARAM font) -> BOOL {
        SendMessageW(child, WM_SETFONT, static_cast<WPARAM>(font), TRUE); return TRUE;
    }, reinterpret_cast<LPARAM>(dialog.font));
    populate(window, dialog); layout(window);
    return true;
}

void openPolicy(HWND window, const Dialog &dialog) {
    const Entry *entry = selectedEntry(dialog);
    if (!entry || !httpsURL(entry->policy)) return;
    const auto result = reinterpret_cast<INT_PTR>(
        ShellExecuteW(window, L"open", entry->policy.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
    if (result <= 32) SetDlgItemTextW(window, statusID, L"Could not open your browser. Check your default browser settings.");
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto *dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    LRESULT themed = 0;
    if (jsti::chrome::dialogMessage(window, message, wparam, lparam, themed)) return themed;
    switch (message) {
    case WM_CREATE: return controls(window, *dialog) ? 0 : -1;
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const auto *rect = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top,
            SWP_NOACTIVATE | SWP_NOZORDER); layout(window); return 0;
    }
    case WM_GETMINMAXINFO:
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {px(window, 560), px(window, 520)}; return 0;
    case refreshMessage:
        if (!dialog->consent) {
            std::lock_guard<std::mutex> lock(mutex);
            dialog->content = snapshotContent;
            populate(window, *dialog);
            if (!dialog->content.rows.empty()) SetFocus(GetDlgItem(window, listID));
        }
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case IDCANCEL: DestroyWindow(window); return 0;
        case allowID: dialog->allowed = true; DestroyWindow(window); return 0;
        case policyID: openPolicy(window, *dialog); return 0;
        case withdrawID:
            if (const Entry *entry = selectedEntry(*dialog)) {
                EnableWindow(GetDlgItem(window, withdrawID), FALSE);
                if (dialog->callback) dialog->callback(JSTI_EVENT_CLOUD_SHARING_WITHDRAW, entry->id.c_str(), 0,
                                                       dialog->context);
            }
            return 0;
        case listID:
            if (HIWORD(wparam) == LBN_SELCHANGE) {
                dialog->selected = static_cast<int>(SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0));
                selection(window, *dialog);
            }
            return 0;
        }
        break;
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        if (dialog->font) { DeleteObject(dialog->font); dialog->font = nullptr; }
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

// Runs the dialog over `owner` until it closes. False when it could not be opened.
bool run(HWND owner, Dialog &dialog, const wchar_t *className, HWND *activeSlot) {
    WNDCLASSW type{}; type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = className; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    const std::wstring caption = dialog.content.title + L" — Just Speak to It";
    HWND window = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, type.lpszClassName, caption.c_str(),
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME, CW_USEDEFAULT, CW_USEDEFAULT,
        px(owner, 640), px(owner, 560), owner, nullptr, type.hInstance, &dialog);
    if (!window) return false;
    if (activeSlot) { std::lock_guard<std::mutex> lock(mutex); *activeSlot = window; }
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, dialog.consent || dialog.content.rows.empty() ? IDCANCEL : listID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (activeSlot) { std::lock_guard<std::mutex> lock(mutex); *activeSlot = nullptr; }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    return true;
}
} // namespace

int32_t jsti_window_request_cloud_sharing(
    const char *token, const char *title, const char *intro, const JSTICloudSharingRow *rows, size_t count,
    const char *allow_title, const char *not_now_title) {
    if (!token || !*token || !title || !intro || !allow_title || !not_now_title || count == 0) return -1;
    try {
        Content content;
        if (!jsti::wide(title, content.title) || !jsti::wide(intro, content.intro) ||
            !jsti::wide(allow_title, content.allow) || !jsti::wide(not_now_title, content.notNow) ||
            !copyRows(rows, count, content.rows)) return -1;
        HWND window = nullptr;
        { std::lock_guard<std::mutex> lock(jsti_window::state.mutex); window = jsti_window::state.window; }
        if (!window) return -1;
        std::lock_guard<std::mutex> lock(mutex);
        if (!stagedToken.empty()) return -1;
        stagedRequest = std::move(content);
        stagedToken = token;
        if (!PostMessageW(window, jsti_window::cloudSharingMessage, 0, 0)) { stagedToken.clear(); return -1; }
        return 0;
    } catch (const std::exception &) { return -1; }
}

int32_t jsti_window_set_cloud_sharing(
    const char *title, const char *footer, const char *empty_text, const JSTICloudSharingRow *rows, size_t count) {
    if (!title || !footer || !empty_text) return -1;
    try {
        Content content;
        if (!jsti::wide(title, content.title) || !jsti::wide(footer, content.footer) ||
            !jsti::wide(empty_text, content.empty) || !copyRows(rows, count, content.rows)) return -1;
        content.intro = content.title; // names the provider list for a screen reader
        std::lock_guard<std::mutex> lock(mutex);
        snapshotContent = std::move(content);
        if (activeWithdrawal) PostMessageW(activeWithdrawal, refreshMessage, 0, 0);
        return 0;
    } catch (const std::exception &) { return -1; }
}

void jsti_present_cloud_sharing_request(HWND owner, JSTIWindowCallback callback, void *context) {
    Dialog dialog; dialog.consent = true; dialog.callback = callback; dialog.context = context;
    {
        std::lock_guard<std::mutex> lock(mutex);
        dialog.content = std::move(stagedRequest);
        dialog.token.swap(stagedToken);
        stagedRequest = Content{};
    }
    if (dialog.token.empty()) return;
    // A modal dialog may already be open; the question belongs over it.
    HWND popup = GetLastActivePopup(owner);
    HWND over = popup ? popup : owner;
    if (!run(over, dialog, L"JustSpeakToItCloudSharingConsent", nullptr)) dialog.allowed = false;
    if (callback) callback(JSTI_EVENT_CLOUD_CONSENT_RESPONSE, dialog.token.c_str(), dialog.allowed ? 1 : 0, context);
}

void jsti_show_cloud_sharing(HWND owner, JSTIWindowCallback callback, void *context) {
    Dialog dialog; dialog.callback = callback; dialog.context = context;
    { std::lock_guard<std::mutex> lock(mutex); dialog.content = snapshotContent; }
    if (dialog.content.title.empty()) dialog.content.title = L"AI providers you allowed";
    dialog.content.intro = dialog.content.title;
    if (!run(owner, dialog, L"JustSpeakToItCloudSharing", &activeWithdrawal)) {
        jsti_window_update("The AI provider privacy settings could not be opened.", nullptr, -1);
    }
}
