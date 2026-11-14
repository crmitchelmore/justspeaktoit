// Browse OpenRouter models… (#1618): search the OpenRouter catalogue, filter by
// provider and zero listed prices, read a model's details and pricing, then
// choose it. The host filters and writes every string (DesktopOpenRouterBrowser);
// this window renders its pages and returns the chosen picker slot.
#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <commctrl.h>
#include <shellapi.h>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {
// Enter chooses (IDOK) and Escape closes (IDCANCEL) through IsDialogMessageW.
enum { introID = 1101, searchLabelID, searchID, providerLabelID, providerID, zeroPricesID, listLabelID, listID,
       detailsLabelID, detailsID, statusID, openPageID };
constexpr size_t maximumRows = 2048;
constexpr size_t maximumText = 16384;
const wchar_t *const pagePrefix = L"https://openrouter.ai/";

struct Row { std::wstring title, subtitle, details, url; int32_t slot = -1; bool selected = false; };
struct Page {
    std::wstring title, intro, action, selectedAction, placeholder, allProviders, zeroPrices, linkTitle, status;
    std::vector<std::wstring> providers;
    std::vector<Row> rows;
};
struct Received { Page page; bool ok = false; };

std::mutex sourceMutex;
JSTIOpenRouterBrowserQuery source = nullptr;
HWND active = nullptr;

struct Dialog {
    int32_t purpose = JSTI_OPENROUTER_BROWSER_CLEANUP;
    int32_t selected = -1;
    int32_t chosen = -1;
    HFONT font = nullptr;
    Page page;
    std::wstring provider;
};

bool copy(const char *text, std::wstring &result) {
    if (!text) { result.clear(); return true; }
    return strlen(text) <= maximumText && jsti::wide(text, result);
}

void receive(const JSTIOpenRouterBrowserPage *page, void *context) {
    auto &received = *static_cast<Received *>(context);
    if (!page || page->row_count > maximumRows || (page->row_count && !page->rows) ||
        page->provider_count > maximumRows || (page->provider_count && !page->providers)) return;
    Page next;
    if (!copy(page->title, next.title) || !copy(page->intro, next.intro) || !copy(page->action, next.action) ||
        !copy(page->selected_action, next.selectedAction) || !copy(page->search_placeholder, next.placeholder) ||
        !copy(page->all_providers, next.allProviders) || !copy(page->zero_prices, next.zeroPrices) ||
        !copy(page->link_title, next.linkTitle) || !copy(page->status, next.status)) return;
    for (size_t index = 0; index < page->provider_count; ++index) {
        std::wstring provider;
        if (!copy(page->providers[index], provider)) return;
        next.providers.push_back(std::move(provider));
    }
    for (size_t index = 0; index < page->row_count; ++index) {
        const JSTIOpenRouterBrowserRow &item = page->rows[index];
        Row row;
        if (!copy(item.title, row.title) || !copy(item.subtitle, row.subtitle) ||
            !copy(item.details, row.details) || !copy(item.url, row.url) || item.slot < 0) return;
        row.slot = item.slot;
        row.selected = item.selected != 0;
        next.rows.push_back(std::move(row));
    }
    received.page = std::move(next);
    received.ok = true;
}

std::wstring text(HWND window, int id) {
    const int length = GetWindowTextLengthW(GetDlgItem(window, id));
    std::wstring value(static_cast<size_t>(length > 0 ? length : 0) + 1, 0);
    GetDlgItemTextW(window, id, &value[0], static_cast<int>(value.size()));
    value.resize(wcslen(value.c_str()));
    return value;
}

// Runs the host's query for the current filters; false when it has no catalogue.
bool query(int32_t purpose, const std::wstring &search, const std::wstring &provider, bool zeroPrices,
           int32_t selected, Page &page) {
    JSTIOpenRouterBrowserQuery current;
    { std::lock_guard<std::mutex> lock(sourceMutex); current = source; }
    if (!current) return false;
    Received received;
    const std::string searchText = jsti::utf8(search), providerText = jsti::utf8(provider);
    if (current(purpose, searchText.c_str(), providerText.c_str(), zeroPrices ? 1 : 0, selected, receive,
                &received) != 0 || !received.ok) return false;
    page = std::move(received.page);
    return true;
}

