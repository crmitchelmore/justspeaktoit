#include "WindowsVocabularyInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <commdlg.h>
#include <cwctype>
#include <mutex>

void jsti_show_vocabulary(HWND owner, int kind, void (*emit)(int, const char *, int));

namespace jsti::vocabulary {
namespace {
// The open editor jsti_vocabulary_set delivers to. Host threads post through
// it; the UI thread opens and closes it.
class ActiveEditor {
public:
    void open(HWND window, int kind) {
        std::lock_guard<std::mutex> lock(mutex_);
        window_ = window; kind_ = kind;
    }
    void close(HWND window) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (window_ == window) { window_ = nullptr; kind_ = -1; }
    }
    // 0 when delivered or when no editor of `kind` is open; -1 if posting failed.
    int deliver(int kind, std::unique_ptr<Update> data) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!window_ || kind_ != kind) return 0;
        if (!PostMessageW(window_, update, 0, reinterpret_cast<LPARAM>(data.get()))) return -1;
        data.release(); return 0;
    }
private:
    std::mutex mutex_;
    HWND window_ = nullptr;
    int kind_ = -1;
};
ActiveEditor &activeEditor() {
    static ActiveEditor editor;
    return editor;
}
} // namespace
using jsti::chrome::scale;

void activateEditor(HWND window, int kind) { activeEditor().open(window, kind); }

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

