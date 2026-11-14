#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <shellapi.h>
#include <map>
#include <mutex>
#include <tuple>
#include <vector>

// Native API Keys dialog: one row per provider credential the host can use,
// with Save/Replace, Remove (confirmed), Check validity and the provider's key
// page. The host owns the credential store and every network check; this
// dialog never shows a stored key and wipes typed text once it is handed over.
// Account balances arrive on their own channel and never make the dialog busy.

namespace {
enum Control {
    introID = 1100, listLabelID, listID, detailID, keyLabelID, keyID, saveID, removeID, validateID, linkID, statusID,
    filterLabelID, filterID, balanceID
};
// SpeakCore's APIKeyStatusFilter cases in order; a row passes filter `i` when
// bit `i` of its host-computed mask is set, so the predicate stays shared.
constexpr const wchar_t *filterNames[] = {L"All", L"Errors", L"Set", L"Unset"};
constexpr const wchar_t *emptyMessages[] = {
    L"No provider keys are available.", L"No key failed its last check.", L"No API key is saved yet.",
    L"Every provider has a saved key."
};
constexpr int filterCount = 4;
constexpr UINT refreshMessage = WM_APP + 97;
constexpr UINT balanceMessage = WM_APP + 98;
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 600, minimumClientHeight = 540;
constexpr int keyCapacity = 4096;

struct Row {
    std::string identifier;
    std::wstring label, uses, status, url, hint;
    bool saved = false;
    uint32_t filters = 1;
};

struct Balance {
    std::wstring text;
    bool refreshable = false;
    bool result = false;
};

struct Configuration {
    std::vector<Row> rows;
    std::wstring status;
    JSTIAPIKeyCallback callback = nullptr;
    void *context = nullptr;
    uint64_t revision = 0;
};
std::mutex configurationMutex;
Configuration configuration;
std::map<std::string, Balance> balances; // Guarded by configurationMutex; identifier -> balance line.
HWND openDialog = nullptr; // Guarded by configurationMutex; at most one dialog.

bool confirmRemoval(HWND window, const std::wstring &label) {
    const std::wstring title = L"Remove the " + label + L" key?";
    const std::wstring text = title + L"\n\nJust Speak to It forgets this key and deletes it from Windows Credential "
        L"Manager. Features that need it stop working until you paste it again.";
    return MessageBoxW(window, text.c_str(), L"Remove API key", MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2) == IDOK;
}
// The self-test replaces this so it never blocks on a message box.
bool (*confirm)(HWND, const std::wstring &) = confirmRemoval;

struct Dialog {
    Configuration config;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    int selected = 0;
    int filter = 0;
    std::vector<size_t> visible; // List index -> row index for the current filter.
    std::map<std::string, Balance> balances;
    bool busy = false;
};

Configuration snapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}

std::map<std::string, Balance> balanceSnapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return balances;
}

using jsti::chrome::scale;

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), button = at(32), gap = at(10), field = at(28);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    const int bottom = static_cast<int>(bounds.bottom) - margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    const int closeTop = bottom - button;
    const int statusTop = closeTop - gap - at(44);
    const int actionsTop = statusTop - gap - button;
    const int keyTop = actionsTop - gap - field;
    const int detailHeight = at(88);
    const int detailTop = keyTop - gap - detailHeight;
    const int listTop = at(82);
    move(introID, margin, at(14), width, at(40));
    move(listLabelID, margin, at(58), width - at(230), at(22));
    move(filterLabelID, margin + width - at(220), at(58), at(56), at(22));
    move(filterID, margin + width - at(160), at(54), at(160), at(160));
    move(listID, margin, listTop, width, std::max(at(96), detailTop - gap - listTop));
    move(detailID, margin, detailTop, width, detailHeight);
    move(keyLabelID, margin, keyTop + at(4), at(120), at(22));
    move(keyID, margin + at(128), keyTop, width - at(128), field);
    const int actionWidth = (width - 4 * gap) / 5;
    move(saveID, margin, actionsTop, actionWidth, button);
    move(removeID, margin + actionWidth + gap, actionsTop, actionWidth, button);
    move(validateID, margin + 2 * (actionWidth + gap), actionsTop, actionWidth, button);
    move(balanceID, margin + 3 * (actionWidth + gap), actionsTop, actionWidth, button);
    move(linkID, margin + 4 * (actionWidth + gap), actionsTop, width - 4 * (actionWidth + gap), button);
    move(statusID, margin, statusTop, width, at(44));
    move(IDCANCEL, static_cast<int>(bounds.right) - margin - at(100), closeTop, at(100), button);
}