// Host copy shown on a button: the access key is ours, so literal ampersands are doubled.
std::wstring buttonText(const std::wstring &value, bool accessKey) {
    std::wstring result = accessKey ? L"&" : L"";
    for (const wchar_t character : value) {
        if (character == L'&') result += L'&';
        result += character;
    }
    return result;
}

std::wstring lines(const std::wstring &value) {
    std::wstring result;
    for (const wchar_t character : value) {
        if (character == L'\n') result += L'\r';
        result += character;
    }
    return result;
}

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int margin = scale(window, 20), gap = scale(window, 8), row = scale(window, 30);
    const int width = bounds.right - 2 * margin, label = scale(window, 96), button = scale(window, 34);
    int y = margin;
    MoveWindow(GetDlgItem(window, introID), margin, y, width, scale(window, 40), TRUE);
    y += scale(window, 40) + gap;
    MoveWindow(GetDlgItem(window, searchLabelID), margin, y + scale(window, 5), label, scale(window, 20), TRUE);
    MoveWindow(GetDlgItem(window, searchID), margin + label, y, width - label, row, TRUE);
    y += row + gap;
    const int picker = scale(window, 260);
    MoveWindow(GetDlgItem(window, providerLabelID), margin, y + scale(window, 5), label, scale(window, 20), TRUE);
    MoveWindow(GetDlgItem(window, providerID), margin + label, y, picker, scale(window, 300), TRUE);
    MoveWindow(GetDlgItem(window, zeroPricesID), margin + label + picker + scale(window, 16), y,
        width - label - picker - scale(window, 16), row, TRUE);
    y += row + gap;
    const int buttons = bounds.bottom - margin - button;
    const int status = buttons - gap - scale(window, 22);
    const int columns = scale(window, 16), list = (width - columns) * 11 / 20;
    const int details = margin + list + columns, detailsWidth = width - list - columns;
    MoveWindow(GetDlgItem(window, listLabelID), margin, y, list, scale(window, 20), TRUE);
    MoveWindow(GetDlgItem(window, detailsLabelID), details, y, detailsWidth, scale(window, 20), TRUE);
    y += scale(window, 22);
    const int height = status - gap - y;
    MoveWindow(GetDlgItem(window, listID), margin, y, list, height, TRUE);
    MoveWindow(GetDlgItem(window, detailsID), details, y, detailsWidth, height, TRUE);
    MoveWindow(GetDlgItem(window, statusID), margin, status, width, scale(window, 22), TRUE);
    const int wide = scale(window, 200), narrow = scale(window, 120);
    MoveWindow(GetDlgItem(window, openPageID), margin, buttons, wide, button, TRUE);
    MoveWindow(GetDlgItem(window, IDCANCEL), bounds.right - margin - narrow, buttons, narrow, button, TRUE);
    MoveWindow(GetDlgItem(window, IDOK), bounds.right - margin - narrow - gap - wide, buttons, wide, button, TRUE);
}

void font(HWND window, Dialog &dialog) {
    HFONT next = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!next) return;
    const int ids[] = {introID, searchLabelID, searchID, providerLabelID, providerID, zeroPricesID, listLabelID,
                       listID, detailsLabelID, detailsID, statusID, openPageID, IDOK, IDCANCEL};
    for (int id : ids) SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(next), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = next;
}

int selectedRow(HWND window, const Dialog &dialog) {
    const LRESULT index = SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0);
    return index >= 0 && static_cast<size_t>(index) < dialog.page.rows.size() ? static_cast<int>(index) : -1;
}

// The highlighted model's details, and Choose unless it is already the picker's model.
void selectionChanged(HWND window, const Dialog &dialog) {
    const int index = selectedRow(window, dialog);
    if (index < 0) {
        SetDlgItemTextW(window, detailsID, dialog.page.status.c_str());
        SetDlgItemTextW(window, IDOK, buttonText(dialog.page.action, true).c_str());
        EnableWindow(GetDlgItem(window, IDOK), FALSE);
        EnableWindow(GetDlgItem(window, openPageID), FALSE);
        return;
    }
    const Row &row = dialog.page.rows[static_cast<size_t>(index)];
    SetDlgItemTextW(window, detailsID, lines(row.details).c_str());
    SetDlgItemTextW(window, IDOK, buttonText(row.selected ? dialog.page.selectedAction : dialog.page.action,
        !row.selected).c_str());
    EnableWindow(GetDlgItem(window, IDOK), !row.selected);
    EnableWindow(GetDlgItem(window, openPageID), row.url.rfind(pagePrefix, 0) == 0);
}

