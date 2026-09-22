#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commdlg.h>
#include <mutex>
#include <vector>

namespace {
enum Control { listID = 500, addID, removeID, upID, downID, nameID, pathsID, browseID,
    transcriptionID, polishModeID, polishModelID, promptID, outputID, languageID, notesID };
struct Draft {
    std::string id;
    std::wstring name, paths, prompt, output, notes;
    int transcription = -1, polishMode = 0, polishModel = -1, language = -1;
};
struct Configuration {
    std::vector<Draft> drafts;
    std::vector<std::wstring> transcription, polish, languages;
    std::wstring notice;
    JSTIProfilesCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex configurationMutex;
Configuration configuration;
struct Dialog {
    Configuration config;
    std::vector<HWND> controls;
    HFONT font = nullptr;
    int selected = -1;
    int scroll = 0;
    bool loading = false, accepted = false;
};
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
std::wstring text(HWND window, int id) {
    HWND control = GetDlgItem(window, id);
    const int length = GetWindowTextLengthW(control);
    std::wstring value(static_cast<size_t>(length) + 1, 0);
    value.resize(static_cast<size_t>(GetWindowTextW(control, value.data(), length + 1)));
    return value;
}
int choice(HWND window, int id, size_t count) {
    const LRESULT selected = SendDlgItemMessageW(window, id, CB_GETCURSEL, 0, 0);
    if (selected == CB_ERR) return -1;
    return static_cast<size_t>(selected) == count + 1 ? -2 : static_cast<int>(selected) - 1;
}
void choices(HWND window, int id, const std::vector<std::wstring> &names, int selected) {
    HWND combo = GetDlgItem(window, id);
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Use app setting"));
    for (const auto &name : names) SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str()));
    if (selected == -2) SendMessageW(combo, CB_ADDSTRING, 0,
        reinterpret_cast<LPARAM>(L"Keep stored value (unavailable here; see notes)"));
    SendMessageW(combo, CB_SETCURSEL, selected == -2 ? names.size() + 1 : static_cast<size_t>(selected + 1), 0);
}
void storeCurrent(HWND window, Dialog &dialog) {
    if (dialog.loading || dialog.selected < 0 || static_cast<size_t>(dialog.selected) >= dialog.config.drafts.size()) return;
    auto &draft = dialog.config.drafts[static_cast<size_t>(dialog.selected)];
    draft.name = text(window, nameID); draft.paths = text(window, pathsID);
    draft.prompt = text(window, promptID); draft.output = text(window, outputID);
    draft.transcription = choice(window, transcriptionID, dialog.config.transcription.size());
    draft.polishModel = choice(window, polishModelID, dialog.config.polish.size());
    draft.language = choice(window, languageID, dialog.config.languages.size());
    draft.polishMode = static_cast<int>(SendDlgItemMessageW(window, polishModeID, CB_GETCURSEL, 0, 0));
}
void populate(HWND window, Dialog &dialog) {
    dialog.loading = true;
    SendDlgItemMessageW(window, listID, LB_RESETCONTENT, 0, 0);
    for (const auto &draft : dialog.config.drafts) SendDlgItemMessageW(window, listID, LB_ADDSTRING, 0,
        reinterpret_cast<LPARAM>(draft.name.empty() ? L"Unnamed profile" : draft.name.c_str()));
    SendDlgItemMessageW(window, listID, LB_SETCURSEL, static_cast<WPARAM>(dialog.selected), 0);
    const bool selected = dialog.selected >= 0 && static_cast<size_t>(dialog.selected) < dialog.config.drafts.size();
    const Draft empty;
    const Draft &draft = selected ? dialog.config.drafts[static_cast<size_t>(dialog.selected)] : empty;
    for (int id : {removeID, upID, downID, nameID, pathsID, browseID, transcriptionID, polishModeID,
                   polishModelID, promptID, outputID, languageID}) EnableWindow(GetDlgItem(window, id), selected);
    EnableWindow(GetDlgItem(window, upID), selected && dialog.selected > 0);
    EnableWindow(GetDlgItem(window, downID), selected && static_cast<size_t>(dialog.selected + 1) < dialog.config.drafts.size());
    SetDlgItemTextW(window, nameID, draft.name.c_str()); SetDlgItemTextW(window, pathsID, draft.paths.c_str());
    SetDlgItemTextW(window, promptID, draft.prompt.c_str()); SetDlgItemTextW(window, outputID, draft.output.c_str());
    std::wstring notes = dialog.config.notice;
    if (!notes.empty()) notes += L"\n";
    notes += selected ? draft.notes : L"Add a profile to customise dictation for an app.";
    SetDlgItemTextW(window, notesID, notes.c_str());
    choices(window, transcriptionID, dialog.config.transcription, draft.transcription);
    choices(window, polishModelID, dialog.config.polish, draft.polishModel);
    choices(window, languageID, dialog.config.languages, draft.language);
    SendDlgItemMessageW(window, polishModeID, CB_SETCURSEL, draft.polishMode, 0);
    dialog.loading = false;
}
void font(HWND window, Dialog &dialog) {
    HFONT replacement = CreateFontW(-MulDiv(10, static_cast<int>(GetDpiForWindow(window)), 72),
        0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!replacement) return;
    for (HWND control : dialog.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(replacement), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = replacement;
}
void layout(HWND window) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int m = scale(window, 16), gap = scale(window, 8), row = scale(window, 28), label = scale(window, 20);
    const int left = scale(window, 205), x = left + 2 * m, width = static_cast<int>(bounds.right) - x - m;
    const int height = std::max(static_cast<int>(bounds.bottom), scale(window, 680));
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (!dialog) return;
    dialog->scroll = std::clamp(dialog->scroll, 0, height - static_cast<int>(bounds.bottom));
    SCROLLINFO scroll{}; scroll.cbSize = sizeof(scroll); scroll.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    scroll.nMax = height - 1; scroll.nPage = static_cast<UINT>(bounds.bottom); scroll.nPos = dialog->scroll;
    SetScrollInfo(window, SB_VERT, &scroll, TRUE);
    auto move = [&](int id, int xx, int y, int w, int h) {
        MoveWindow(GetDlgItem(window, id), xx, y - dialog->scroll, w, h, TRUE);
    };
    move(600, m, m, left, scale(window, 40));
    move(listID, m, scale(window, 60), left, std::max(row, height - scale(window, 170)));
    const int half = (left - gap) / 2, bottom = height - scale(window, 102);
    move(addID, m, bottom, half, row); move(removeID, m + half + gap, bottom, half, row);
    move(upID, m, bottom + row + gap, half, row); move(downID, m + half + gap, bottom + row + gap, half, row);
    auto field = [&](int labelID, int controlID, int y, int h) {
        move(labelID, x, scale(window, y), width, label);
        move(controlID, x, scale(window, y) + label + scale(window, 3), width, scale(window, h));
    };
    field(601, nameID, 16, 28); field(602, pathsID, 73, 55);
    move(browseID, x + width - scale(window, 100), scale(window, 153), scale(window, 100), row);
    field(603, transcriptionID, 189, 240); field(604, languageID, 246, 240);
    field(605, polishModeID, 303, 120); field(606, polishModelID, 360, 240);
    field(607, promptID, 417, 64); field(608, outputID, 510, 28);
    move(notesID, x, scale(window, 568), width, std::max(scale(window, 40), height - scale(window, 626)));
    move(IDOK, static_cast<int>(bounds.right) - m - scale(window, 208), height - m - row, scale(window, 100), row);
    move(IDCANCEL, static_cast<int>(bounds.right) - m - scale(window, 100), height - m - row, scale(window, 100), row);
}
bool controls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *title, DWORD style, int id) {
        HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, kind, title,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
            GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const DWORD combo = CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL;
    const DWORD edit = ES_AUTOHSCROLL | WS_TABSTOP;
    const DWORD multiline = ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_TABSTOP | WS_VSCROLL;
    const DWORD button = BS_PUSHBUTTON | WS_TABSTOP;
    if (!(add(L"STATIC", L"&Profiles\nFirst matching profile wins", 0, 600) &&
        add(L"LISTBOX", L"", LBS_NOTIFY | WS_BORDER | WS_VSCROLL | WS_TABSTOP, listID) &&
        add(L"BUTTON", L"&Add", button, addID) && add(L"BUTTON", L"&Remove", button, removeID) &&
        add(L"BUTTON", L"Move &up", button, upID) && add(L"BUTTON", L"Move &down", button, downID) &&
        add(L"STATIC", L"Profile &name", 0, 601) && add(L"EDIT", L"", edit, nameID) &&
        add(L"STATIC", L"Application &paths (one complete path per line)", 0, 602) &&
        add(L"EDIT", L"", multiline, pathsID) && add(L"BUTTON", L"&Browse…", button, browseID) &&
        add(L"STATIC", L"&Transcription model", 0, 603) && add(L"COMBOBOX", L"", combo, transcriptionID) &&
        add(L"STATIC", L"Spoken &language", 0, 604) && add(L"COMBOBOX", L"", combo, languageID) &&
        add(L"STATIC", L"&Polish transcript", 0, 605) && add(L"COMBOBOX", L"", combo, polishModeID) &&
        add(L"STATIC", L"Polish &model", 0, 606) && add(L"COMBOBOX", L"", combo, polishModelID) &&
        add(L"STATIC", L"Polish &instructions (blank keeps the app setting)", 0, 607) &&
        add(L"EDIT", L"", multiline, promptID) && add(L"STATIC", L"Polish &output language", 0, 608) &&
        add(L"EDIT", L"", edit, outputID) && add(L"STATIC", L"", SS_LEFT, notesID) &&
        add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", button, IDCANCEL))) return false;
    for (const wchar_t *value : {L"Use app setting", L"Disabled", L"Enabled"})
        SendDlgItemMessageW(window, polishModeID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(value));
    SendDlgItemMessageW(window, nameID, EM_LIMITTEXT, 256, 0);
    for (int id : {pathsID, promptID}) SendDlgItemMessageW(window, id, EM_LIMITTEXT, 65535, 0);
    SendDlgItemMessageW(window, outputID, EM_LIMITTEXT, 256, 0);
    font(window, dialog); populate(window, dialog); return true;
}
void browse(HWND window) {
    std::vector<wchar_t> path(32768, 0);
    OPENFILENAMEW file{}; file.lStructSize = sizeof(file); file.hwndOwner = window;
    file.lpstrFilter = L"Applications (*.exe)\0*.exe\0All files\0*.*\0\0";
    file.lpstrFile = path.data(); file.nMaxFile = static_cast<DWORD>(path.size());
    file.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_DONTADDTORECENT;
    if (!GetOpenFileNameW(&file)) return;
    std::wstring paths = text(window, pathsID);
    if (!paths.empty()) paths += L"\r\n";
    paths += path.data();
    if (paths.size() > 65535) { SetDlgItemTextW(window, notesID, L"Too many application paths."); return; }
    SetDlgItemTextW(window, pathsID, paths.c_str());
}
bool apply(HWND window, Dialog &dialog) {
    storeCurrent(window, dialog);
    struct Strings { std::string name, paths, prompt, output, notes; };
    std::vector<Strings> strings(dialog.config.drafts.size());
    std::vector<JSTIProfileDraft> values(dialog.config.drafts.size());
    for (size_t i = 0; i < values.size(); ++i) {
        const auto &draft = dialog.config.drafts[i]; auto &s = strings[i];
        s = {jsti::utf8(draft.name), jsti::utf8(draft.paths), jsti::utf8(draft.prompt),
             jsti::utf8(draft.output), jsti::utf8(draft.notes)};
        values[i] = {draft.id.c_str(), s.name.c_str(), s.paths.c_str(), s.prompt.c_str(), s.output.c_str(),
                     s.notes.c_str(), draft.transcription, draft.polishMode, draft.polishModel, draft.language};
    }
    char error[2048] = {};
    if (dialog.config.callback(1, values.data(), values.size(), dialog.config.context, error, sizeof(error)) != 0) {
        std::wstring message;
        if (!jsti::wide(error, message) || message.empty()) message = L"Profile changes could not be applied.";
        SetDlgItemTextW(window, notesID, message.c_str()); return false;
    }
    dialog.accepted = true; return true;
}
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: return controls(window, *dialog) ? 0 : -1;
    case WM_SIZE: layout(window); return 0;
    case WM_GETMINMAXINFO:
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {scale(window, 810), scale(window, 420)}; return 0;
    case WM_VSCROLL: {
        SCROLLINFO info{}; info.cbSize = sizeof(info); info.fMask = SIF_ALL;
        GetScrollInfo(window, SB_VERT, &info);
        switch (LOWORD(wparam)) {
        case SB_LINEUP: dialog->scroll -= scale(window, 32); break;
        case SB_LINEDOWN: dialog->scroll += scale(window, 32); break;
        case SB_PAGEUP: dialog->scroll -= static_cast<int>(info.nPage); break;
        case SB_PAGEDOWN: dialog->scroll += static_cast<int>(info.nPage); break;
        case SB_THUMBTRACK: dialog->scroll = info.nTrackPos; break;
        case SB_TOP: dialog->scroll = 0; break;
        case SB_BOTTOM: dialog->scroll = info.nMax; break;
        default: break;
        }
        layout(window); return 0;
    }
    case WM_MOUSEWHEEL:
        dialog->scroll -= GET_WHEEL_DELTA_WPARAM(wparam) * scale(window, 72) / WHEEL_DELTA;
        layout(window); return 0;
    case WM_DPICHANGED: {
        const RECT *bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        font(window, *dialog); layout(window); return 0;
    }
    case WM_COMMAND: {
        const int id = LOWORD(wparam);
        if (lparam && GetFocus() == reinterpret_cast<HWND>(lparam) &&
            (HIWORD(wparam) == EN_SETFOCUS || HIWORD(wparam) == CBN_SETFOCUS || HIWORD(wparam) == BN_SETFOCUS)) {
            RECT control{}, bounds{};
            GetWindowRect(reinterpret_cast<HWND>(lparam), &control);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&control), 2);
            GetClientRect(window, &bounds);
            if (control.top < 0) dialog->scroll += control.top - scale(window, 8);
            else if (control.bottom > bounds.bottom) dialog->scroll += control.bottom - bounds.bottom + scale(window, 8);
            layout(window);
        }
        if (id == IDCANCEL) { DestroyWindow(window); return 0; }
        if (id == IDOK) { if (apply(window, *dialog)) DestroyWindow(window); return 0; }
        if (id == browseID) { browse(window); return 0; }
        if (id == listID && HIWORD(wparam) == LBN_SELCHANGE) {
            const int selected = static_cast<int>(SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0));
            storeCurrent(window, *dialog); dialog->selected = selected; populate(window, *dialog); return 0;
        }
        if (id == addID || id == removeID || id == upID || id == downID) {
            storeCurrent(window, *dialog); auto &rows = dialog->config.drafts;
            if (id == addID && rows.size() < 1000) {
                rows.emplace_back(); rows.back().name = L"New profile"; dialog->selected = static_cast<int>(rows.size() - 1);
            } else if (dialog->selected >= 0 && static_cast<size_t>(dialog->selected) < rows.size()) {
                const size_t selected = static_cast<size_t>(dialog->selected);
                if (id == removeID) { rows.erase(rows.begin() + dialog->selected); dialog->selected = rows.empty() ? -1 :
                    static_cast<int>(std::min(selected, rows.size() - 1)); }
                if (id == upID && selected > 0) { std::swap(rows[selected], rows[selected - 1]); --dialog->selected; }
                if (id == downID && selected + 1 < rows.size()) { std::swap(rows[selected], rows[selected + 1]); ++dialog->selected; }
            }
            populate(window, *dialog); return 0;
        }
        break;
    }
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        if (dialog->font) { DeleteObject(dialog->font); dialog->font = nullptr; }
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
HWND create(HWND owner, Dialog &dialog) {
    WNDCLASSW type{}; type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItProfiles"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT bounds{}; GetWindowRect(owner, &bounds);
    RECT work{}; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    const int height = std::min(scale(owner, 760), static_cast<int>(work.bottom - work.top));
    const int top = std::clamp(static_cast<int>(bounds.top + scale(owner, 20)),
        static_cast<int>(work.top), std::max(static_cast<int>(work.top), static_cast<int>(work.bottom) - height));
    return CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, type.lpszClassName,
        L"App profiles — Just Speak to It", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_VSCROLL,
        bounds.left + scale(owner, 20), top, scale(owner, 880), height,
        owner, nullptr, type.hInstance, &dialog);
}
bool copyNames(const char *const *names, size_t count, std::vector<std::wstring> &result) {
    if ((count && !names) || count > 10000) return false;
    result.resize(count);
    for (size_t i = 0; i < count; ++i) if (!jsti::wide(names[i], result[i]) || result[i].size() > 2048) return false;
    return true;
}
}