void refreshFont(HWND window, Dialog &dialog) { jsti::chrome::refreshDialogFont(window, dialog.controls, dialog.font); }

const Row *selectedRow(const Dialog &dialog) {
    if (dialog.selected < 0 || static_cast<size_t>(dialog.selected) >= dialog.config.rows.size()) return nullptr;
    return &dialog.config.rows[static_cast<size_t>(dialog.selected)];
}

bool hasTypedKey(HWND window) { return GetWindowTextLengthW(GetDlgItem(window, keyID)) > 0; }

const Balance *balanceFor(const Dialog &dialog, const Row *row) {
    if (!row) return nullptr;
    const auto found = dialog.balances.find(row->identifier);
    return found == dialog.balances.end() ? nullptr : &found->second;
}

// Buttons follow the selected row; while the host works nothing else is sent.
void updateActions(HWND window, Dialog &dialog) {
    const Row *row = selectedRow(dialog);
    const bool idle = row && !dialog.busy, typed = hasTypedKey(window);
    SetDlgItemTextW(window, saveID, row && row->saved ? L"&Replace key" : L"&Save key");
    EnableWindow(GetDlgItem(window, saveID), idle && typed);
    EnableWindow(GetDlgItem(window, removeID), idle && row->saved);
    EnableWindow(GetDlgItem(window, validateID), idle && (typed || row->saved));
    EnableWindow(GetDlgItem(window, linkID), row && !row->url.empty());
    EnableWindow(GetDlgItem(window, keyID), row != nullptr && !dialog.busy);
    // Balance checks run beside key work, so busy never disables this button.
    const Balance *balance = balanceFor(dialog, row);
    EnableWindow(GetDlgItem(window, balanceID), balance && balance->refreshable);
    std::wstring detail;
    if (dialog.visible.empty()) detail = emptyMessages[dialog.filter];
    if (row) {
        detail = L"Used for: " + row->uses + L"\r\n" + row->status;
        if (balance) detail += L"\r\n" + balance->text;
        if (!row->hint.empty()) detail += L"\r\n" + row->hint;
    }
    SetDlgItemTextW(window, detailID, detail.c_str());
}

bool populate(HWND window, Dialog &dialog, const std::string &keep) {
    HWND list = GetDlgItem(window, listID);
    SendMessageW(list, WM_SETREDRAW, FALSE, 0);
    SendMessageW(list, LB_RESETCONTENT, 0, 0);
    bool okay = true;
    int position = -1;
    dialog.visible.clear();
    for (size_t index = 0; index < dialog.config.rows.size(); ++index) {
        const Row &row = dialog.config.rows[index];
        if ((row.filters & (1u << dialog.filter)) == 0) continue;
        const std::wstring text = row.label + L" — " + row.status;
        const LRESULT added = SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(text.c_str()));
        if (added == LB_ERR || added == LB_ERRSPACE) { okay = false; break; }
        if (!keep.empty() && row.identifier == keep) position = static_cast<int>(dialog.visible.size());
        dialog.visible.push_back(index);
    }
    if (dialog.visible.empty()) position = -1;
    else position = std::max(position, 0);
    dialog.selected = position < 0 ? -1 : static_cast<int>(dialog.visible[static_cast<size_t>(position)]);
    SendMessageW(list, LB_SETCURSEL, static_cast<WPARAM>(position), 0);
    SendMessageW(list, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(list, nullptr, TRUE);
    SetDlgItemTextW(window, statusID, dialog.config.status.c_str());
    updateActions(window, dialog);
    return okay;
}

