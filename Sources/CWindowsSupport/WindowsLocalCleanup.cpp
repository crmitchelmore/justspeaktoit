#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <vector>

namespace {
enum { listID = 1800, statusID, detailID, repoID, fileID, importID, downloadID, cancelID, removeID,
    introID, repoLabelID, fileLabelID };
constexpr UINT refreshMessage = WM_APP + 78;
struct Row { std::string id; std::wstring name, detail; int state; };
struct Configuration {
    std::vector<Row> rows;
    std::wstring status;
    JSTILocalCleanupCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex mutex;
Configuration current;
HWND active = nullptr;
struct Dialog { Configuration config; HFONT font = nullptr; int selected = 0; };
Configuration snapshot() { std::lock_guard<std::mutex> lock(mutex); return current; }
int px(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT rect{}; GetClientRect(window, &rect);
    const int margin = px(window, 20), gap = px(window, 10), row = px(window, 32);
    const int width = rect.right - margin * 2, height = rect.bottom;
    auto move = [&](int id, int y, int h) { MoveWindow(GetDlgItem(window, id), margin, y, width, h, TRUE); };
    move(introID, margin, px(window, 46));
    move(repoLabelID, px(window, 72), px(window, 22)); move(repoID, px(window, 96), row);
    move(fileLabelID, px(window, 136), px(window, 22)); move(fileID, px(window, 160), row);
    move(importID, px(window, 200), row);
    move(listID, px(window, 244), std::max(px(window, 90), height - px(window, 498)));
    move(detailID, height - px(window, 244), px(window, 60));
    const int button = (width - gap * 2) / 3;
    for (int i = 0; i < 3; ++i) {
        MoveWindow(GetDlgItem(window, downloadID + i), margin + i * (button + gap),
            height - px(window, 174), button, row, TRUE);
    }
    move(statusID, height - px(window, 130), px(window, 74));
    MoveWindow(GetDlgItem(window, IDCANCEL), rect.right - margin - px(window, 100),
        height - margin - row, px(window, 100), row, TRUE);
}

void selected(HWND window, Dialog &dialog) {
    const bool valid = dialog.selected >= 0 && static_cast<size_t>(dialog.selected) < dialog.config.rows.size();
    const auto *row = valid ? &dialog.config.rows[static_cast<size_t>(dialog.selected)] : nullptr;
    SetDlgItemTextW(window, detailID, row ? row->detail.c_str() : L"Select a recommended or imported GGUF model.");
    EnableWindow(GetDlgItem(window, downloadID), row && (row->state == 0 || row->state == 1));
    SetDlgItemTextW(window, downloadID, row && row->state == 1 ? L"&Resume download" : L"&Download");
    EnableWindow(GetDlgItem(window, removeID), row && (row->state == 1 || row->state == 3));
}

void refresh(HWND window, Dialog &dialog) {
    const std::string selectedID = dialog.selected >= 0
        && static_cast<size_t>(dialog.selected) < dialog.config.rows.size()
        ? dialog.config.rows[static_cast<size_t>(dialog.selected)].id : "";
    dialog.config = snapshot();
    SendDlgItemMessageW(window, listID, LB_RESETCONTENT, 0, 0);
    for (size_t index = 0; index < dialog.config.rows.size(); ++index) {
        const auto &row = dialog.config.rows[index];
        if (row.id == selectedID) dialog.selected = static_cast<int>(index);
        if (SendDlgItemMessageW(window, listID, LB_ADDSTRING, 0,
            reinterpret_cast<LPARAM>(row.name.c_str())) < 0) {
            SetDlgItemTextW(window, statusID, L"The GGUF model list could not be displayed."); return;
        }
    }
    if (dialog.config.rows.empty()) dialog.selected = -1;
    else dialog.selected = std::min(std::max(0, dialog.selected), static_cast<int>(dialog.config.rows.size()) - 1);
    SendDlgItemMessageW(window, listID, LB_SETCURSEL, dialog.selected, 0);
    SetDlgItemTextW(window, statusID, dialog.config.status.c_str());
    selected(window, dialog);
}

bool controls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *type, const wchar_t *label, int id, DWORD style) {
        return CreateWindowExW(wcscmp(type, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, type, label,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
    };
    const bool okay = add(L"STATIC", L"Downloaded local LLMs polish text on this PC. Import pins public metadata; "
        L"Download verifies weights. No Python, cloud fallback or background model execution.", introID, SS_LEFT)
        && add(L"STATIC", L"Hugging Face &owner/repository", repoLabelID, SS_LEFT)
        && add(L"EDIT", L"", repoID, ES_AUTOHSCROLL | WS_TABSTOP)
        && add(L"STATIC", L"Unsplit GGUF &filename", fileLabelID, SS_LEFT)
        && add(L"EDIT", L"", fileID, ES_AUTOHSCROLL | WS_TABSTOP)
        && add(L"BUTTON", L"&Import immutable GGUF reference", importID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"LISTBOX", L"", listID, LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP | WS_BORDER)
        && add(L"STATIC", L"", detailID, SS_LEFT)
        && add(L"BUTTON", L"&Download", downloadID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"BUTTON", L"&Cancel operation", cancelID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"BUTTON", L"&Remove weights", removeID, BS_PUSHBUTTON | WS_TABSTOP)
        && add(L"STATIC", L"", statusID, SS_LEFT)
        && add(L"BUTTON", L"Close", IDCANCEL, BS_DEFPUSHBUTTON | WS_TABSTOP);
    if (!okay) return false;
    SendDlgItemMessageW(window, repoID, EM_SETLIMITTEXT, 193, 0);
    SendDlgItemMessageW(window, fileID, EM_SETLIMITTEXT, 128, 0);
    dialog.font = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE,
        FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (dialog.font) EnumChildWindows(window, [](HWND child, LPARAM font) -> BOOL {
        SendMessageW(child, WM_SETFONT, static_cast<WPARAM>(font), TRUE); return TRUE;
    }, reinterpret_cast<LPARAM>(dialog.font));
    refresh(window, dialog); layout(window); return true;
}

void act(HWND window, Dialog &dialog, int action) {
    if (!dialog.config.callback) return;
    if (action == 3) { dialog.config.callback(3, "", "", "", dialog.config.context); return; }
    if (action == 4) {
        wchar_t repo[194]{}, file[129]{};
        GetDlgItemTextW(window, repoID, repo, 194); GetDlgItemTextW(window, fileID, file, 129);
        const std::string repository = jsti::utf8(repo), filename = jsti::utf8(file);
        dialog.config.callback(4, "", repository.c_str(), filename.c_str(), dialog.config.context); return;
    }
    if (dialog.selected < 0 || static_cast<size_t>(dialog.selected) >= dialog.config.rows.size()) return;
    const Row row = dialog.config.rows[static_cast<size_t>(dialog.selected)];
    if (action == 2 && MessageBoxW(window,
        (L"Remove downloaded weights for " + row.name + L"? The reference, selection and History are retained.").c_str(),
        L"Remove local cleanup model", MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING) != IDYES) return;
    dialog.config.callback(action, row.id.c_str(), "", "", dialog.config.context);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto *dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: return controls(window, *dialog) ? 0 : -1;
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const auto *rect = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top,
            SWP_NOACTIVATE | SWP_NOZORDER); layout(window); return 0;
    }
    case WM_GETMINMAXINFO:
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {px(window, 640), px(window, 700)}; return 0;
    case refreshMessage: refresh(window, *dialog); return 0;
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case IDCANCEL: DestroyWindow(window); return 0;
        case importID: act(window, *dialog, 4); return 0;
        case downloadID: act(window, *dialog, 1); return 0;
        case cancelID: act(window, *dialog, 3); return 0;
        case removeID: act(window, *dialog, 2); return 0;
        case listID:
            if (HIWORD(wparam) == LBN_SELCHANGE) {
                dialog->selected = static_cast<int>(SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0));
                selected(window, *dialog);
            }
            return 0;
        }
        break;
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        { std::lock_guard<std::mutex> lock(mutex); if (active == window) active = nullptr; }
        if (dialog->font) { DeleteObject(dialog->font); dialog->font = nullptr; } return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