namespace {
bool hiddenSelection(const Dialog &d) {
    return (d.kind == 1 || d.kind == 4) && d.selected >= 0
        && std::find(d.visible.begin(), d.visible.end(), d.selected) == d.visible.end();
}
void selectionControls(Dialog &d) {
    if (d.kind != 1 && d.kind != 4) return;
    for (int id : {save, remove, up, down})
        EnableWindow(GetDlgItem(d.window, id), !d.busy && !hiddenSelection(d));
}
bool categoryOptions(const std::vector<std::string> &header, const std::vector<Row> &rows,
                     std::vector<Category> &options) {
    options = {{"", rows.size()}};
    if (header.size() == 4) return true;
    if (header.size() < 6 || header[4] != "pronunciationCategories.v1"
        || (header.size() - 6) % 2 != 0 || header[5] != std::to_string(rows.size())) return false;
    for (size_t i = 6; i < header.size(); i += 2) {
        const auto name = decoded(header[i]);
        const size_t count = static_cast<size_t>(std::count_if(rows.begin(), rows.end(),
            [&](const Row &row) { return row[4] == name; }));
        if (name.empty() || count == 0 || header[i + 1] != std::to_string(count)
            || std::any_of(options.begin(), options.end(), [&](const Category &item) { return item.value == name; }))
            return false;
        options.push_back({name, count});
    }
    return true;
}
void rebuild(Dialog &d) {
    std::wstring query; jsti::wide(get(d.window, search).c_str(), query);
    std::transform(query.begin(), query.end(), query.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    SendDlgItemMessageW(d.window, list, LB_RESETCONTENT, 0, 0); d.visible.clear();
    for (size_t i = 0; i < d.rows.size(); ++i) {
        const auto &row = d.rows[i];
        std::wstring label, folded;
        const std::string suffix = d.kind == 3 ? " (seen " + row[3] + "; " + row[7] + ")"
            : d.kind == 1 ? " [" + row[4] + "]" : "";
        jsti::wide((row[1] + " -> " + row[2] + suffix).c_str(), label);
        bool match = false;
        if (d.kind == 1) {
            if (!d.category.empty() && row[4] != d.category) continue;
            for (size_t index : {1, 2, 3}) {
                jsti::wide(row[index].c_str(), folded);
                std::transform(folded.begin(), folded.end(), folded.begin(),
                    [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
                match = match || folded.find(query) != std::wstring::npos;
            }
        } else {
            folded = label;
            std::transform(folded.begin(), folded.end(), folded.begin(),
                [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
            match = folded.find(query) != std::wstring::npos;
        }
        if (!match) continue;
        SendDlgItemMessageW(d.window, list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
        if (d.selected == static_cast<int>(i))
            SendDlgItemMessageW(d.window, list, LB_SETCURSEL, d.visible.size(), 0);
        d.visible.push_back(static_cast<int>(i));
    }
    selectionControls(d);
}
} // namespace

void pending(Dialog &d, bool busy) {
    d.busy = busy;
    for (int id : {save, remove, up, down, add, previewButton, preferences, defaults, list, importMerge,
         importReplace, exportJSON, reviewCandidates, promoteCandidate, dismissCandidate, clearCandidates,
         allowLearning, legacyDictionary})
        EnableWindow(GetDlgItem(d.window, id), !busy);
    if (d.kind == 4)
        for (int id : std::array<int, 3>{field, field + 1, search}) EnableWindow(GetDlgItem(d.window, id), !busy);
    selectionControls(d);
}
namespace {
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
} // namespace
void action(Dialog &d, const char *name) {
    if (hiddenSelection(d) && (std::strcmp(name, "save") == 0 || std::strcmp(name, "delete") == 0
        || std::strcmp(name, "up") == 0 || std::strcmp(name, "down") == 0)) {
        set(d.window, notice, "The selected entry is hidden by filters. Clear filters or select a visible entry.");
        return;
    }
    std::string payload = name;
    if (d.kind == 4) {
        payload += "\t" + (d.selected >= 0 ? d.rows[static_cast<size_t>(d.selected)][0] : "");
        payload += "\t" + escaped(get(d.window, field)) + "\t" + escaped(get(d.window, field + 1));
    } else if (d.kind == 3) {
        if (std::strcmp(name, "clear") != 0 && std::strcmp(name, "allowLearning") != 0
            && std::strcmp(name, "stopLearning") != 0) {
            if (d.selected < 0) { set(d.window, notice, "Select a stored candidate first."); return; }
            payload += "\t" + escaped(d.rows[static_cast<size_t>(d.selected)][0]);
        }
    } else if (std::strcmp(name, "preview") == 0) {
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
    set(d.window, notice, std::strcmp(name, "stopLearning") == 0
        ? "Stop requested; waiting for confirmation..." : "Saving or previewing...");
    d.emit(70, payload.c_str(), d.kind);
}

namespace {
LRESULT CALLBACK procedure(HWND w, UINT message, WPARAM wp, LPARAM lp) {
    Dialog *d = reinterpret_cast<Dialog *>(GetWindowLongPtrW(w, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        d = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lp)->lpCreateParams);
        d->window = w; SetWindowLongPtrW(w, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(d));
    }
    if (!d) return DefWindowProcW(w, message, wp, lp);
    LRESULT themed = 0;
    if (jsti::chrome::dialogMessage(w, message, wp, lp, themed)) return themed;
    switch (message) {
    case WM_CREATE: return createControls(*d) ? 0 : -1;
    case WM_SIZE: layout(*d); return 0;
    case WM_MOUSEWHEEL:
        if (d->kind < 2) {
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
        const std::string responseNotice = decoded(header[0]);
        set(w, notice, d->kind == 3 && responseNotice.empty()
            ? "Only stored candidates are listed. Automatic observation of edits in other apps is not available."
            : responseNotice);
        if (d->kind == 0 && header.size() == 4) {
            CheckDlgButton(w, includeRules, header[1] == "true" ? BST_CHECKED : BST_UNCHECKED);
            CheckDlgButton(w, includeTags, header[2] == "true" ? BST_CHECKED : BST_UNCHECKED);
            set(w, tags, decoded(header[3]));
        }
        std::vector<Row> rows;
        for (size_t i = 1; i < lines.size(); ++i) {
            auto fields = split(lines[i], '\t');
            if (fields.size() != 8) continue;
            Row row;
            for (size_t j = 0; j < 8; ++j) row[j] = decoded(fields[j]);
            rows.push_back(std::move(row));
        }
        std::vector<Category> categories;
        if (d->kind == 1 && !categoryOptions(header, rows, categories)) {
            set(w, notice, "Invalid pronunciation category metadata. Reload the editor before making changes.");
            pending(*d, true); return 0;
        }
        const std::string selected = d->selected >= 0 ? d->rows[static_cast<size_t>(d->selected)][0] : "";
        d->rows = std::move(rows); d->selected = -1;
        for (size_t i = 0; i < d->rows.size(); ++i)
            if (d->rows[i][0] == selected) d->selected = static_cast<int>(i);
        if (d->kind == 1) updateCategories(*d, std::move(categories));
        rebuild(*d);
        if (d->selected >= 0) fill(*d, d->rows[static_cast<size_t>(d->selected)]);
        else if (!selected.empty() && (d->kind == 1 || d->kind == 4)) fill(*d, Row{});
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
        if (id == categoryFilter && HIWORD(wp) == CBN_SELCHANGE && d->kind == 1) {
            const auto chosen = SendDlgItemMessageW(w, categoryFilter, CB_GETCURSEL, 0, 0);
            if (chosen >= 0 && static_cast<size_t>(chosen) < d->categories.size())
                d->category = d->categories[static_cast<size_t>(chosen)].value;
            rebuild(*d); return 0;
        }
        if (id == list && HIWORD(wp) == LBN_SELCHANGE) {
            const int index = static_cast<int>(SendDlgItemMessageW(w, list, LB_GETCURSEL, 0, 0));
            d->selected = index >= 0 && static_cast<size_t>(index) < d->visible.size() ? d->visible[static_cast<size_t>(index)] : -1;
            if (d->selected >= 0) fill(*d, d->rows[static_cast<size_t>(d->selected)]);
            selectionControls(*d);
            return 0;
        }
        if (HIWORD(wp) != BN_CLICKED) break;
        if ((id == reviewCandidates && d->kind == 0) || (id == legacyDictionary && d->kind == 1)) {
            jsti_show_vocabulary(w, id == legacyDictionary ? 4 : 3, d->emit);
            if (IsWindow(w)) {
                activateEditor(w, d->kind);
                pending(*d, true); d->emit(71, "", d->kind);
            }
            return 0;
        }
        if (d->kind == 3) {
            if (id == reviewCandidates) { pending(*d, true); d->emit(71, "", 3); return 0; }
            if (id == clearCandidates || id == remove || id == dismissCandidate) {
                if (id != clearCandidates && d->selected < 0) {
                    set(w, notice, "Select a stored candidate first."); return 0;
                }
                const wchar_t *question = id == clearCandidates ? L"Clear all stored candidates? Saved rules stay unchanged."
                    : id == remove ? L"Remove this stored candidate?" : L"Dismiss this stored candidate?";
                if (MessageBoxW(w, question, L"Confirm candidate change", MB_YESNO | MB_ICONQUESTION) != IDYES) return 0;
            }
            if (id == allowLearning) {
                if (MessageBoxW(w, L"Allow correction learning until this app closes?\n\n"
                    L"Only the exact text range of a confirmed insertion is read after 10-30 seconds. "
                    L"Changing fields or starting another dictation cancels it. "
                    L"No unrelated fields are read. Imported settings never grant this approval.",
                    L"Allow correction learning", MB_YESNO | MB_ICONQUESTION) == IDYES)
                    action(*d, "allowLearning");
            }
            else if (id == stopLearning) action(*d, "stopLearning");
            else if (id == promoteCandidate) action(*d, "promote");
            else if (id == dismissCandidate) action(*d, "dismiss");
            else if (id == remove) action(*d, "remove");
            else if (id == clearCandidates) action(*d, "clear");
            return 0;
        }
        if (id == add) {
            d->selected = -1; Row row{};
            row[4] = d->kind == 0 ? "automatic" : "";
            row[6] = d->kind == 0 ? "high" : "false"; row[5] = d->kind == 0 ? "" : "false";
            if (d->kind == 1 || d->kind == 4)
                SendDlgItemMessageW(w, list, LB_SETCURSEL, static_cast<WPARAM>(-1), 0);
            fill(*d, row); selectionControls(*d); return 0;
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
        activeEditor().close(w);
        MSG queued{};
        while (PeekMessageW(&queued, w, update, update, PM_REMOVE)) delete reinterpret_cast<Update *>(queued.lParam);
        if (d->font) DeleteObject(d->font);
        return 0;
    }
    }
    return DefWindowProcW(w, message, wp, lp);
}
} // namespace

HWND createWindow(HWND owner, Dialog &dialog) {
    WNDCLASSW type{}; type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItVocabulary"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    return CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName,
        dialog.kind == 0 ? L"Corrections - Just Speak to It" : dialog.kind == 1
            ? L"Pronunciation - Just Speak to It" : dialog.kind == 2
                ? L"Recording corrections - Just Speak to It" : dialog.kind == 4
                    ? L"Legacy word dictionary - Just Speak to It" : L"Stored correction candidates - Just Speak to It",
        WS_OVERLAPPEDWINDOW | WS_VSCROLL, CW_USEDEFAULT, CW_USEDEFAULT, scale(owner, 850), scale(owner, 740),
        owner, nullptr, type.hInstance, &dialog);
}

namespace {
void showDialog(HWND owner, int kind, const char *record, void (*emit)(int, const char *, int)) {
    Dialog dialog; dialog.kind = kind; dialog.emit = emit;
    HWND window = createWindow(owner, dialog);
    if (!window) { jsti_window_update("The vocabulary editor could not be opened.", nullptr, -1); return; }
    activateEditor(window, kind);
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
} // namespace
} // namespace jsti::vocabulary

void jsti_show_vocabulary(HWND owner, int kind, void (*emit)(int, const char *, int)) {
    jsti::vocabulary::showDialog(owner, kind, nullptr, emit);
}
void jsti_show_vocabulary_result(HWND owner, const char *record, void (*emit)(int, const char *, int)) {
    jsti::vocabulary::showDialog(owner, 2, record, emit);
}

int32_t jsti_vocabulary_set(int32_t kind, const char *payload, int32_t refresh) {
    if (kind < 0 || kind > 4 || !payload || std::strlen(payload) > 4 * 1024 * 1024) return -1;
    auto data = std::make_unique<jsti::vocabulary::Update>();
    data->payload = payload; data->refresh = refresh != 0;
    return jsti::vocabulary::activeEditor().deliver(kind, std::move(data));
}