bool createControls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        const bool framed = wcscmp(kind, L"LISTBOX") == 0 || wcscmp(kind, L"EDIT") == 0;
        HWND control = CreateWindowExW(framed ? WS_EX_CLIENTEDGE : 0, kind, text,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay =
        add(L"STATIC", L"Keys stay in Windows Credential Manager and are shared with the Transcription and Voice "
            L"settings. Only the last four characters are ever shown.", SS_LEFT, introID) &&
        add(L"STATIC", L"&Providers", 0, listLabelID) &&
        add(L"STATIC", L"Sho&w", 0, filterLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, filterID) &&
        add(L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP, listID) &&
        add(L"STATIC", L"", SS_LEFT, detailID) &&
        add(L"STATIC", L"API &key", 0, keyLabelID) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID) &&
        add(L"BUTTON", L"&Save key", BS_PUSHBUTTON | WS_TABSTOP, saveID) &&
        add(L"BUTTON", L"Re&move key", BS_PUSHBUTTON | WS_TABSTOP, removeID) &&
        add(L"BUTTON", L"&Check validity", BS_PUSHBUTTON | WS_TABSTOP, validateID) &&
        add(L"BUTTON", L"Check &balance", BS_PUSHBUTTON | WS_TABSTOP, balanceID) &&
        add(L"BUTTON", L"&Get API key…", BS_PUSHBUTTON | WS_TABSTOP, linkID) &&
        add(L"STATIC", L"", SS_LEFT, statusID) &&
        add(L"BUTTON", L"Close", BS_DEFPUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    dialog.balances = balanceSnapshot();
    SendDlgItemMessageW(window, keyID, EM_SETLIMITTEXT, keyCapacity - 1, 0);
    for (const wchar_t *name : filterNames) {
        SendDlgItemMessageW(window, filterID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name));
    }
    SendDlgItemMessageW(window, filterID, CB_SETCURSEL, 0, 0);
    refreshFont(window, dialog);
    layout(window);
    return populate(window, dialog, {});
}

void close(HWND window) {
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        if (openDialog == window) openDialog = nullptr;
    }
    SetDlgItemTextW(window, keyID, L"");
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

// Hands the typed key (or none) to the host, then wipes every copy this
// dialog made and clears the field.
void act(HWND window, Dialog &dialog, int action) {
    const Row *row = selectedRow(dialog);
    if (!row || dialog.busy || !dialog.config.callback) return;
    if (action == JSTI_API_KEY_REMOVE && (!row->saved || !confirm(window, row->label))) return;
    std::vector<wchar_t> buffer(keyCapacity, L'\0');
    const int length = action == JSTI_API_KEY_REMOVE ? 0 : GetDlgItemTextW(window, keyID, buffer.data(), keyCapacity);
    std::wstring typed(buffer.data(), static_cast<size_t>(std::max(length, 0)));
    SecureZeroMemory(buffer.data(), buffer.size() * sizeof(wchar_t));
    std::string key = jsti::utf8(typed);
    if (!typed.empty()) SecureZeroMemory(&typed[0], typed.size() * sizeof(wchar_t));
    if (action == JSTI_API_KEY_SAVE && key.empty()) return;
    SetDlgItemTextW(window, keyID, L"");
    dialog.busy = true;
    SetDlgItemTextW(window, statusID, action == JSTI_API_KEY_REMOVE ? L"Removing…" : L"Checking the key…");
    updateActions(window, dialog);
    const std::string identifier = row->identifier;
    dialog.config.callback(action, identifier.c_str(), key.empty() ? nullptr : key.c_str(), dialog.config.context);
    if (!key.empty()) SecureZeroMemory(&key[0], key.size());
}