// Shows `dialog.page`, keeping the highlighted model (`keep`, a slot) when it still matches.
void render(HWND window, Dialog &dialog, int32_t keep, bool announce) {
    SetWindowTextW(window, (dialog.page.title + L" \u2014 Just Speak to It").c_str());
    SetDlgItemTextW(window, introID, dialog.page.intro.c_str());
    SetDlgItemTextW(window, zeroPricesID, buttonText(dialog.page.zeroPrices, true).c_str());
    SetDlgItemTextW(window, openPageID, buttonText(dialog.page.linkTitle, true).c_str());
    SendDlgItemMessageW(window, searchID, EM_SETCUEBANNER, TRUE,
                        reinterpret_cast<LPARAM>(dialog.page.placeholder.c_str()));
    HWND providers = GetDlgItem(window, providerID);
    const LRESULT count = SendMessageW(providers, CB_GETCOUNT, 0, 0);
    if (count != static_cast<LRESULT>(dialog.page.providers.size() + 1)) {
        SendMessageW(providers, CB_RESETCONTENT, 0, 0);
        SendMessageW(providers, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(dialog.page.allProviders.c_str()));
        LRESULT current = 0;
        for (const std::wstring &provider : dialog.page.providers) {
            const LRESULT row = SendMessageW(providers, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(provider.c_str()));
            if (provider == dialog.provider) current = row;
        }
        SendMessageW(providers, CB_SETCURSEL, current, 0);
    }
    HWND list = GetDlgItem(window, listID);
    SendMessageW(list, WM_SETREDRAW, FALSE, 0);
    SendMessageW(list, LB_RESETCONTENT, 0, 0);
    int reselect = -1, chosen = -1;
    for (size_t index = 0; index < dialog.page.rows.size(); ++index) {
        const Row &row = dialog.page.rows[index];
        std::wstring item = row.title;
        if (row.selected) item += L" (" + dialog.page.selectedAction + L")";
        if (!row.subtitle.empty()) item += L" \u2014 " + row.subtitle;
        SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(item.c_str()));
        if (row.slot == keep) reselect = static_cast<int>(index);
        if (row.selected) chosen = static_cast<int>(index);
    }
    if (reselect < 0) reselect = chosen >= 0 ? chosen : (dialog.page.rows.empty() ? -1 : 0);
    SendMessageW(list, LB_SETCURSEL, reselect, 0);
    SendMessageW(list, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(list, nullptr, TRUE);
    const std::wstring previous = text(window, statusID);
    SetDlgItemTextW(window, statusID, dialog.page.status.c_str());
    if (announce && previous != dialog.page.status)
        jsti::accessibility::announce(GetDlgItem(window, statusID), dialog.page.status, false);
    selectionChanged(window, dialog);
}

void filtersChanged(HWND window, Dialog &dialog) {
    const LRESULT provider = SendDlgItemMessageW(window, providerID, CB_GETCURSEL, 0, 0);
    dialog.provider = provider > 0 && static_cast<size_t>(provider) <= dialog.page.providers.size()
        ? dialog.page.providers[static_cast<size_t>(provider) - 1] : L"";
    const bool zero = SendDlgItemMessageW(window, zeroPricesID, BM_GETCHECK, 0, 0) == BST_CHECKED;
    const int highlighted = selectedRow(window, dialog);
    const int32_t keep = highlighted >= 0 ? dialog.page.rows[static_cast<size_t>(highlighted)].slot : -1;
    Page next;
    if (!query(dialog.purpose, text(window, searchID), dialog.provider, zero, dialog.selected, next)) {
        SetDlgItemTextW(window, statusID, L"OpenRouter models are no longer available. Close this window and refresh.");
        return;
    }
    dialog.page = std::move(next);
    render(window, dialog, keep, true);
}

