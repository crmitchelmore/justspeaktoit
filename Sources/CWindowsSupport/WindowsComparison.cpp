#include "include/CWindowsSupport.h"
#include "WindowsWindowChrome.hpp"
#include <commdlg.h>
#include <mutex>
#include <sstream>
#include <vector>

int jsti_owned_window_save_snapshot(HWND window, const char *path, char *error, size_t capacity);
void jsti_show_comparison(HWND owner, JSTIWindowCallback callback, void *context);

namespace {
enum Control { modelsID = 700, modeID, languageID, runID, stopID, cancelID, roundsID, detailID,
               ranksID, judgeID, jsonID, markdownID, noticeID, modelLabelID, languageLabelID,
               roundLabelID, ranksLabelID, playID, stopAudioID };
constexpr UINT presentMessage = WM_APP + 70;
constexpr int deleteID = 740;
constexpr int syncID = 741, syncNowID = 742;
struct Row { std::string id; std::wstring name; bool live = false; };
struct Presentation {
    std::string models, rounds, detail, selected;
    bool busy = false, recording = false, judgeable = false;
    bool syncEnabled = false, syncAvailable = false;
};
std::mutex mutex;
Presentation pending;
HWND activeWindow = nullptr;
struct Dialog {
    JSTIWindowCallback callback;
    void *context;
    std::vector<Row> models, rounds, visible;
    std::vector<HWND> controls;
    Presentation shown;
    bool suppress = false;
    int scroll = 0;
    int scrollX = 0;
};
std::vector<Row> rows(const std::string &value) {
    std::vector<Row> result;
    std::istringstream input(value);
    std::string line;
    while (std::getline(input, line)) {
        const auto tab = line.find('\t');
        if (tab == std::string::npos) continue;
        const auto last = line.find('\t', tab + 1);
        Row row; row.id = line.substr(0, tab);
        jsti::wide(line.substr(tab + 1, last == std::string::npos ? last : last - tab - 1).c_str(), row.name);
        row.live = last != std::string::npos && line.substr(last + 1) == "1";
        result.push_back(std::move(row));
    }
    return result;
}
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
std::string text(HWND window, int id) {
    HWND control = GetDlgItem(window, id);
    std::wstring value(static_cast<size_t>(GetWindowTextLengthW(control)) + 1, 0);
    value.resize(static_cast<size_t>(GetWindowTextW(control, value.data(), static_cast<int>(value.size()))));
    return jsti::utf8(value);
}
void emit(Dialog &dialog, int action, const std::string &value = {}, int index = 0) {
    if (dialog.callback) dialog.callback(action, value.c_str(), index, dialog.context);
}
void confirmDeletion(Dialog &dialog, const std::string &selected) {
    if (!dialog.shown.busy && !selected.empty() && dialog.shown.selected == selected)
        emit(dialog, 120, selected);
}
void populateModels(HWND window, Dialog &dialog) {
    SendDlgItemMessageW(window, modelsID, LB_RESETCONTENT, 0, 0);
    dialog.visible.clear();
    const bool live = SendDlgItemMessageW(window, modeID, CB_GETCURSEL, 0, 0) == 1;
    for (const auto &row : dialog.models) if (row.live == live) {
        dialog.visible.push_back(row);
        SendDlgItemMessageW(window, modelsID, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(row.name.c_str()));
    }
    SetDlgItemTextW(window, runID, live ? L"&Start microphone" : L"&Choose samples and run...");
}
void present(HWND window, Dialog &dialog) {
    Presentation next;
    { std::lock_guard<std::mutex> lock(mutex); next = pending; }
    dialog.suppress = true;
    if (dialog.shown.models != next.models) {
        dialog.models = rows(next.models);
        populateModels(window, dialog);
    }
    if (dialog.shown.rounds != next.rounds) {
        dialog.rounds = rows(next.rounds);
        SendDlgItemMessageW(window, roundsID, LB_RESETCONTENT, 0, 0);
        for (const auto &row : dialog.rounds)
            SendDlgItemMessageW(window, roundsID, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(row.name.c_str()));
    }
    for (size_t i = 0; i < dialog.rounds.size(); ++i) if (dialog.rounds[i].id == next.selected)
        SendDlgItemMessageW(window, roundsID, LB_SETCURSEL, i, 0);
    std::wstring detail; jsti::wide(next.detail.c_str(), detail);
    size_t newline = 0;
    while ((newline = detail.find(L'\n', newline)) != std::wstring::npos) {
        if (newline == 0 || detail[newline - 1] != L'\r') detail.insert(newline++, 1, L'\r');
        ++newline;
    }
    if (dialog.shown.detail != next.detail) {
        const LRESULT firstLine = SendDlgItemMessageW(window, detailID, EM_GETFIRSTVISIBLELINE, 0, 0);
        SetDlgItemTextW(window, detailID, detail.c_str());
        SendDlgItemMessageW(window, detailID, EM_LINESCROLL, 0, firstLine);
    }
    if (dialog.shown.selected != next.selected) SetDlgItemTextW(window, ranksID, L"");
    for (int id : {modelsID, modeID, languageID, runID}) EnableWindow(GetDlgItem(window, id), !next.busy);
    EnableWindow(GetDlgItem(window, stopID), next.recording);
    EnableWindow(GetDlgItem(window, cancelID), next.busy);
    EnableWindow(GetDlgItem(window, judgeID), next.judgeable);
    EnableWindow(GetDlgItem(window, ranksID), next.judgeable);
    EnableWindow(GetDlgItem(window, playID), !next.busy && !dialog.rounds.empty());
    EnableWindow(GetDlgItem(window, jsonID), !next.busy && !dialog.rounds.empty());
    EnableWindow(GetDlgItem(window, markdownID), !next.busy && !dialog.rounds.empty());
    EnableWindow(GetDlgItem(window, deleteID), !next.busy && !next.selected.empty());
    SendDlgItemMessageW(window, syncID, BM_SETCHECK, next.syncEnabled ? BST_CHECKED : BST_UNCHECKED, 0);
    EnableWindow(GetDlgItem(window, syncID), next.syncAvailable);
    EnableWindow(GetDlgItem(window, syncNowID), next.syncAvailable && next.syncEnabled);
    dialog.shown = std::move(next);
    dialog.suppress = false;
}
void layout(HWND window, Dialog &dialog) {
    RECT client{}; GetClientRect(window, &client);
    const int height = std::max(static_cast<int>(client.bottom), scale(window, 690));
    const int width = std::max(static_cast<int>(client.right), scale(window, 640));
    dialog.scroll = std::clamp(dialog.scroll, 0, height - static_cast<int>(client.bottom));
    SCROLLINFO info{}; info.cbSize = sizeof(info); info.fMask = SIF_RANGE | SIF_PAGE | SIF_POS;
    info.nMax = height - 1; info.nPage = client.bottom; info.nPos = dialog.scroll;
    SetScrollInfo(window, SB_VERT, &info, TRUE);
    dialog.scrollX = std::clamp(dialog.scrollX, 0, width - static_cast<int>(client.right));
    info.nMax = width - 1; info.nPage = client.right; info.nPos = dialog.scrollX;
    SetScrollInfo(window, SB_HORZ, &info, TRUE);
    auto move = [&](int id, int x, int y, int w, int h) {
        MoveWindow(GetDlgItem(window, id), scale(window, x) - dialog.scrollX, scale(window, y) - dialog.scroll,
                   id == detailID ? width - scale(window, x + 16) : scale(window, w), scale(window, h), TRUE);
    };
    move(noticeID, 16, 12, 610, 36);
    move(modeID, 16, 55, 240, 160);
    move(languageLabelID, 270, 55, 130, 24); move(languageID, 400, 55, 210, 28);
    move(modelLabelID, 16, 92, 240, 22); move(modelsID, 16, 117, 240, 170);
    move(runID, 16, 298, 240, 32); move(stopID, 16, 339, 112, 32); move(cancelID, 138, 339, 118, 32);
    move(roundLabelID, 16, 385, 240, 22); move(roundsID, 16, 410, 240, 112);
    move(playID, 16, 537, 112, 32); move(stopAudioID, 138, 537, 118, 32);
    move(detailID, 270, 92, 340, 390);
    move(ranksLabelID, 270, 490, 340, 24); move(ranksID, 270, 516, 140, 30);
    move(judgeID, 420, 516, 190, 30);
    move(jsonID, 270, 557, 140, 30); move(markdownID, 420, 557, 190, 30);
    move(deleteID, 16, 585, 240, 32);
    move(syncID, 16, 633, 420, 32); move(syncNowID, 450, 633, 160, 32);
    const HFONT font = jsti::chrome::font(jsti::chrome::Font::body, GetDpiForWindow(window));
    for (HWND control : dialog.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
}
void run(HWND window, Dialog &dialog) {
    std::string payload = text(window, languageID);
    if (payload.find_first_of("\r\n\t") != std::string::npos) {
        MessageBoxW(window, L"Use a single language identifier, or leave it blank for Automatic.",
                    L"Comparison language", MB_OK | MB_ICONWARNING); return;
    }
    payload += "\n";
    int count = 0;
    for (size_t i = 0; i < dialog.visible.size(); ++i)
        if (SendDlgItemMessageW(window, modelsID, LB_GETSEL, i, 0) > 0) {
            if (count++) payload += "\t";
            payload += dialog.visible[i].id;
        }
    if (count < 2 || count > 8) {
        MessageBoxW(window, L"Select two to eight models (Ctrl+click or Shift+click).",
                    L"Comparison models", MB_OK | MB_ICONWARNING); return;
    }
    const bool live = SendDlgItemMessageW(window, modeID, CB_GETCURSEL, 0, 0) == 1;
    if (!live) {
        std::vector<wchar_t> files(131072, 0);
        OPENFILENAMEW picker{}; picker.lStructSize = sizeof(picker); picker.hwndOwner = window;
        picker.lpstrFile = files.data(); picker.nMaxFile = static_cast<DWORD>(files.size());
        picker.lpstrTitle = L"Choose one sample, or multiple samples for Batch";
        picker.lpstrFilter = L"Audio\0*.wav;*.mp3;*.m4a;*.aac;*.mp4;*.flac;*.ogg;*.opus;*.webm\0";
        picker.Flags = OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR;
        if (!GetOpenFileNameW(&picker)) {
            if (CommDlgExtendedError()) MessageBoxW(window, L"Could not open the audio picker.", L"Comparison", MB_OK);
            return;
        }
        const std::wstring first(files.data());
        const wchar_t *next = files.data() + first.size() + 1;
        if (!*next) payload += "\n" + jsti::utf8(first);
        else while (*next) {
            const std::wstring name(next);
            payload += "\n" + jsti::utf8(first + L"\\" + name);
            next += name.size() + 1;
        }
    }
    emit(dialog, live ? 103 : 102, payload);
}
void exportFile(HWND window, Dialog &dialog, bool markdown) {
    std::vector<wchar_t> path(32768, 0);
    const wchar_t *name = markdown ? L"Comparisons.md" : L"Comparisons.json";
    wcscpy_s(path.data(), path.size(), name);
    OPENFILENAMEW picker{}; picker.lStructSize = sizeof(picker); picker.hwndOwner = window;
    picker.lpstrFile = path.data(); picker.nMaxFile = static_cast<DWORD>(path.size());
    picker.lpstrTitle = L"Export includes transcripts and model identities, not audio";
    picker.lpstrDefExt = markdown ? L"md" : L"json";
    picker.lpstrFilter = markdown ? L"Markdown\0*.md\0" : L"JSON\0*.json\0";
    picker.Flags = OFN_EXPLORER | OFN_OVERWRITEPROMPT | OFN_NOCHANGEDIR;
    if (GetSaveFileNameW(&picker)) emit(dialog, 107, jsti::utf8(path.data()), markdown ? 1 : 0);
    else if (CommDlgExtendedError()) MessageBoxW(window, L"Could not open the save picker.", L"Comparison", MB_OK);
}
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto *dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = reinterpret_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: {
        auto add = [&](int id, const wchar_t *kind, const wchar_t *title, DWORD style) {
            HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, kind, title,
                WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
            if (control) dialog->controls.push_back(control);
            return control != nullptr;
        };
        bool okay = add(noticeID, L"STATIC", L"Compare Models: one sample, raw results, blind judging.\n"
                        L"Choose Batch/File or Live. No dictation settings or History are changed.", 0)
            && add(modeID, L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP)
            && add(modelLabelID, L"STATIC", L"Models (select 2-8)", 0)
            && add(modelsID, L"LISTBOX", L"Comparison models", LBS_EXTENDEDSEL | LBS_NOTIFY | WS_VSCROLL | WS_TABSTOP)
            && add(languageLabelID, L"STATIC", L"Language hint", 0)
            && add(languageID, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP)
            && add(runID, L"BUTTON", L"&Choose samples and run...", BS_PUSHBUTTON | WS_TABSTOP)
            && add(stopID, L"BUTTON", L"&Stop", BS_PUSHBUTTON | WS_TABSTOP)
            && add(cancelID, L"BUTTON", L"&Cancel run", BS_PUSHBUTTON | WS_TABSTOP)
            && add(roundLabelID, L"STATIC", L"Saved rounds", 0)
            && add(roundsID, L"LISTBOX", L"Saved comparison rounds", LBS_NOTIFY | WS_VSCROLL | WS_TABSTOP)
            && add(playID, L"BUTTON", L"&Play sample", BS_PUSHBUTTON | WS_TABSTOP)
            && add(stopAudioID, L"BUTTON", L"Stop &audio", BS_PUSHBUTTON | WS_TABSTOP)
            && add(detailID, L"EDIT", L"", ES_MULTILINE | ES_READONLY | WS_VSCROLL | WS_TABSTOP)
            && add(ranksLabelID, L"STATIC", L"Ranks for A, B, ... (e.g. 2,1,3; rank failures too)", 0)
            && add(ranksID, L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP)
            && add(judgeID, L"BUTTON", L"&Save ranking and reveal", BS_PUSHBUTTON | WS_TABSTOP)
            && add(jsonID, L"BUTTON", L"Export &JSON", BS_PUSHBUTTON | WS_TABSTOP)
            && add(markdownID, L"BUTTON", L"Export &Markdown", BS_PUSHBUTTON | WS_TABSTOP)
            && add(deleteID, L"BUTTON", L"&Delete / discard saved round...", BS_PUSHBUTTON | WS_TABSTOP)
            && add(syncID, L"BUTTON", L"Sync comparison transcripts and rankings with &iCloud",
                   BS_AUTOCHECKBOX | BS_MULTILINE | WS_TABSTOP)
            && add(syncNowID, L"BUTTON", L"S&ync now / retry", BS_PUSHBUTTON | WS_TABSTOP);
        if (!okay) return -1;
        SendDlgItemMessageW(window, detailID, EM_SETLIMITTEXT, 0x7ffffffe, 0);
        SendDlgItemMessageW(window, modeID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"File / multi-sample Batch"));
        SendDlgItemMessageW(window, modeID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Live microphone"));
        SendDlgItemMessageW(window, modeID, CB_SETCURSEL, 0, 0);
        layout(window, *dialog); present(window, *dialog); return 0;
    }
    case presentMessage: present(window, *dialog); return 0;
    case WM_SIZE: layout(window, *dialog); return 0;
    case WM_DPICHANGED: {
        const RECT *rect = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top,
                     SWP_NOZORDER | SWP_NOACTIVATE); layout(window, *dialog); return 0;
    }
    case WM_MOUSEWHEEL: dialog->scroll -= GET_WHEEL_DELTA_WPARAM(wparam) * scale(window, 48) / WHEEL_DELTA;
        layout(window, *dialog); return 0;
    case WM_VSCROLL: {
        SCROLLINFO info{}; info.cbSize = sizeof(info); info.fMask = SIF_ALL; GetScrollInfo(window, SB_VERT, &info);
        switch (LOWORD(wparam)) {
        case SB_LINEUP: dialog->scroll -= scale(window, 32); break;
        case SB_LINEDOWN: dialog->scroll += scale(window, 32); break;
        case SB_PAGEUP: dialog->scroll -= info.nPage; break;
        case SB_PAGEDOWN: dialog->scroll += info.nPage; break;
        case SB_THUMBTRACK: dialog->scroll = info.nTrackPos; break;
        default: break;
        }
        layout(window, *dialog); return 0;
    }
    case WM_HSCROLL: {
        SCROLLINFO info{}; info.cbSize = sizeof(info); info.fMask = SIF_ALL; GetScrollInfo(window, SB_HORZ, &info);
        switch (LOWORD(wparam)) {
        case SB_LINELEFT: dialog->scrollX -= scale(window, 32); break;
        case SB_LINERIGHT: dialog->scrollX += scale(window, 32); break;
        case SB_PAGELEFT: dialog->scrollX -= info.nPage; break;
        case SB_PAGERIGHT: dialog->scrollX += info.nPage; break;
        case SB_THUMBTRACK: dialog->scrollX = info.nTrackPos; break;
        default: break;
        }
        layout(window, *dialog); return 0;
    }
    case WM_COMMAND:
        if (dialog->suppress) return 0;
        if (LOWORD(wparam) == modeID && HIWORD(wparam) == CBN_SELCHANGE) populateModels(window, *dialog);
        if (LOWORD(wparam) == roundsID && HIWORD(wparam) == LBN_SELCHANGE) {
            const LRESULT row = SendDlgItemMessageW(window, roundsID, LB_GETCURSEL, 0, 0);
            if (row >= 0 && static_cast<size_t>(row) < dialog->rounds.size()) emit(*dialog, 101, dialog->rounds[row].id);
        }
        if (HIWORD(wparam) == BN_CLICKED) switch (LOWORD(wparam)) {
        case IDCANCEL: SendMessageW(window, WM_CLOSE, 0, 0); break;
        case runID: run(window, *dialog); break;
        case stopID: emit(*dialog, 104); break;
        case cancelID: emit(*dialog, 105); break;
        case judgeID: emit(*dialog, 106, dialog->shown.selected + "\n" + text(window, ranksID)); break;
        case jsonID: exportFile(window, *dialog, false); break;
        case markdownID: exportFile(window, *dialog, true); break;
        case playID: emit(*dialog, 108, dialog->shown.selected); break;
        case stopAudioID: emit(*dialog, 109); break;
        case syncID: emit(*dialog, 121, {}, SendDlgItemMessageW(window, syncID, BM_GETCHECK, 0, 0) == BST_CHECKED); break;
        case syncNowID: emit(*dialog, 122); break;
        case deleteID: {
            const auto selected = dialog->shown.selected;
            if (!selected.empty() && MessageBoxW(window,
                L"Delete this saved comparison and its app-owned audio? Original imports are not changed.\n\n"
                L"A previously synced comparison is also deleted on its other devices when sync is enabled "
                L"for its original iCloud account.",
                L"Delete comparison?", MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING) == IDYES
                ) confirmDeletion(*dialog, selected);
            break;
        }
        default: break;
        }
        return 0;
    case WM_CTLCOLORSTATIC: case WM_CTLCOLOREDIT: case WM_CTLCOLORLISTBOX: {
        HDC dc = reinterpret_cast<HDC>(wparam); const auto &palette = jsti::chrome::palette();
        SetTextColor(dc, palette.text); SetBkColor(dc, palette.field);
        static HBRUSH brush = nullptr;
        if (brush) DeleteObject(brush);
        brush = CreateSolidBrush(palette.field);
        return reinterpret_cast<LRESULT>(brush);
    }
    case WM_ERASEBKGND: {
        RECT client{}; GetClientRect(window, &client);
        HBRUSH brush = CreateSolidBrush(jsti::chrome::palette().window);
        FillRect(reinterpret_cast<HDC>(wparam), &client, brush); DeleteObject(brush); return 1;
    }
    case WM_CLOSE: emit(*dialog, 123); DestroyWindow(window); return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

extern "C" int jsti_comparison_present(const char *models, const char *rounds, const char *detail,
                                      const char *selected, int busy, int recording, int judgeable,
                                      int sync_enabled, int sync_available) {
    if (!models || !rounds || !detail || !selected) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    pending = {models, rounds, detail, selected, busy != 0, recording != 0, judgeable != 0,
               sync_enabled != 0, sync_available != 0};
    return activeWindow && PostMessageW(activeWindow, presentMessage, 0, 0) ? 0 : -1;
}

void jsti_show_comparison(HWND owner, JSTIWindowCallback callback, void *context) {
    Dialog dialog{callback, context, {}, {}, {}, {}, {}, false, 0, 0};
    WNDCLASSW type{}; type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItComparison"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return;
    RECT work{}; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    const int width = std::min(scale(owner, 900), static_cast<int>(work.right - work.left));
    const int height = std::min(scale(owner, 760), static_cast<int>(work.bottom - work.top));
    HWND window = CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName, L"Compare Models",
        WS_OVERLAPPEDWINDOW | WS_VSCROLL | WS_HSCROLL, work.left + (work.right - work.left - width) / 2,
        work.top + (work.bottom - work.top - height) / 2, width, height, owner, nullptr, type.hInstance, &dialog);
    if (!window) { MessageBoxW(owner, L"Could not create Compare Models.", L"Comparison", MB_OK); return; }
    { std::lock_guard<std::mutex> lock(mutex); activeWindow = window; }
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW);
    emit(dialog, 100);
    MSG message{};
    HWND previousFocus = nullptr;
    while (IsWindow(window) && GetMessageW(&message, nullptr, 0, 0) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
        const HWND focus = GetFocus();
        if (focus != previousFocus && IsChild(window, focus)) {
            previousFocus = focus;
            RECT rect{}, client{}; GetWindowRect(focus, &rect); GetClientRect(window, &client);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&rect), 2);
            const int oldY = dialog.scroll, oldX = dialog.scrollX;
            if (rect.top < 0) dialog.scroll += rect.top;
            else if (rect.bottom > client.bottom) dialog.scroll += rect.bottom - client.bottom;
            if (rect.left < 0) dialog.scrollX += rect.left;
            else if (rect.right > client.right) dialog.scrollX += rect.right - client.right;
            if (oldY != dialog.scroll || oldX != dialog.scrollX) layout(window, dialog);
        }
    }
    if (IsWindow(window)) SendMessageW(window, WM_CLOSE, 0, 0);
    if (message.message == WM_QUIT) PostQuitMessage(static_cast<int>(message.wParam));
    { std::lock_guard<std::mutex> lock(mutex); activeWindow = nullptr; }
    EnableWindow(owner, TRUE); SetActiveWindow(owner);
}