// Asks the host for the selected account's balance. No key leaves the dialog
// and nothing turns busy; the host answers through jsti_window_set_api_key_balance.
void checkBalance(HWND window, Dialog &dialog) {
    const Row *row = selectedRow(dialog);
    const Balance *balance = balanceFor(dialog, row);
    if (!row || !balance || !balance->refreshable || !dialog.config.callback) return;
    const std::string identifier = row->identifier;
    dialog.config.callback(JSTI_API_KEY_BALANCE, identifier.c_str(), nullptr, dialog.config.context);
    updateActions(window, dialog);
}

// Takes the latest balances and announces a new result for the selected row.
void applyBalances(HWND window, Dialog &dialog) {
    const Row *row = selectedRow(dialog);
    const Balance *before = balanceFor(dialog, row);
    const std::wstring previous = before ? before->text : std::wstring();
    dialog.balances = balanceSnapshot();
    const Balance *after = balanceFor(dialog, row);
    updateActions(window, dialog);
    if (after && after->result && after->text != previous) jsti::accessibility::announce(window, after->text, false);
}

void openKeyPage(HWND window, const Dialog &dialog) {
    const Row *row = selectedRow(dialog);
    if (!row || row->url.rfind(L"https://", 0) != 0) return;
    const HINSTANCE result = ShellExecuteW(window, L"open", row->url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(result) <= 32) {
        SetDlgItemTextW(window, statusID, L"Could not open the provider's key page in your browser.");
    }
}

constexpr jsti::chrome::DialogFrame dialogFrame{
    minimumClientWidth, minimumClientHeight, windowStyle, windowExStyle, listID, IDCANCEL};

bool handle(HWND window, Dialog &dialog, UINT message, WPARAM wparam, LPARAM, LRESULT &) {
    switch (message) {
    case refreshMessage: {
        Configuration latest = snapshot();
        if (latest.revision != dialog.config.revision) {
            const Row *row = selectedRow(dialog);
            const std::string keep = row ? row->identifier : std::string();
            dialog.config = std::move(latest);
            dialog.busy = false;
            populate(window, dialog, keep);
        }
        return true;
    }
    case balanceMessage:
        applyBalances(window, dialog);
        return true;
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case listID:
            if (HIWORD(wparam) == LBN_SELCHANGE) {
                const LRESULT chosen = SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0);
                dialog.selected = chosen == LB_ERR || static_cast<size_t>(chosen) >= dialog.visible.size()
                    ? -1 : static_cast<int>(dialog.visible[static_cast<size_t>(chosen)]);
                SetDlgItemTextW(window, keyID, L"");
                updateActions(window, dialog);
            }
            return true;
        case filterID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                const LRESULT chosen = SendDlgItemMessageW(window, filterID, CB_GETCURSEL, 0, 0);
                if (chosen == CB_ERR || chosen >= filterCount) return true;
                const Row *row = selectedRow(dialog);
                const std::string keep = row ? row->identifier : std::string();
                dialog.filter = static_cast<int>(chosen);
                SetDlgItemTextW(window, keyID, L"");
                populate(window, dialog, keep);
            }
            return true;
        case keyID: if (HIWORD(wparam) == EN_CHANGE) updateActions(window, dialog); return true;
        case saveID: if (HIWORD(wparam) == BN_CLICKED) act(window, dialog, JSTI_API_KEY_SAVE); return true;
        case removeID: if (HIWORD(wparam) == BN_CLICKED) act(window, dialog, JSTI_API_KEY_REMOVE); return true;
        case validateID: if (HIWORD(wparam) == BN_CLICKED) act(window, dialog, JSTI_API_KEY_VALIDATE); return true;
        case balanceID: if (HIWORD(wparam) == BN_CLICKED) checkBalance(window, dialog); return true;
        case linkID: if (HIWORD(wparam) == BN_CLICKED) openKeyPage(window, dialog); return true;
        case IDCANCEL: if (HIWORD(wparam) == BN_CLICKED) close(window); return true;
        }
        return false;
    }
    return false;
}