void openPage(HWND window, const Dialog &dialog) {
    const int index = selectedRow(window, dialog);
    if (index < 0) return;
    const std::wstring &url = dialog.page.rows[static_cast<size_t>(index)].url;
    if (url.rfind(pagePrefix, 0) != 0) return;
    const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr,
                                                                 SW_SHOWNORMAL));
    if (opened <= 32) SetDlgItemTextW(window, statusID, L"Windows could not open the model's OpenRouter page.");
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    LRESULT themed = 0;
    if (jsti::chrome::dialogMessage(window, message, wparam, lparam, themed)) return themed;
    switch (message) {
    case WM_CREATE: {
        auto add = [&](const wchar_t *type, const wchar_t *text, DWORD style, int id, DWORD extended = 0) {
            return CreateWindowExW(extended, type, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 1, 1, window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
        };
        // Each field's label comes right before it, so UI Automation names the field.
        if (!add(L"STATIC", L"", SS_NOPREFIX, introID) ||
            !add(L"STATIC", L"&Search", 0, searchLabelID) ||
            !add(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, searchID, WS_EX_CLIENTEDGE) ||
            !add(L"STATIC", L"&Provider", 0, providerLabelID) ||
            !add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, providerID) ||
            !add(L"BUTTON", L"&Zero listed prices only", BS_AUTOCHECKBOX | WS_TABSTOP, zeroPricesID) ||
            !add(L"STATIC", L"&Models", 0, listLabelID) ||
            !add(L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP, listID,
                 WS_EX_CLIENTEDGE) ||
            !add(L"STATIC", L"&Details", 0, detailsLabelID) ||
            !add(L"EDIT", L"", ES_READONLY | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, detailsID,
                 WS_EX_CLIENTEDGE) ||
            !add(L"STATIC", L"", SS_NOPREFIX, statusID) ||
            !add(L"BUTTON", L"&Open model page", BS_PUSHBUTTON | WS_TABSTOP, openPageID) ||
            !add(L"BUTTON", L"&Choose", BS_DEFPUSHBUTTON | WS_TABSTOP, IDOK) ||
            !add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL)) return -1;
        SendDlgItemMessageW(window, searchID, EM_LIMITTEXT, 256, 0);
        font(window, *dialog);
        render(window, *dialog, -1, false);
        layout(window);
        return 0;
    }
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case searchID: if (HIWORD(wparam) == EN_CHANGE) filtersChanged(window, *dialog); return 0;
        case providerID: if (HIWORD(wparam) == CBN_SELCHANGE) filtersChanged(window, *dialog); return 0;
        case zeroPricesID: if (HIWORD(wparam) == BN_CLICKED) filtersChanged(window, *dialog); return 0;
        case listID: if (HIWORD(wparam) == LBN_SELCHANGE) selectionChanged(window, *dialog); return 0;
        case openPageID: if (HIWORD(wparam) == BN_CLICKED) openPage(window, *dialog); return 0;
        case IDOK:
            if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, IDOK))) {
                const int index = selectedRow(window, *dialog);
                if (index < 0 || dialog->page.rows[static_cast<size_t>(index)].selected) return 0;
                dialog->chosen = dialog->page.rows[static_cast<size_t>(index)].slot;
                DestroyWindow(window);
            }
            return 0;
        case IDCANCEL: if (HIWORD(wparam) == BN_CLICKED) DestroyWindow(window); return 0;
        default: break;
        }
        break;
    case WM_SIZE: layout(window); return 0;
    case WM_GETMINMAXINFO: {
        RECT size{0, 0, scale(window, 680), scale(window, 500)};
        AdjustWindowRectExForDpi(&size, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(window));
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {size.right - size.left, size.bottom - size.top};
        return 0;
    }
    case WM_DPICHANGED: {
        const auto bounds = reinterpret_cast<const RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        font(window, *dialog); layout(window); return 0;
    }
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        if (active == window) active = nullptr;
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

HWND makeDialog(HWND owner, Dialog &dialog) {
    WNDCLASSW type{};
    type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItOpenRouterBrowser"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT bounds{0, 0, scale(owner, 820), scale(owner, 600)};
    AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(owner));
    return CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName, L"Browse OpenRouter models — Just Speak to It",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left, bounds.bottom - bounds.top,
        owner, nullptr, type.hInstance, &dialog);
}