bool jsti_comparison_self_test(HWND owner, std::string &error, const std::string &directory) {
    struct Check { std::string directory, payload, failure; int event = 0, index = 0; };
    Check check{directory, {}, {}, 0, 0};
    const int appearance = jsti::chrome::appearance();
    Presentation original;
    { std::lock_guard<std::mutex> lock(mutex); original = pending;
      pending = {"test/file-a\tFile A\t0\ntest/file-b\tFile B\t0\ntest/live-a\tLive A\t1\ntest/live-b\tLive B\t1",
                 "synthetic-round\tSynthetic sample.wav",
                 "Synthetic sample.wav\n\nResult A\nCould we meet Friday?\n\nResult B\nCould we meet on Friday?\n"
                 "\nRank every blind result to reveal models.", "synthetic-round", false, false, true, false, true}; }
    auto callback = [](int action, const char *payload, int index, void *context) {
        auto &check = *static_cast<Check *>(context);
        if (action != 100) { check.event = action; check.payload = payload; check.index = index; return; }
        HWND window = activeWindow;
        auto *dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
        auto require = [&](bool value, const char *message) { if (!value && check.failure.empty()) check.failure = message; };
        require(SendDlgItemMessageW(window, modelsID, LB_GETCOUNT, 0, 0) == 2, "Comparison file routes are missing.");
        require(IsWindowEnabled(GetDlgItem(window, judgeID)), "Unjudged comparison cannot be ranked.");
        require(IsWindowEnabled(GetDlgItem(window, deleteID)), "Saved comparison cannot be discarded.");
        require(IsWindowEnabled(GetDlgItem(window, syncID)), "Comparison sync consent is unavailable.");
        require(!IsWindowEnabled(GetDlgItem(window, syncNowID)), "Sync retry is enabled before consent.");
        SendDlgItemMessageW(window, syncID, BM_SETCHECK, BST_CHECKED, 0);
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(syncID, BN_CLICKED), 0);
        require(check.event == 121 && check.index == 1, "Comparison sync consent was not explicitly admitted.");
        { std::lock_guard<std::mutex> lock(mutex); pending.syncEnabled = true; }
        present(window, *dialog);
        require(IsWindowEnabled(GetDlgItem(window, syncNowID)), "Comparison sync retry remains disabled.");
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(syncNowID, BN_CLICKED), 0);
        require(check.event == 122, "Comparison sync retry lost its action.");
        confirmDeletion(*dialog, "a-stale-round");
        require(check.event != 120, "A stale delete confirmation was admitted.");
        confirmDeletion(*dialog, dialog->shown.selected);
        require(check.event == 120 && check.payload == "synthetic-round", "Confirmed deletion lost its round identity.");
        require(text(window, detailID).find("test/") == std::string::npos, "Blind result reveals model identities.");
        auto snapshot = [&](const char *name) {
            if (check.directory.empty()) return;
            char failure[512]{};
            const auto path = check.directory + "\\" + name;
            if (jsti_owned_window_save_snapshot(window, path.c_str(), failure, sizeof failure) != 0)
                require(false, failure);
        };
        jsti::chrome::setAppearance(1); snapshot("comparison-blind-light.bmp");
        SendDlgItemMessageW(window, modeID, CB_SETCURSEL, 1, 0); populateModels(window, *dialog);
        SendDlgItemMessageW(window, modelsID, LB_SETSEL, TRUE, 0);
        SendDlgItemMessageW(window, modelsID, LB_SETSEL, TRUE, 1);
        SetDlgItemTextW(window, languageID, L"en_GB");
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(runID, BN_CLICKED), 0);
        require(check.event == 103 && check.payload == "en_GB\ntest/live-a\ttest/live-b",
                "Comparison live selection did not produce a frozen payload.");
        SetDlgItemTextW(window, ranksID, L"2,1");
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(judgeID, BN_CLICKED), 0);
        require(check.event == 106 && check.payload == "synthetic-round\n2,1", "Comparison ranking payload changed.");
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(playID, BN_CLICKED), 0);
        require(check.event == 108 && check.payload == "synthetic-round", "Comparison sample playback lost its round.");
        { std::lock_guard<std::mutex> lock(mutex);
          pending.detail = "Synthetic judged comparison\n\nResult A - File A (rank 2)\nCould we meet Friday?\n"
                           "\nResult B - File B (rank 1)\nCould we meet on Friday?\n\nScoreboard\nFile B: 1 win\nFile A: 0 wins";
          pending.judgeable = false; }
        present(window, *dialog);
        require(!IsWindowEnabled(GetDlgItem(window, judgeID)), "A judged comparison can be judged again.");
        jsti::chrome::setAppearance(2); snapshot("comparison-revealed-dark.bmp");
        { std::lock_guard<std::mutex> lock(mutex); pending.busy = true; pending.recording = true; }
        present(window, *dialog);
        require(!IsWindowEnabled(GetDlgItem(window, runID)) && IsWindowEnabled(GetDlgItem(window, stopID)),
                "Comparison run/stop controls do not follow capture state.");
        SetWindowPos(window, nullptr, 0, 0, 580, 400, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        require(GetScrollPos(window, SB_VERT) == 0, "Comparison short-area scroll did not reset.");
        PostMessageW(window, WM_CLOSE, 0, 0);
    };
    jsti_show_comparison(owner, callback, &check);
    jsti::chrome::setAppearance(appearance);
    { std::lock_guard<std::mutex> lock(mutex); pending = std::move(original); }
    error = check.failure;
    return check.event == 123 && error.empty();
}