void jsti_show_profiles(HWND owner) {
    Dialog dialog;
    { std::lock_guard<std::mutex> lock(configurationMutex); dialog.config = configuration; }
    if (!dialog.config.callback) return;
    dialog.selected = dialog.config.drafts.empty() ? -1 : 0;
    HWND window = create(owner, dialog);
    if (!window) {
        dialog.config.callback(0, nullptr, 0, dialog.config.context, nullptr, 0);
        jsti_window_update(jsti::systemError("Opening app profiles").c_str(), nullptr, -1); return;
    }
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, listID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (!dialog.accepted) dialog.config.callback(0, nullptr, 0, dialog.config.context, nullptr, 0);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
}

void jsti_cancel_profiles_request() {
    Configuration current;
    { std::lock_guard<std::mutex> lock(configurationMutex); current = configuration; }
    if (current.callback) current.callback(0, nullptr, 0, current.context, nullptr, 0);
}

int jsti_window_set_profiles(const JSTIProfileDraft *drafts, size_t count,
                            const char *const *transcription, size_t transcriptionCount,
                            const char *const *polish, size_t polishCount,
                            const char *const *languages, size_t languageCount,
                            const char *notice,
                            JSTIProfilesCallback callback, void *context) {
    if ((count && !drafts) || count > 1000 || !callback) return -1;
    try {
        Configuration updated;
        if (!jsti::wide(notice ? notice : "", updated.notice) || updated.notice.size() > 65535) return -1;
        if (!copyNames(transcription, transcriptionCount, updated.transcription) ||
            !copyNames(polish, polishCount, updated.polish) || !copyNames(languages, languageCount, updated.languages)) return -1;
        updated.drafts.resize(count);
        for (size_t i = 0; i < count; ++i) {
            const auto &source = drafts[i]; auto &target = updated.drafts[i];
            if (!source.id || std::strlen(source.id) > 36 || !jsti::wide(source.name, target.name) ||
                !jsti::wide(source.paths, target.paths) || !jsti::wide(source.prompt, target.prompt) ||
                !jsti::wide(source.output_language, target.output) || !jsti::wide(source.notes, target.notes) ||
                target.name.size() > 256 || target.paths.size() > 65535 || target.prompt.size() > 65535 ||
                target.output.size() > 256 || target.notes.size() > 65535) return -1;
            auto valid = [](int index, size_t size) { return index >= -2 && (index < 0 || static_cast<size_t>(index) < size); };
            if (!valid(source.transcription, transcriptionCount) || !valid(source.polish_model, polishCount) ||
                !valid(source.language, languageCount) || source.polish_mode < 0 || source.polish_mode > 2) return -1;
            target.id = source.id; target.transcription = source.transcription; target.polishMode = source.polish_mode;
            target.polishModel = source.polish_model; target.language = source.language;
        }
        updated.callback = callback; updated.context = context;
        std::lock_guard<std::mutex> lock(configurationMutex); configuration = std::move(updated);
        return 0;
    } catch (const std::exception &) { return -1; }
}