// A fixture catalogue for the self-test: three models from two providers, one free.
const JSTIOpenRouterBrowserRow fixtureRows[] = {
    {"Alpha", "OpenAI · $0.10 / $0.40 per 1M tokens", "Provider: OpenAI\nAlpha details",
     "https://openrouter.ai/openai/alpha", "openRouterBrowser.cleanup.openai-alpha", 2, 0},
    {"Beta", "OpenAI · $0 / $0 per 1M tokens", "Provider: OpenAI\nBeta details", "",
     "openRouterBrowser.cleanup.openai-beta", 5, 0},
    {"Gamma & co", "Mistral · prices not listed", "Provider: Mistral\nGamma details",
     "https://openrouter.ai/mistral/gamma", "openRouterBrowser.cleanup.mistral-gamma", 7, 0},
};
int fixtureQueries = 0;

int32_t fixtureQuery(int32_t purpose, const char *search, const char *provider, int32_t zeroOnly, int32_t selected,
                     JSTIOpenRouterBrowserReceive receive, void *context) {
    if (purpose != JSTI_OPENROUTER_BROWSER_CLEANUP) return -1;
    ++fixtureQueries;
    std::vector<JSTIOpenRouterBrowserRow> rows;
    for (JSTIOpenRouterBrowserRow row : fixtureRows) {
        if (provider && provider[0] && strstr(row.subtitle, provider) != row.subtitle) continue;
        if (zeroOnly && !strstr(row.subtitle, "$0 /")) continue;
        if (search && search[0] && !strstr(row.title, search)) continue;
        row.selected = row.slot == selected;
        rows.push_back(row);
    }
    const char *const providers[] = {"Mistral", "OpenAI"};
    const std::string status = rows.empty() ? "No models match." : std::to_string(rows.size()) + " of 3 models";
    const JSTIOpenRouterBrowserPage page{"OpenRouter cleanup models", "Pick a model for cleanup.",
        "Use for cleanup", "Selected for cleanup", "Search models", "All providers", "Zero listed prices only",
        "Open model page", status.c_str(), providers, 2, rows.data(), rows.size()};
    receive(&page, context);
    return 0;
}
} // namespace

int32_t jsti_window_set_openrouter_browser_source(JSTIOpenRouterBrowserQuery query) {
    if (!query) return -1;
    std::lock_guard<std::mutex> lock(sourceMutex);
    source = query;
    return 0;
}

bool jsti_show_openrouter_browser(HWND owner, int32_t purpose, int32_t selected, int32_t &chosen) {
    chosen = -1;
    if (active) { SetForegroundWindow(active); return false; }
    Dialog dialog;
    dialog.purpose = purpose;
    dialog.selected = selected;
    if (!query(purpose, L"", L"", false, selected, dialog.page)) {
        jsti_window_update("OpenRouter models aren't available yet. Refresh models and try again.", nullptr, -1);
        return false;
    }
    HWND window = makeDialog(owner, dialog);
    if (!window) { jsti_window_update("Browse OpenRouter models could not be opened.", nullptr, -1); return false; }
    active = window;
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, searchID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) jsti_window_update("Reading Browse OpenRouter models messages failed.", nullptr, -1);
    chosen = dialog.chosen;
    return chosen >= 0;
}