const jsti::chrome::DialogProcedure<Dialog> dialogParts{dialogFrame, layout, refreshFont, createControls, close, handle};

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    return jsti::chrome::dialogProcedure(dialogParts, window, message, wparam, lparam);
}

HWND createDialog(HWND owner, Dialog &dialog) {
    HWND window = jsti::chrome::createOwnedDialog(owner, L"JustSpeakToItAPIKeys", procedure, L"API keys — Just Speak to It",
        640, 600, windowStyle, windowExStyle, &dialog);
    if (window) {
        std::lock_guard<std::mutex> lock(configurationMutex);
        openDialog = window;
    }
    return window;
}

bool validIdentifier(const char *text) {
    if (!text || !*text) return false;
    const size_t length = std::strlen(text);
    if (length > 128) return false;
    for (size_t index = 0; index < length; ++index) {
        const unsigned char character = static_cast<unsigned char>(text[index]);
        if (character <= 0x20 || character >= 0x7F) return false;
    }
    return true;
}
} // namespace

bool jsti_api_keys_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr && !configuration.rows.empty();
}

void jsti_show_api_keys(HWND owner) {
    Dialog dialog;
    dialog.config = snapshot();
    if (!dialog.config.callback || dialog.config.rows.empty()) return;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening API keys").c_str(), nullptr, -1);
        return;
    }
    // The saved keys are read once the dialog shows; until then it is busy.
    jsti::chrome::runModalDialog(owner, window, listID, close, "API key", [](HWND shown, void *context) {
        auto &opened = *static_cast<Dialog *>(context);
        opened.busy = true;
        SetDlgItemTextW(shown, statusID, L"Reading saved keys…");
        updateActions(shown, opened);
        opened.config.callback(JSTI_API_KEY_REFRESH, "", nullptr, opened.config.context);
    }, &dialog);
}

int jsti_window_set_api_keys(const JSTIAPIKeyRow *rows, size_t count, const char *status,
                             JSTIAPIKeyCallback callback, void *context) {
    if (!callback || (count && !rows) || count > 128) return -1;
    HWND dialog = nullptr;
    try {
        Configuration updated;
        for (size_t index = 0; index < count; ++index) {
            const JSTIAPIKeyRow &source = rows[index];
            Row row;
            if (!validIdentifier(source.identifier) ||
                !jsti::wide(source.label, row.label) || row.label.empty() || row.label.size() > 128 ||
                !jsti::wide(source.uses, row.uses) || row.uses.size() > 256 ||
                !jsti::wide(source.status, row.status) || row.status.size() > 512 ||
                !jsti::wide(source.url, row.url) || row.url.size() > 512 ||
                (!row.url.empty() && row.url.rfind(L"https://", 0) != 0) ||
                !jsti::wide(source.hint, row.hint) || row.hint.size() > 512 ||
                (source.saved != 0 && source.saved != 1)) {
                return -1;
            }
            row.identifier = source.identifier;
            row.saved = source.saved == 1;
            row.filters = source.filters;
            updated.rows.push_back(std::move(row));
        }
        if (status && (!jsti::wide(status, updated.status) || updated.status.size() > 1024)) return -1;
        updated.callback = callback;
        updated.context = context;
        std::lock_guard<std::mutex> lock(configurationMutex);
        updated.revision = configuration.revision + 1;
        configuration = std::move(updated);
        dialog = openDialog;
    } catch (const std::exception &) { return -1; }
    if (dialog) PostMessageW(dialog, refreshMessage, 0, 0);
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

void jsti_window_clear_api_keys(void) {
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = Configuration();
        balances.clear();
    }
    jsti_window_update(nullptr, nullptr, -1);
}