bool jsti_profiles_self_test(HWND owner, std::string &error) {
    struct Outcome { int calls = 0; bool correct = false; } outcome;
    Dialog dialog;
    dialog.config.transcription = {L"Batch: First", L"Live: Second"};
    dialog.config.polish = {L"Polish model"}; dialog.config.languages = {L"English", L"French"};
    Draft original; original.id = "original"; original.name = L"Original"; original.paths = L"C:\\Apps\\App.exe";
    original.transcription = -2; original.prompt = L"Keep caf\u00e9.";
    dialog.config.drafts = {original}; dialog.selected = 0;
    dialog.config.context = &outcome;
    dialog.config.callback = [](int action, const JSTIProfileDraft *values, size_t count,
                                void *context, char *message, size_t capacity) {
        auto &out = *static_cast<Outcome *>(context);
        if (action != 1) return 0;
        ++out.calls;
        if (out.calls == 1) return jsti::fail("Synthetic validation failure", message, capacity);
        out.correct = count == 2 && std::string(values[0].name) == "New profile" &&
            values[0].transcription == 1 && values[0].polish_mode == 2 && values[0].language == 1 &&
            std::string(values[1].id) == "original" && values[1].transcription == -2 &&
            std::string(values[1].prompt) == "Keep caf\xc3\xa9.";
        return 0;
    };
    HWND window = create(owner, dialog);
    if (!window) { error = "Profiles editor could not be created."; return false; }
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(addID, BN_CLICKED), 0);
    SendDlgItemMessageW(window, transcriptionID, CB_SETCURSEL, 2, 0);
    SendDlgItemMessageW(window, polishModeID, CB_SETCURSEL, 2, 0);
    SendDlgItemMessageW(window, languageID, CB_SETCURSEL, 2, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(upID, BN_CLICKED), 0);
    SetWindowPos(window, nullptr, 0, 0, scale(window, 820), scale(window, 440), SWP_NOMOVE | SWP_NOZORDER);
    SendMessageW(window, WM_VSCROLL, SB_BOTTOM, 0);
    RECT button{}, bounds{}; GetWindowRect(GetDlgItem(window, IDOK), &button);
    MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&button), 2); GetClientRect(window, &bounds);
    const bool reachable = button.top >= 0 && button.bottom <= bounds.bottom;
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    const bool rejected = IsWindow(window) && !dialog.accepted && text(window, notesID) == L"Synthetic validation failure";
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
    if (IsWindow(window)) DestroyWindow(window);
    if (!reachable || !rejected || !dialog.accepted || !outcome.correct || outcome.calls != 2) {
        error = "Profiles editor failed ordering, preserved values, validation or short-window scrolling."; return false;
    }
    Dialog cancelled; cancelled.config = dialog.config; cancelled.selected = 0;
    window = create(owner, cancelled);
    if (!window) { error = "Profiles cancellation fixture could not be created."; return false; }
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(removeID, BN_CLICKED), 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
    if (IsWindow(window)) DestroyWindow(window);
    if (cancelled.accepted || outcome.calls != 2 || dialog.config.drafts.size() != 2) {
        error = "Cancelling the profiles editor changed the saved snapshot."; return false;
    }
    return true;
}