bool jsti_openrouter_browser_self_test(HWND owner, std::string &error) {
    JSTIOpenRouterBrowserQuery original;
    { std::lock_guard<std::mutex> lock(sourceMutex); original = source; }
    std::string step;
    auto check = [&](bool ok, const char *name) {
        if (!ok && step.empty()) step = name;
        return ok;
    };
    bool passed = check(jsti_window_set_openrouter_browser_source(nullptr) == -1, "a null source was accepted");
    passed = check(jsti_window_set_openrouter_browser_source(fixtureQuery) == 0, "the fixture source was refused")
        && passed;
    Dialog dialog;
    dialog.selected = 2;
    passed = check(query(dialog.purpose, L"", L"", false, dialog.selected, dialog.page) &&
        dialog.page.rows.size() == 3, "the fixture page was not received") && passed;
    Page none;
    passed = check(!query(JSTI_OPENROUTER_BROWSER_TRANSCRIPTION, L"", L"", false, -1, none),
        "a purpose without a catalogue opened") && passed;
    HWND window = makeDialog(owner, dialog);
    if (!window) {
        { std::lock_guard<std::mutex> lock(sourceMutex); source = original; }
        error = "Browse OpenRouter models fixture could not open.";
        return false;
    }
    auto enabled = [&](int id) { return IsWindowEnabled(GetDlgItem(window, id)) != FALSE; };
    auto shown = [](HWND control) { return (GetWindowLongPtrW(control, GWL_STYLE) & WS_VISIBLE) != 0; };
    auto command = [&](int id, int code) {
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(id, code), reinterpret_cast<LPARAM>(GetDlgItem(window, id)));
    };
    auto count = [&] { return SendDlgItemMessageW(window, listID, LB_GETCOUNT, 0, 0); };
    auto cursor = [&] { return SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0); };
    // The picker's model is highlighted and cannot be chosen again.
    passed = check(count() == 3 && cursor() == 0 && !enabled(IDOK) && text(window, IDOK) == L"Selected for cleanup" &&
        enabled(openPageID) && text(window, detailsID) == L"Provider: OpenAI\r\nAlpha details" &&
        text(window, statusID) == L"3 of 3 models", "the picker's model was not highlighted") && passed;
    passed = check(SendDlgItemMessageW(window, providerID, CB_GETCOUNT, 0, 0) == 3 &&
        SendDlgItemMessageW(window, providerID, CB_GETCURSEL, 0, 0) == 0, "the providers were not listed") && passed;
    std::string audit;
    passed = check(jsti::accessibility::audit(window, audit) > 0, "a control had no accessible name or id") && passed;
    // Search, then the zero-price and provider filters, each re-query the host.
    SetDlgItemTextW(window, searchID, L"Gamma");
    command(searchID, EN_CHANGE);
    passed = check(count() == 1 && enabled(IDOK) && text(window, IDOK) == L"&Use for cleanup" &&
        enabled(openPageID), "search did not narrow the models") && passed;
    SetDlgItemTextW(window, searchID, L"");
    command(searchID, EN_CHANGE);
    SendDlgItemMessageW(window, zeroPricesID, BM_SETCHECK, BST_CHECKED, 0);
    command(zeroPricesID, BN_CLICKED);
    passed = check(count() == 1 && !enabled(openPageID) && text(window, detailsID) == L"Provider: OpenAI\r\nBeta details",
        "the zero-price filter, or a model without a page, was wrong") && passed;
    SendDlgItemMessageW(window, zeroPricesID, BM_SETCHECK, BST_UNCHECKED, 0);
    SendDlgItemMessageW(window, providerID, CB_SETCURSEL, 1, 0);
    command(providerID, CBN_SELCHANGE);
    passed = check(dialog.provider == L"Mistral" && count() == 1, "the provider filter was wrong") && passed;
    SetDlgItemTextW(window, searchID, L"no such model");
    command(searchID, EN_CHANGE);
    passed = check(count() == 0 && !enabled(IDOK) && !enabled(openPageID) && text(window, statusID) == L"No models match.",
        "the empty result was wrong") && passed;
    auto fits = [&] {
        RECT client{}; GetClientRect(window, &client);
        for (HWND child = GetWindow(window, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
            if (!shown(child)) continue;
            RECT bounds{}; GetWindowRect(child, &bounds);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
            if (bounds.left < 0 || bounds.top < 0 || bounds.right > client.right || bounds.bottom > client.bottom)
                return false;
        }
        return true;
    };
    MINMAXINFO minimum{}; SendMessageW(window, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&minimum));
    SetWindowPos(window, nullptr, 0, 0, minimum.ptMinTrackSize.x, minimum.ptMinTrackSize.y, SWP_NOMOVE | SWP_NOZORDER);
    passed = check(fits(), "a control fell outside the window at its minimum size") && passed;
    // Choose returns the highlighted model's slot and closes the window.
    SetDlgItemTextW(window, searchID, L"");
    command(searchID, EN_CHANGE);
    SendDlgItemMessageW(window, listID, LB_SETCURSEL, 0, 0);
    command(listID, LBN_SELCHANGE);
    command(IDOK, BN_CLICKED);
    passed = check(dialog.chosen == 7 && !IsWindow(window), "Choose did not return the model's slot") && passed;
    if (IsWindow(window)) DestroyWindow(window);
    { std::lock_guard<std::mutex> lock(sourceMutex); source = original; }
    if (!passed) error = "Browse OpenRouter models fixture failed: " + step + (audit.empty() ? "." : " (" + audit + ").");
    return passed;
}
