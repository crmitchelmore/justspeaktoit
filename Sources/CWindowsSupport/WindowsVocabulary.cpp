#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commdlg.h>
#include <array>
#include <cwctype>
#include <mutex>
#include <vector>

namespace {
constexpr UINT update = WM_APP + 93;
enum { list = 900, add, save, remove, up, down, field = 910, preview = 920,
       previewTags, previewButton, notice, includeRules, includeTags, tags, preferences, defaults,
       search = 930, importMerge = 934, importReplace, exportJSON };
using Row = std::array<std::string, 8>;
struct Dialog {
    int kind = 0, selected = -1, scroll = 0;
    HWND window = nullptr;
    HFONT font = nullptr;
    std::vector<HWND> controls;
    std::vector<Row> rows;
    std::vector<int> visible;
    void (*emit)(int, const char *, int) = nullptr;
};
struct Update { std::string payload; bool refresh; };
std::mutex mutex;
HWND active = nullptr;
int activeKind = -1;

std::string escaped(const std::string &text) {
    std::string result;
    for (unsigned char c : text) {
        switch (c) {
        case '%': result += "%25"; break;
        case '\t': result += "%09"; break;
        case '\r': result += "%0D"; break;
        case '\n': result += "%0A"; break;
        default: result += static_cast<char>(c); break;
        }
    }
    return result;
}
std::string decoded(const std::string &text) {
    std::string result;
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '%' && i + 2 < text.size()) {
            const std::string code = text.substr(i + 1, 2);
            if (code == "25") result += '%';
            else if (code == "09") result += '\t';
            else if (code == "0A") result += '\n';
            else if (code == "0D") result += '\r';
            else { result += text[i]; continue; }
            i += 2;
        } else result += text[i];
    }
    return result;
}
std::vector<std::string> split(const std::string &text, char delimiter) {
    std::vector<std::string> values;
    size_t start = 0;
    do {
        size_t end = text.find(delimiter, start);
        values.push_back(text.substr(start, end == std::string::npos ? end : end - start));
        if (end == std::string::npos) break;
        start = end + 1;
    } while (true);
    return values;
}
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
bool combo(const Dialog &d, int index) { return d.kind == 0 && (index == 4 || index == 6); }
bool check(const Dialog &d, int index) { return d.kind == 1 && (index == 5 || index == 6); }
const std::array<const char *, 3> activation = {"automatic", "requireContextMatch", "manual"};
const std::array<const char *, 3> confidence = {"high", "medium", "low"};
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
    for (int i = 1; i < 8; ++i) {
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
void rebuild(Dialog &d) {
    std::wstring query; jsti::wide(get(d.window, search).c_str(), query);
    std::transform(query.begin(), query.end(), query.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    SendDlgItemMessageW(d.window, list, LB_RESETCONTENT, 0, 0); d.visible.clear();
    for (size_t i = 0; i < d.rows.size(); ++i) {
        const auto &row = d.rows[i];
        std::wstring label, folded;
        jsti::wide((row[1] + " -> " + row[2] + (d.kind == 1 ? " [" + row[4] + "]" : "")).c_str(), label);
        folded = label;
        std::transform(folded.begin(), folded.end(), folded.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
        if (folded.find(query) == std::wstring::npos) continue;
        SendDlgItemMessageW(d.window, list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
        if (d.selected == static_cast<int>(i))
            SendDlgItemMessageW(d.window, list, LB_SETCURSEL, d.visible.size(), 0);
        d.visible.push_back(static_cast<int>(i));
    }
}
void pending(Dialog &d, bool busy) {
    for (int id : {save, remove, up, down, add, previewButton, preferences, defaults, list, importMerge, importReplace, exportJSON})
        EnableWindow(GetDlgItem(d.window, id), !busy);
}
void transfer(Dialog &d, const char *action) {
    std::vector<wchar_t> path(32768, 0);
    const bool exporting = std::strcmp(action, "export") == 0;
    if (exporting) std::wcscpy(path.data(), L"pronunciation_dictionary.json");
    OPENFILENAMEW file{}; file.lStructSize = sizeof(file); file.hwndOwner = d.window;
    file.lpstrFile = path.data(); file.nMaxFile = static_cast<DWORD>(path.size());
    file.lpstrFilter = L"JSON dictionary (*.json)\0*.json\0\0"; file.lpstrDefExt = L"json";
    file.Flags = OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_DONTADDTORECENT
        | (exporting ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    if (!(exporting ? GetSaveFileNameW(&file) : GetOpenFileNameW(&file))) {
        const DWORD failure = CommDlgExtendedError();
        if (failure) set(d.window, notice, "Dictionary file dialog failed (" + std::to_string(failure) + ").");
        return;
    }
    std::string payload = std::string(action) + "\t" + escaped(jsti::utf8(path.data()));
    pending(d, true); d.emit(70, payload.c_str(), d.kind);
}
void action(Dialog &d, const char *name) {
    std::string payload = name;
    if (std::strcmp(name, "preview") == 0) {
        payload += "\t" + escaped(get(d.window, preview)) + "\t" + escaped(get(d.window, previewTags));
    } else if (std::strcmp(name, "preferences") == 0) {
        payload += IsDlgButtonChecked(d.window, includeRules) == BST_CHECKED ? "\ttrue" : "\tfalse";
        payload += IsDlgButtonChecked(d.window, includeTags) == BST_CHECKED ? "\ttrue" : "\tfalse";
        payload += "\t" + escaped(get(d.window, tags));
    } else if (std::strcmp(name, "defaults") != 0) {
        const std::string id = d.selected >= 0 ? d.rows[static_cast<size_t>(d.selected)][0] : "";
        payload += "\t" + id;
        for (int i = 1; i < 8; ++i) payload += "\t" + escaped(value(d, i));
    }
    pending(d, true);
    set(d.window, notice, "Saving or previewing...");
    d.emit(70, payload.c_str(), d.kind);
}
int scale(HWND w, int v) { return MulDiv(v, static_cast<int>(GetDpiForWindow(w)), 96); }
void layout(Dialog &d) {
    RECT r{}; GetClientRect(d.window, &r);
    if (d.kind == 2) {
        const int inset = scale(d.window, 16);
        MoveWindow(GetDlgItem(d.window, notice), inset, inset, static_cast<int>(r.right) - 2 * inset,
            static_cast<int>(r.bottom) - 2 * inset, TRUE);
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
    move(list, 16, 80, 210, 436);
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
        || !control(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, search)
        || !control(L"LISTBOX", L"", LBS_NOTIFY | WS_TABSTOP | WS_VSCROLL | WS_BORDER, list)) return false;
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
LRESULT CALLBACK procedure(HWND w, UINT message, WPARAM wp, LPARAM lp) {
    Dialog *d = reinterpret_cast<Dialog *>(GetWindowLongPtrW(w, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        d = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lp)->lpCreateParams);
        d->window = w; SetWindowLongPtrW(w, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(d));
    }
    if (!d) return DefWindowProcW(w, message, wp, lp);
    switch (message) {
    case WM_CREATE: return createControls(*d) ? 0 : -1;
    case WM_SIZE: layout(*d); return 0;
    case WM_MOUSEWHEEL:
        if (d->kind != 2) {
            d->scroll -= scale(w, 72) * GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA;
            layout(*d); return 0;
        }
        break;
    case WM_DPICHANGED: {
        if (!updateFont(*d)) jsti_window_update("Vocabulary font could not be updated for this display.", nullptr, -1);
        const RECT *bounds = reinterpret_cast<const RECT *>(lp);
        SetWindowPos(w, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOACTIVATE | SWP_NOZORDER);
        layout(*d); return 0;
    }
    case WM_GETMINMAXINFO:
        reinterpret_cast<MINMAXINFO *>(lp)->ptMinTrackSize = {scale(w, 800), scale(w, 480)}; return 0;
    case WM_VSCROLL: {
        SCROLLINFO si{}; si.cbSize = sizeof(si); si.fMask = SIF_ALL; GetScrollInfo(w, SB_VERT, &si);
        if (LOWORD(wp) == SB_THUMBTRACK) d->scroll = si.nTrackPos;
        else if (LOWORD(wp) == SB_LINEUP) d->scroll -= scale(w, 36);
        else if (LOWORD(wp) == SB_LINEDOWN) d->scroll += scale(w, 36);
        else if (LOWORD(wp) == SB_PAGEUP) d->scroll -= static_cast<int>(si.nPage);
        else if (LOWORD(wp) == SB_PAGEDOWN) d->scroll += static_cast<int>(si.nPage);
        layout(*d); return 0;
    }
    case update: {
        std::unique_ptr<Update> data(reinterpret_cast<Update *>(lp));
        if (!data->refresh || d->kind == 2) {
            set(w, notice, data->payload);
            if (d->kind != 2) pending(*d, false);
            return 0;
        }
        auto lines = split(data->payload, '\n');
        if (lines.empty()) return 0;
        auto header = split(lines[0], '\t');
        set(w, notice, decoded(header[0]));
        if (header.size() == 4) {
            CheckDlgButton(w, includeRules, header[1] == "true" ? BST_CHECKED : BST_UNCHECKED);
            CheckDlgButton(w, includeTags, header[2] == "true" ? BST_CHECKED : BST_UNCHECKED);
            set(w, tags, decoded(header[3]));
        }
        std::string selected = d->selected >= 0 ? d->rows[static_cast<size_t>(d->selected)][0] : "";
        d->rows.clear(); d->selected = -1; SendDlgItemMessageW(w, list, LB_RESETCONTENT, 0, 0);
        for (size_t i = 1; i < lines.size(); ++i) {
            auto fields = split(lines[i], '\t');
            if (fields.size() != 8) continue;
            Row row;
            for (size_t j = 0; j < 8; ++j) row[j] = decoded(fields[j]);
            if (row[0] == selected) d->selected = static_cast<int>(d->rows.size());
            d->rows.push_back(std::move(row));
        }
        rebuild(*d);
        if (d->selected >= 0) fill(*d, d->rows[static_cast<size_t>(d->selected)]);
        pending(*d, false); return 0;
    }
    case WM_COMMAND: {
        const int id = LOWORD(wp);
        if (id == IDCANCEL) { DestroyWindow(w); return 0; }
        if (HIWORD(wp) == EN_SETFOCUS || HIWORD(wp) == CBN_SETFOCUS
            || HIWORD(wp) == LBN_SETFOCUS || HIWORD(wp) == BN_SETFOCUS) {
            RECT bounds{}, client{};
            GetWindowRect(reinterpret_cast<HWND>(lp), &bounds); GetClientRect(w, &client);
            MapWindowPoints(nullptr, w, reinterpret_cast<POINT *>(&bounds), 2);
            if (bounds.top < 0) d->scroll += bounds.top;
            else if (bounds.bottom > client.bottom) d->scroll += bounds.bottom - client.bottom;
            layout(*d);
        }
        if (id == search && HIWORD(wp) == EN_CHANGE) { rebuild(*d); return 0; }
        if (id == list && HIWORD(wp) == LBN_SELCHANGE) {
            const int index = static_cast<int>(SendDlgItemMessageW(w, list, LB_GETCURSEL, 0, 0));
            d->selected = index >= 0 && static_cast<size_t>(index) < d->visible.size() ? d->visible[static_cast<size_t>(index)] : -1;
            if (d->selected >= 0) fill(*d, d->rows[static_cast<size_t>(d->selected)]);
            return 0;
        }
        if (HIWORD(wp) != BN_CLICKED) break;
        if (id == add) {
            d->selected = -1; Row row{};
            row[4] = d->kind == 0 ? "automatic" : "";
            row[6] = d->kind == 0 ? "high" : "false"; row[5] = d->kind == 0 ? "" : "false";
            fill(*d, row); return 0;
        }
        if (id == remove && (d->selected < 0 || MessageBoxW(w, L"Delete this saved entry?", L"Confirm deletion",
            MB_YESNO | MB_ICONQUESTION) != IDYES)) return 0;
        if ((id == remove || id == up || id == down) && d->selected < 0) return 0;
        if (id == save) action(*d, "save");
        else if (id == remove) action(*d, "delete");
        else if (id == up) action(*d, "up");
        else if (id == down) action(*d, "down");
        else if (id == previewButton) action(*d, "preview");
        else if (id == preferences) action(*d, "preferences");
        else if (id == defaults) action(*d, "defaults");
        else if (id == importMerge) transfer(*d, "importMerge");
        else if (id == importReplace) {
            if (MessageBoxW(w, L"Replace this dictionary with the imported file?", L"Confirm replacement",
                MB_YESNO | MB_ICONQUESTION) == IDYES) transfer(*d, "importReplace");
        }
        else if (id == exportJSON) transfer(*d, "export");
        return 0;
    }
    case WM_CLOSE: DestroyWindow(w); return 0;
    case WM_DESTROY: {
        { std::lock_guard<std::mutex> lock(mutex); active = nullptr; activeKind = -1; }
        MSG queued{};
        while (PeekMessageW(&queued, w, update, update, PM_REMOVE)) delete reinterpret_cast<Update *>(queued.lParam);
        if (d->font) DeleteObject(d->font);
        return 0;
    }
    }
    return DefWindowProcW(w, message, wp, lp);
}
HWND createWindow(HWND owner, Dialog &dialog) {
    WNDCLASSW type{}; type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItVocabulary"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    return CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName,
        dialog.kind == 0 ? L"Corrections - Just Speak to It" : dialog.kind == 1
            ? L"Pronunciation - Just Speak to It" : L"Recording corrections - Just Speak to It",
        WS_OVERLAPPEDWINDOW | WS_VSCROLL, CW_USEDEFAULT, CW_USEDEFAULT, scale(owner, 850), scale(owner, 740),
        owner, nullptr, type.hInstance, &dialog);
}
}

static void showDialog(HWND owner, int kind, const char *record, void (*emit)(int, const char *, int)) {
    Dialog dialog; dialog.kind = kind; dialog.emit = emit;
    HWND window = createWindow(owner, dialog);
    if (!window) { jsti_window_update("The vocabulary editor could not be opened.", nullptr, -1); return; }
    { std::lock_guard<std::mutex> lock(mutex); active = window; activeKind = kind; }
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW);
    emit(kind == 2 ? 72 : 71, record ? record : "", kind);
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
}

void jsti_show_vocabulary(HWND owner, int kind, void (*emit)(int, const char *, int)) {
    showDialog(owner, kind, nullptr, emit);
}
void jsti_show_vocabulary_result(HWND owner, const char *record, void (*emit)(int, const char *, int)) {
    showDialog(owner, 2, record, emit);
}

int32_t jsti_vocabulary_set(int32_t kind, const char *payload, int32_t refresh) {
    if (kind < 0 || kind > 2 || !payload || std::strlen(payload) > 4 * 1024 * 1024) return -1;
    auto data = std::make_unique<Update>(); data->payload = payload; data->refresh = refresh != 0;
    std::lock_guard<std::mutex> lock(mutex);
    if (!active || activeKind != kind) return 0;
    if (!PostMessageW(active, update, 0, reinterpret_cast<LPARAM>(data.get()))) return -1;
    data.release(); return 0;
}

bool jsti_vocabulary_self_test(HWND owner, std::string &error) {
    static std::string captured;
    for (int kind = 0; kind < 3; ++kind) {
        Dialog dialog; dialog.kind = kind;
        dialog.emit = [](int event, const char *payload, int) { if (event == 70) captured = payload; };
        HWND window = createWindow(owner, dialog);
        if (!window) { error = "Vocabulary controls could not be created."; return false; }
        if (kind == 2) {
            set(window, notice, "Applied\nSynthetic -> Canonical\nSuggestions\nmanual\t%");
            const bool valid = get(window, notice) == "Applied\nSynthetic -> Canonical\nSuggestions\nmanual\t%";
            DestroyWindow(window);
            if (!valid) { error = "Correction results did not preserve readable multiline text."; return false; }
            continue;
        }
        Row row{}; row[1] = "Synthetic"; row[2] = "Canonical"; row[3] = "spoken\nvariant\t%";
        row[4] = kind == 0 ? "manual" : "Custom"; row[5] = kind == 0 ? "work" : "true";
        row[6] = kind == 0 ? "low" : "true"; row[7] = "fixture notes";
        fill(dialog, row); action(dialog, "save");
        auto fields = split(captured, '\t');
        bool valid = fields.size() == 9 && decoded(fields[2]) == row[1]
            && decoded(fields[4]) == row[3] && decoded(fields[5]) == row[4]
            && decoded(fields[7]) == row[6];
        set(window, preview, "Synthetic\t%\n"); set(window, previewTags, "work");
        action(dialog, "preview"); fields = split(captured, '\t');
        valid = valid && fields.size() == 3 && decoded(fields[1]) == "Synthetic\t%\n"
            && decoded(fields[2]) == "work";
        DestroyWindow(window);
        if (!valid) { error = "Vocabulary editor did not preserve field or preview events."; return false; }
    }
    return true;
}