int32_t jsti_window_set_local_cleanup(
    const JSTILocalCleanupRow *rows, size_t count, const char *status, JSTILocalCleanupCallback callback, void *context) {
    if ((!rows && count) || count > 128 || !status || !callback) return -1;
    try {
        Configuration changed; changed.callback = callback; changed.context = context;
        if (!jsti::wide(status, changed.status)) return -1;
        for (size_t i = 0; i < count; ++i) {
            Row row; row.id = rows[i].identifier ? rows[i].identifier : ""; row.state = rows[i].state;
            if (row.id.empty() || !jsti::wide(rows[i].name, row.name) || !jsti::wide(rows[i].detail, row.detail)) return -1;
            changed.rows.push_back(std::move(row));
        }
        std::lock_guard<std::mutex> lock(mutex);
        current = std::move(changed);
        if (active && !PostMessageW(active, refreshMessage, 0, 0)) return -1;
        return 0;
    } catch (const std::exception &) { return -1; }
}

void jsti_show_local_cleanup(HWND owner) {
    Dialog dialog; dialog.config = snapshot();
    if (!dialog.config.callback) { jsti_window_update("Local cleanup controls are unavailable.", nullptr, -1); return; }
    WNDCLASSW type{}; type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItLocalCleanup"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        jsti_window_update(jsti::systemError("Registering local cleanup controls").c_str(), nullptr, -1); return;
    }
    HWND window = CreateWindowExW(WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, type.lpszClassName,
        L"Downloaded local cleanup models", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME,
        CW_USEDEFAULT, CW_USEDEFAULT, px(owner, 760), px(owner, 760), owner, nullptr, type.hInstance, &dialog);
    if (!window) { jsti_window_update(jsti::systemError("Opening local cleanup controls").c_str(), nullptr, -1); return; }
    { std::lock_guard<std::mutex> lock(mutex); active = window; }
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW);
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading local cleanup controls").c_str(), nullptr, -1);
}
