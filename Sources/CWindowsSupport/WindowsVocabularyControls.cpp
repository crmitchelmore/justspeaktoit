#include "WindowsVocabularyInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <utility>

namespace jsti::vocabulary {
namespace {
bool combo(const Dialog &d, int index) { return d.kind == 0 && (index == 4 || index == 6); }
bool check(const Dialog &d, int index) { return d.kind == 1 && (index == 5 || index == 6); }
const std::array<const char *, 3> activation = {"automatic", "requireContextMatch", "manual"};
const std::array<const char *, 3> confidence = {"high", "medium", "low"};
} // namespace
using jsti::chrome::scale;

void set(HWND window, int id, const std::string &text) {
    std::wstring value;
    if (!jsti::wide(text.c_str(), value)) return;
    HWND control = GetDlgItem(window, id);
    wchar_t className[16]{};
    GetClassNameW(control, className, 16);
    if (_wcsicmp(className, L"Edit") == 0 && (GetWindowLongPtrW(control, GWL_STYLE) & ES_MULTILINE)) {
        for (size_t i = 0; i < value.size(); ++i) {
            if (value[i] == L'\n' && (i == 0 || value[i - 1] != L'\r')) { value.insert(i, 1, L'\r'); ++i; }
        }
    }
    SetDlgItemTextW(window, id, value.c_str());
}
std::string get(HWND window, int id) {
    HWND control = GetDlgItem(window, id);
    const int count = GetWindowTextLengthW(control);
    std::wstring value(static_cast<size_t>(count) + 1, 0);
    value.resize(static_cast<size_t>(GetWindowTextW(control, value.data(), count + 1)));
    for (size_t i = 0; i + 1 < value.size(); ++i)
        if (value[i] == L'\r' && value[i + 1] == L'\n') value.erase(i, 1);
    return jsti::utf8(value);
}
std::string value(Dialog &d, int index) {
    if (d.kind == 1 && index == 7) return "";
    if (combo(d, index)) {
        const int chosen = static_cast<int>(SendDlgItemMessageW(d.window, field + index - 1, CB_GETCURSEL, 0, 0));
        return chosen < 0 || chosen > 2 ? "" : (index == 4 ? activation : confidence)[static_cast<size_t>(chosen)];
    }
    if (check(d, index)) return IsDlgButtonChecked(d.window, field + index - 1) == BST_CHECKED ? "true" : "false";
    return get(d.window, field + index - 1);
}
void fill(Dialog &d, const Row &row) {
    if (d.kind == 3) {
        set(d.window, notice, row[0].empty()
            ? "Review stored candidates only. Automatic observation of edits in other apps is not available."
            : row[1] + " -> " + row[2] + "\r\nSeen: " + row[3] + "\r\nSource apps: " + row[4]
                + "\r\nFirst seen: " + row[5] + "\r\nLast seen: " + row[6] + "\r\nState: " + row[7]);
        return;
    }
    for (int i = 1; i < (d.kind == 4 ? 3 : 8); ++i) {
        if (d.kind == 1 && i == 7) continue;
        if (combo(d, i)) {
            const auto &choices = i == 4 ? activation : confidence;
            const auto match = std::find(choices.begin(), choices.end(), row[static_cast<size_t>(i)]);
            SendDlgItemMessageW(d.window, field + i - 1, CB_SETCURSEL,
                match == choices.end() ? 0 : static_cast<WPARAM>(match - choices.begin()), 0);
        } else if (check(d, i)) {
            CheckDlgButton(d.window, field + i - 1, row[static_cast<size_t>(i)] == "true" ? BST_CHECKED : BST_UNCHECKED);
        } else set(d.window, field + i - 1, row[static_cast<size_t>(i)]);
    }
}
void updateCategories(Dialog &d, std::vector<Category> options) {
    d.categories = std::move(options);
    SendDlgItemMessageW(d.window, categoryFilter, CB_RESETCONTENT, 0, 0);
    size_t selected = 0;
    for (size_t i = 0; i < d.categories.size(); ++i) {
        const auto &item = d.categories[i];
        std::wstring label;
        jsti::wide(((i == 0 ? "All" : item.value) + " (" + std::to_string(item.count) + ")").c_str(), label);
        SendDlgItemMessageW(d.window, categoryFilter, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
        if (item.value == d.category) selected = i;
    }
    d.category = d.categories[selected].value;
    SendDlgItemMessageW(d.window, categoryFilter, CB_SETCURSEL, selected, 0);
}
void layout(Dialog &d) {
    RECT r{}; GetClientRect(d.window, &r);
    if (d.kind == 2) {
        const int inset = scale(d.window, 16);
        MoveWindow(GetDlgItem(d.window, notice), inset, inset, static_cast<int>(r.right) - 2 * inset,
            static_cast<int>(r.bottom) - 2 * inset, TRUE);
        return;
    }
    if (d.kind == 4) {
        const int inset = scale(d.window, 16), left = scale(d.window, 210), gap = scale(d.window, 24);
        const int x = inset + left + gap, width = static_cast<int>(r.right) - x - inset;
        MoveWindow(GetDlgItem(d.window, 951), inset, inset, left, scale(d.window, 20), TRUE);
        MoveWindow(GetDlgItem(d.window, search), inset, scale(d.window, 42), left, scale(d.window, 28), TRUE);
        MoveWindow(GetDlgItem(d.window, list), inset, scale(d.window, 80), left,
            static_cast<int>(r.bottom) - scale(d.window, 140), TRUE);
        MoveWindow(GetDlgItem(d.window, add), inset, static_cast<int>(r.bottom) - scale(d.window, 44),
            scale(d.window, 100), scale(d.window, 30), TRUE);
        MoveWindow(GetDlgItem(d.window, remove), inset + scale(d.window, 110),
            static_cast<int>(r.bottom) - scale(d.window, 44), scale(d.window, 100), scale(d.window, 30), TRUE);
        for (int i = 0; i < 2; ++i) {
            MoveWindow(GetDlgItem(d.window, 941 + i), x, scale(d.window, 16 + i * 100), width,
                scale(d.window, 20), TRUE);
            MoveWindow(GetDlgItem(d.window, field + i), x, scale(d.window, 42 + i * 100), width,
                scale(d.window, 60), TRUE);
        }
        MoveWindow(GetDlgItem(d.window, save), x, scale(d.window, 220), scale(d.window, 140), scale(d.window, 32), TRUE);
        MoveWindow(GetDlgItem(d.window, notice), x, scale(d.window, 270), width,
            static_cast<int>(r.bottom) - scale(d.window, 286), TRUE);
        ShowScrollBar(d.window, SB_VERT, FALSE);
        return;
    }
    if (d.kind == 3) {
        const int inset = scale(d.window, 16), width = static_cast<int>(r.right) - 2 * inset;
        const int row = scale(d.window, 32), footer = static_cast<int>(r.bottom) - scale(d.window, 180);
        MoveWindow(GetDlgItem(d.window, 951), inset, inset, width, scale(d.window, 20), TRUE);
        MoveWindow(GetDlgItem(d.window, search), inset, scale(d.window, 42), width, row, TRUE);
        MoveWindow(GetDlgItem(d.window, list), inset, scale(d.window, 82), width,
            footer - scale(d.window, 92), TRUE);
        const int ids[] = {promoteCandidate, dismissCandidate, remove, clearCandidates, reviewCandidates};
        for (int i = 0; i < 5; ++i)
            MoveWindow(GetDlgItem(d.window, ids[i]), inset + i * width / 5, footer,
                width / 5 - scale(d.window, 8), row, TRUE);
        for (int i = 0; i < 2; ++i)
            MoveWindow(GetDlgItem(d.window, i == 0 ? allowLearning : stopLearning),
                inset + i * width / 2, footer + row + scale(d.window, 8),
                width / 2 - scale(d.window, 8), row, TRUE);
        MoveWindow(GetDlgItem(d.window, notice), inset, footer + 2 * row + scale(d.window, 16), width,
            static_cast<int>(r.bottom) - footer - 2 * row - scale(d.window, 16) - inset, TRUE);
        ShowScrollBar(d.window, SB_VERT, FALSE);
        return;
    }
    const int height = std::max(static_cast<int>(r.bottom), scale(d.window, 920));
    d.scroll = std::clamp(d.scroll, 0, height - static_cast<int>(r.bottom));
    SCROLLINFO si{}; si.cbSize = sizeof(si); si.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    si.nMax = height - 1; si.nPage = static_cast<UINT>(r.bottom); si.nPos = d.scroll;
    SetScrollInfo(d.window, SB_VERT, &si, TRUE);
    const int x = scale(d.window, 250), width = static_cast<int>(r.right) - x - scale(d.window, 16);
    auto move = [&](int id, int xx, int y, int w, int h) {
        MoveWindow(GetDlgItem(d.window, id), scale(d.window, xx), scale(d.window, y) - d.scroll,
            w < 0 ? width : scale(d.window, w), scale(d.window, h), TRUE);
    };
    move(951, 16, 16, 210, 20); move(search, 16, 42, 210, 28);
    if (d.kind == 1) {
        MoveWindow(d.categoryLabel, scale(d.window, 16), scale(d.window, 80) - d.scroll,
            scale(d.window, 210), scale(d.window, 20), TRUE);
        move(categoryFilter, 16, 104, 210, 180);
    }
    move(list, 16, d.kind == 1 ? 144 : 80, 210, d.kind == 1 ? 372 : 436);
    move(add, 16, 528, 100, 30); move(remove, 126, 528, 100, 30);
    move(up, 16, 568, 100, 30); move(down, 126, 568, 100, 30);
    for (int i = 1; i < 8; ++i) {
        if (d.kind == 1 && i == 7) continue;
        move(940 + i, 250, 16 + (i - 1) * 66, -1, 20);
        move(field + i - 1, 250, 38 + (i - 1) * 66, -1, combo(d, i) ? 180 : 38);
    }
    move(save, 250, 485, 130, 30); move(defaults, 390, 485, 170, 30);
    move(importMerge, 16, 615, 210, 30); move(importReplace, 16, 655, 210, 30);
    move(exportJSON, 16, 695, 210, 30);
    move(legacyDictionary, 16, 740, 210, 40);
    move(reviewCandidates, 16, 615, 210, 40);
    move(948, 250, 532, -1, 20); move(preview, 250, 558, -1, 65);
    move(949, 250, 630, -1, 20); move(previewTags, 250, 655, -1, 28);
    move(previewButton, 250, 695, 130, 30);
    move(includeRules, 16, 740, 320, 28); move(includeTags, 350, 740, 320, 28);
    move(950, 16, 778, 200, 20); move(tags, 220, 775, -1, 28);
    move(preferences, 16, 815, 200, 30);
    move(notice, 250, 815, -1, 90);
    (void)x;
}
bool updateFont(Dialog &d) {
    HFONT font = CreateFontW(-MulDiv(10, static_cast<int>(GetDpiForWindow(d.window)), 72), 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!font) return false;
    for (HWND h : d.controls) SendMessageW(h, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    if (d.font) DeleteObject(d.font);
    d.font = font;
    return true;
}
bool createControls(Dialog &d) {
    auto control = [&](const wchar_t *kind, const wchar_t *title, DWORD style, int id) {
        HWND h = CreateWindowExW(std::wcscmp(kind, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0,
            kind, title, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, d.window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (!h) return false;
        d.controls.push_back(h); return true;
    };
    if (d.kind == 2) {
        if (!control(L"EDIT", L"Loading retained correction results...", ES_MULTILINE | ES_READONLY
            | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, notice)) return false;
        ShowScrollBar(d.window, SB_VERT, FALSE);
        return updateFont(d);
    }
    const DWORD button = WS_TABSTOP | BS_PUSHBUTTON;
    if (!control(L"STATIC", L"Searc&h saved entries", 0, 951)
        || !control(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, search)) return false;
    if (d.kind == 1) {
        if (!control(L"STATIC", L"Category &filter", 0, -1)) return false;
        d.categoryLabel = d.controls.back();
        if (!control(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, categoryFilter)) return false;
        updateCategories(d, {{"", 0}});
    }
    if (!control(L"LISTBOX", L"", LBS_NOTIFY | WS_TABSTOP | WS_VSCROLL | WS_BORDER, list)) return false;
    if (d.kind == 4) {
        if (!control(L"BUTTON", L"&New", button, add) || !control(L"BUTTON", L"&Delete", button, remove)) return false;
        for (int i = 0; i < 2; ++i) {
            if (!control(L"STATIC", i == 0 ? L"&Word" : L"&Pronunciation", 0, 941 + i)
                || !control(L"EDIT", L"", ES_MULTILINE | ES_WANTRETURN | ES_AUTOVSCROLL
                    | WS_VSCROLL | WS_TABSTOP, field + i)) return false;
            SendDlgItemMessageW(d.window, field + i, EM_SETLIMITTEXT, 65535, 0);
        }
        if (!control(L"BUTTON", L"&Save entry", button, save)
            || !control(L"EDIT", L"Loading legacy word dictionary...", ES_MULTILINE | ES_READONLY
            | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, notice)) return false;
        fill(d, Row{}); pending(d, true); return updateFont(d);
    }
    if (d.kind == 3) {
        for (const auto &item : std::vector<std::pair<int, const wchar_t *>>{
             {promoteCandidate, L"&Approve"}, {dismissCandidate, L"&Dismiss"}, {remove, L"&Remove"},
             {clearCandidates, L"&Clear all"}, {reviewCandidates, L"Re&load"},
             {allowLearning, L"Allow &learning for this session"}, {stopLearning, L"&Stop learning"}})
            if (!control(L"BUTTON", item.second, button, item.first)) return false;
        if (!control(L"EDIT", L"Loading stored candidates...", ES_MULTILINE | ES_READONLY
            | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, notice)) return false;
        ShowScrollBar(d.window, SB_VERT, FALSE);
        pending(d, true);
        return updateFont(d);
    }
    if (d.kind == 0 && !control(L"BUTTON", L"Review stored &candidates...", button, reviewCandidates)) return false;
    if (d.kind == 1 && !control(L"BUTTON", L"Legacy &word dictionary...", button, legacyDictionary)) return false;
    for (const auto &item : std::vector<std::pair<int, const wchar_t *>>{
         {add, L"&New"}, {save, L"&Save entry"}, {remove, L"&Delete"}, {up, L"Move &up"}, {down, L"Move &down"},
         {previewButton, L"&Preview"}, {preferences, L"Save &context settings"}, {defaults, L"Add default &entries"}})
        if (!control(L"BUTTON", item.second, button, item.first)) return false;
    for (const auto &item : std::vector<std::pair<int, const wchar_t *>>{
         {importMerge, L"&Import JSON (merge)..."}, {importReplace, L"Import JSON (replace)..."},
         {exportJSON, L"&Export JSON..."}})
        if (!control(L"BUTTON", item.second, button, item.first)) return false;
    const wchar_t *ruleLabels[] = {L"Display &name", L"&Canonical spelling", L"&Spoken variants (one per line)",
        L"&Activation", L"Context &tags (comma-separated)", L"Con&fidence", L"&Notes"};
    const wchar_t *speechLabels[] = {L"&Word or pattern", L"&Pronunciation", L"&Text replacement",
        L"Ca&tegory", L"&Regular expression", L"Case &sensitive", L"Notes (not stored)"};
    for (int i = 1; i < 8; ++i) {
        if (d.kind == 1 && i == 7) continue;
        if (!control(L"STATIC", (d.kind == 0 ? ruleLabels : speechLabels)[i - 1], 0, 940 + i)) return false;
        const wchar_t *type = combo(d, i) ? L"COMBOBOX" : check(d, i) ? L"BUTTON" : L"EDIT";
        const DWORD style = combo(d, i) ? CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP
            : check(d, i) ? BS_AUTOCHECKBOX | WS_TABSTOP
            : ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL | WS_TABSTOP;
        if (!control(type, check(d, i) ? speechLabels[i - 1] : L"", style, field + i - 1)) return false;
        if (combo(d, i)) {
            const wchar_t *a[] = {L"Automatic", L"Require context match", L"Manual confirmation"};
            const wchar_t *c[] = {L"High", L"Medium", L"Low"};
            for (int j = 0; j < 3; ++j)
                SendDlgItemMessageW(d.window, field + i - 1, CB_ADDSTRING, 0,
                    reinterpret_cast<LPARAM>((i == 4 ? a : c)[j]));
        }
    }
    if (!control(L"STATIC", L"Preview &text (saved rules are used)", 0, 948)
        || !control(L"EDIT", L"", ES_MULTILINE | ES_WANTRETURN | WS_VSCROLL | WS_TABSTOP, preview)
        || !control(L"STATIC", L"Preview conte&xt tags (comma-separated)", 0, 949)
        || !control(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, previewTags)
        || !control(L"EDIT", L"Loading...", ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL
            | WS_VSCROLL | WS_TABSTOP, notice)
        || !control(L"BUTTON", L"Include &rules in post-processing", BS_AUTOCHECKBOX | WS_TABSTOP, includeRules)
        || !control(L"BUTTON", L"Include context ta&gs", BS_AUTOCHECKBOX | WS_TABSTOP, includeTags)
        || !control(L"STATIC", L"Recording context tags", 0, 950)
        || !control(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, tags)) return false;
    if (!updateFont(d)) return false;
    for (int id : std::array<int, 5>{includeRules, includeTags, tags, preferences, 950})
        ShowWindow(GetDlgItem(d.window, id), d.kind == 0 ? SW_SHOW : SW_HIDE);
    ShowWindow(GetDlgItem(d.window, defaults), d.kind == 1 ? SW_SHOW : SW_HIDE);
    for (int id : {importMerge, importReplace, exportJSON})
        ShowWindow(GetDlgItem(d.window, id), d.kind == 1 ? SW_SHOW : SW_HIDE);
    fill(d, Row{});
    pending(d, true);
    return true;
}

} // namespace jsti::vocabulary