int jsti_window_set_api_key_balance(const char *identifier, const char *text, int refreshable, int result) {
    if (!validIdentifier(identifier) || (refreshable != 0 && refreshable != 1) || (result != 0 && result != 1)) {
        return -1;
    }
    HWND dialog = nullptr;
    try {
        Balance balance;
        if (!jsti::wide(text, balance.text) || balance.text.empty() || balance.text.size() > 1024) return -1;
        balance.refreshable = refreshable == 1;
        balance.result = result == 1;
        std::lock_guard<std::mutex> lock(configurationMutex);
        balances[identifier] = std::move(balance);
        dialog = openDialog;
    } catch (const std::exception &) { return -1; }
    if (dialog) PostMessageW(dialog, balanceMessage, 0, 0);
    return 0;
}

// ---- self-test -------------------------------------------------------------

namespace {
using Call = std::tuple<int, std::string, std::string>;
void recordAPIKeyAction(int action, const char *identifier, const char *key, void *context) {
    static_cast<std::vector<Call> *>(context)->emplace_back(action, identifier, key ? key : "<none>");
}
bool approve(HWND, const std::wstring &) { return true; }
bool decline(HWND, const std::wstring &) { return false; }
} // namespace

// Validation, per-row buttons, every action with its row and key, a declined
// removal, the field wiped after each hand-over, busy until the host refreshes,
// selection kept across a refresh, a balance shown and checked without turning
// busy, and Close emitting nothing.
bool jsti_api_keys_self_test(HWND owner, std::string &error) {
    const Configuration original = snapshot();
    const std::map<std::string, Balance> originalBalances = balanceSnapshot();
    const auto originalConfirm = confirm;
    std::vector<Call> calls;
    bool passed = false;
    try {
        JSTIAPIKeyRow rows[] = {
            {"openrouter.apiKey", "OpenRouter", "Post-processing", "Not set", "https://openrouter.ai/keys", "", 0,
             0b1001},
            {"openai.apiKey", "OpenAI", "Transcription",
             "Saved \xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2" "abcd",
             "https://platform.openai.com/api-keys", "", 1, 0b0101}
        };
        JSTIAPIKeyRow insecure = rows[0];
        insecure.url = "http://openrouter.ai/keys";
        JSTIAPIKeyRow spaced = rows[0];
        spaced.identifier = "open router";
        if (jsti_window_set_api_keys(&insecure, 1, "", recordAPIKeyAction, &calls) != -1 ||
            jsti_window_set_api_keys(&spaced, 1, "", recordAPIKeyAction, &calls) != -1 ||
            jsti_window_set_api_keys(rows, 2, "", nullptr, &calls) != -1 ||
            jsti_window_set_api_keys(rows, 2, "Ready", recordAPIKeyAction, &calls) != 0 ||
            !jsti_api_keys_available()) {
            error = "API key configuration accepted an invalid row or rejected a valid one.";
        } else {
            Dialog dialog;
            dialog.config = snapshot();
            HWND window = createDialog(owner, dialog);
            if (!window) {
                error = jsti::systemError("Creating the API keys fixture");
            } else {
                auto select = [&](int index) {
                    SendDlgItemMessageW(window, listID, LB_SETCURSEL, static_cast<WPARAM>(index), 0);
                    SendMessageW(window, WM_COMMAND, MAKEWPARAM(listID, LBN_SELCHANGE), 0);
                };
                auto click = [&](int id) { SendMessageW(window, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED), 0); };
                auto show = [&](int filter) {
                    SendDlgItemMessageW(window, filterID, CB_SETCURSEL, static_cast<WPARAM>(filter), 0);
                    SendMessageW(window, WM_COMMAND, MAKEWPARAM(filterID, CBN_SELCHANGE), 0);
                };
                auto count = [&] { return SendDlgItemMessageW(window, listID, LB_GETCOUNT, 0, 0); };
                auto enabled = [&](int id) { return IsWindowEnabled(GetDlgItem(window, id)) != FALSE; };
                auto type = [&](const wchar_t *text) {
                    SetDlgItemTextW(window, keyID, text);
                    SendMessageW(window, WM_COMMAND, MAKEWPARAM(keyID, EN_CHANGE), 0);
                };
                auto refresh = [&](const char *status) {
                    jsti_window_set_api_keys(rows, 2, status, recordAPIKeyAction, &calls);
                    SendMessageW(window, refreshMessage, 0, 0);
                };
                const bool listed = count() == 2;
                show(2);
                const bool setOnly = count() == 1 && dialog.selected == 1;
                show(1);
                const bool noErrors = count() == 0 && dialog.selected == -1 && !enabled(saveID);
                show(3);
                const bool unsetOnly = count() == 1 && dialog.selected == 0;
                show(0);
                const bool filtered = setOnly && noErrors && unsetOnly && count() == 2;
                select(0);
                const bool unsaved = !enabled(saveID) && !enabled(removeID) && !enabled(validateID) && enabled(linkID);
                type(L"sk-or-fixture-0000");
                const bool typed = enabled(saveID) && enabled(validateID) && !enabled(removeID);
                click(saveID);
                const bool wiped = GetWindowTextLengthW(GetDlgItem(window, keyID)) == 0;
                const bool busy = dialog.busy && !enabled(saveID) && !enabled(validateID) && !enabled(keyID);
                rows[0].saved = 1;
                rows[0].filters = 0b0101;
                rows[0].status = "Saved \xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2\xE2\x80\xA2" "0000";
                refresh("OpenRouter API key saved and validated successfully.");
                wchar_t replace[32] = {};
                GetDlgItemTextW(window, saveID, replace, 32);
                const bool kept = !dialog.busy && dialog.selected == 0 && enabled(removeID) && enabled(validateID) &&
                    std::wstring(replace) == L"&Replace key";
                const bool rejectsBalance =
                    jsti_window_set_api_key_balance("open router", "Balance: checking\xE2\x80\xA6", 1, 0) == -1 &&
                    jsti_window_set_api_key_balance("openrouter.apiKey", "", 1, 0) == -1 &&
                    jsti_window_set_api_key_balance("openrouter.apiKey", "Balance: $4.10 credit.", 2, 0) == -1;
                jsti_window_set_api_key_balance("openrouter.apiKey", "Balance: $4.10 credit.", 1, 1);
                SendMessageW(window, balanceMessage, 0, 0);
                wchar_t detail[512] = {};
                GetDlgItemTextW(window, detailID, detail, 512);
                const bool balanced = rejectsBalance && enabled(balanceID) &&
                    std::wstring(detail).find(L"Balance: $4.10 credit.") != std::wstring::npos;
                click(balanceID);
                const bool balanceIdle = !dialog.busy && enabled(keyID) && enabled(balanceID);
                select(1);
                const bool noBalance = !enabled(balanceID);
                click(validateID);
                refresh("OpenAI key is valid.");
                confirm = decline;
                click(removeID);
                const bool declined = !dialog.busy;
                confirm = approve;
                click(removeID);
                refresh("OpenAI key removed from Windows Credential Manager.");
                const size_t beforeClose = calls.size();
                click(IDCANCEL);
                const bool closed = !IsWindow(window) && calls.size() == beforeClose;
                if (IsWindow(window)) DestroyWindow(window);
                const std::vector<Call> expected = {
                    Call{JSTI_API_KEY_SAVE, "openrouter.apiKey", "sk-or-fixture-0000"},
                    Call{JSTI_API_KEY_BALANCE, "openrouter.apiKey", "<none>"},
                    Call{JSTI_API_KEY_VALIDATE, "openai.apiKey", "<none>"},
                    Call{JSTI_API_KEY_REMOVE, "openai.apiKey", "<none>"}
                };
                passed = listed && filtered && unsaved && typed && wiped && busy && kept && balanced && balanceIdle &&
                    noBalance && declined && closed && calls == expected;
                if (!passed) error = "The API keys dialog did not match its row states or reported the wrong action.";
            }
        }
    } catch (const std::exception &) { error = "The API keys self-test could not allocate its fixtures."; }
    confirm = originalConfirm;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        const uint64_t revision = configuration.revision;
        configuration = original;
        configuration.revision = revision + 1;
        balances = originalBalances;
    }
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
