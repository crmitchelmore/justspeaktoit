#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commctrl.h>
#include <shellapi.h>
#include <mutex>
#include <vector>

// Native Local models dialog: downloads, resumes, cancels and removes the
// on-device speech and language models the host projects from the shared
// catalogue, imports files from Hugging Face, and chooses whether the local
// runtimes may use a Vulkan GPU. The host owns every file and network
// operation; this dialog only shows rows and reports actions.

namespace {
enum Control {
    introID = 1000, listLabelID, listID, aboutID, downloadID, cancelDownloadID, removeID, gpuID, runtimeID,
    importLabelID, repositoryID, fileID, importID, browseID
};
constexpr const wchar_t *browseAddress = L"https://huggingface.co/models?library=gguf&sort=downloads";
constexpr UINT refreshMessage = WM_APP + 41;
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 560, minimumClientHeight = 540;

struct Row {
    std::wstring name, detail, about;
    int state = JSTI_LOCAL_MODEL_NOT_INSTALLED;
};

struct Configuration {
    std::vector<Row> rows;
    std::wstring runtime;
    bool useGPU = true;
    JSTILocalModelCallback callback = nullptr;
    void *context = nullptr;
    uint64_t revision = 0;
};
std::mutex configurationMutex;
Configuration configuration;
HWND openDialog = nullptr; // Guarded by configurationMutex; at most one dialog.
// The import fields, readable only while the callback for an import runs.
thread_local std::string pendingRepository, pendingFile;

struct Dialog {
    Configuration config;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    int selected = 0;
};

Configuration snapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), button = at(32), gap = at(10);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    const int bottom = static_cast<int>(bounds.bottom) - margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(introID, margin, at(14), width, at(40));
    move(listLabelID, margin, at(58), width, at(22));
    const int listTop = at(82);
    const int importTop = bottom - button - gap - at(44) - gap - at(24) - gap - button;
    const int actionsTop = importTop - gap - at(22) - gap - button;
    const int aboutHeight = at(64);
    const int listHeight = std::max(at(96), actionsTop - gap - aboutHeight - gap - listTop);
    move(listID, margin, listTop, width, listHeight);
    move(aboutID, margin, listTop + listHeight + gap, width, aboutHeight);
    const int actionWidth = (width - 2 * gap) / 3;
    move(downloadID, margin, actionsTop, actionWidth, button);
    move(cancelDownloadID, margin + actionWidth + gap, actionsTop, actionWidth, button);
    move(removeID, margin + 2 * (actionWidth + gap), actionsTop, width - 2 * (actionWidth + gap), button);
    move(importLabelID, margin, actionsTop + button + gap, width, at(22));
    const int addWidth = at(90);
    const int fieldWidth = (width - addWidth - 2 * gap) / 2;
    move(repositoryID, margin, importTop, fieldWidth, button);
    move(fileID, margin + fieldWidth + gap, importTop, fieldWidth, button);
    move(importID, margin + 2 * (fieldWidth + gap), importTop, width - 2 * (fieldWidth + gap), button);
    move(gpuID, margin, importTop + button + gap, width, at(24));
    move(runtimeID, margin, importTop + button + gap + at(24) + gap, width, at(44));
    move(browseID, margin, bottom - button, at(190), button);
    move(IDCANCEL, static_cast<int>(bounds.right) - margin - at(100), bottom - button, at(100), button);
}

void refreshFont(HWND window, Dialog &dialog) {
    HFONT font = CreateFontW(-MulDiv(10, static_cast<int>(GetDpiForWindow(window)), 72), 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!font) return;
    for (HWND control : dialog.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = font;
}

// Buttons follow the selected row's state; nothing acts on a stale row.
void updateActions(HWND window, Dialog &dialog) {
    const bool valid = dialog.selected >= 0 && static_cast<size_t>(dialog.selected) < dialog.config.rows.size();
    const int state = valid ? dialog.config.rows[static_cast<size_t>(dialog.selected)].state : -1;
    SetDlgItemTextW(window, downloadID, state == JSTI_LOCAL_MODEL_PARTIAL ? L"&Resume download" : L"&Download");
    EnableWindow(GetDlgItem(window, downloadID), state == JSTI_LOCAL_MODEL_NOT_INSTALLED || state == JSTI_LOCAL_MODEL_PARTIAL);
    EnableWindow(GetDlgItem(window, cancelDownloadID), state == JSTI_LOCAL_MODEL_DOWNLOADING);
    EnableWindow(GetDlgItem(window, removeID), state == JSTI_LOCAL_MODEL_INSTALLED || state == JSTI_LOCAL_MODEL_PARTIAL);
    SetDlgItemTextW(window, aboutID, valid ? dialog.config.rows[static_cast<size_t>(dialog.selected)].about.c_str() : L"");
}

bool populate(HWND window, Dialog &dialog) {
    HWND list = GetDlgItem(window, listID);
    SendMessageW(list, WM_SETREDRAW, FALSE, 0);
    SendMessageW(list, LB_RESETCONTENT, 0, 0);
    bool okay = true;
    for (const auto &row : dialog.config.rows) {
        const std::wstring text = row.name + L" — " + row.detail;
        const LRESULT added = SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(text.c_str()));
        if (added == LB_ERR || added == LB_ERRSPACE) { okay = false; break; }
    }
    if (dialog.config.rows.empty()) dialog.selected = -1;
    else dialog.selected = std::min(std::max(dialog.selected, 0), static_cast<int>(dialog.config.rows.size()) - 1);
    SendMessageW(list, LB_SETCURSEL, static_cast<WPARAM>(dialog.selected), 0);
    SendMessageW(list, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(list, nullptr, TRUE);
    CheckDlgButton(window, gpuID, dialog.config.useGPU ? BST_CHECKED : BST_UNCHECKED);
    SetDlgItemTextW(window, runtimeID, dialog.config.runtime.c_str());
    updateActions(window, dialog);
    return okay;
}

bool createControls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        const bool edged = wcscmp(kind, L"LISTBOX") == 0 || wcscmp(kind, L"EDIT") == 0;
        HWND control = CreateWindowExW(edged ? WS_EX_CLIENTEDGE : 0, kind, text,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay =
        add(L"STATIC", L"Local models run on this PC: audio and text never leave it. Download a speech model, then "
            L"choose Source: Local; download a language model for Local post-processing.", SS_LEFT, introID) &&
        add(L"STATIC", L"&Models", 0, listLabelID) &&
        add(L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP, listID) &&
        add(L"STATIC", L"", SS_LEFT, aboutID) &&
        add(L"BUTTON", L"&Download", BS_PUSHBUTTON | WS_TABSTOP, downloadID) &&
        add(L"BUTTON", L"&Cancel download", BS_PUSHBUTTON | WS_TABSTOP, cancelDownloadID) &&
        add(L"BUTTON", L"Re&move", BS_PUSHBUTTON | WS_TABSTOP, removeID) &&
        add(L"STATIC", L"Add from Hugging Face: &repository (owner/name) and file (a whisper.cpp .bin or a .gguf model)",
            0, importLabelID) &&
        add(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, repositoryID) &&
        add(L"EDIT", L"", ES_AUTOHSCROLL | WS_TABSTOP, fileID) &&
        add(L"BUTTON", L"&Add", BS_PUSHBUTTON | WS_TABSTOP, importID) &&
        add(L"BUTTON", L"Browse Hugging &Face\u2026", BS_PUSHBUTTON | WS_TABSTOP, browseID) &&
        add(L"BUTTON", L"Use a &GPU through Vulkan when available (takes effect after restarting the app)",
            BS_AUTOCHECKBOX | WS_TABSTOP, gpuID) &&
        add(L"STATIC", L"", SS_LEFT, runtimeID) &&
        add(L"BUTTON", L"Close", BS_DEFPUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    SendDlgItemMessageW(window, repositoryID, EM_LIMITTEXT, 200, 0);
    SendDlgItemMessageW(window, fileID, EM_LIMITTEXT, 512, 0);
    SendDlgItemMessageW(window, repositoryID, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(L"ggerganov/whisper.cpp"));
    SendDlgItemMessageW(window, fileID, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(L"ggml-small.en.bin"));
    refreshFont(window, dialog);
    layout(window);
    return populate(window, dialog);
}

void close(HWND window) {
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        if (openDialog == window) openDialog = nullptr;
    }
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

std::wstring fieldText(HWND window, int id) {
    const HWND control = GetDlgItem(window, id);
    const int length = GetWindowTextLengthW(control);
    std::wstring text(static_cast<size_t>(std::max(length, 0)) + 1, 0);
    const int copied = GetWindowTextW(control, &text[0], length + 1);
    text.resize(static_cast<size_t>(std::max(copied, 0)));
    return text;
}

// The host validates the fields, resolves the file and reports the outcome in
// the status line; the file field is cleared once the request is handed over.
void requestImport(HWND window, Dialog &dialog) {
    if (!dialog.config.callback) return;
    pendingRepository = jsti::utf8(fieldText(window, repositoryID));
    pendingFile = jsti::utf8(fieldText(window, fileID));
    if (pendingRepository.empty() || pendingFile.empty()) {
        SetDlgItemTextW(window, runtimeID, L"Enter the Hugging Face repository and the file to add.");
    } else {
        dialog.config.callback(JSTI_LOCAL_MODEL_IMPORT, -1, dialog.config.context);
        SetDlgItemTextW(window, fileID, L"");
    }
    pendingRepository.clear();
    pendingFile.clear();
}

void act(Dialog &dialog, int action) {
    const bool rowAction = action == JSTI_LOCAL_MODEL_DOWNLOAD || action == JSTI_LOCAL_MODEL_CANCEL ||
        action == JSTI_LOCAL_MODEL_REMOVE;
    if (rowAction && (dialog.selected < 0 || static_cast<size_t>(dialog.selected) >= dialog.config.rows.size())) return;
    if (dialog.config.callback) dialog.config.callback(action, rowAction ? dialog.selected : -1, dialog.config.context);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: return createControls(window, *dialog) ? 0 : -1;
    case WM_GETMINMAXINFO: {
        RECT frame{0, 0, scale(window, minimumClientWidth), scale(window, minimumClientHeight)};
        AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(window));
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {frame.right - frame.left, frame.bottom - frame.top};
        return 0;
    }
    case WM_SIZE: layout(window); return 0;
    case WM_DPICHANGED: {
        const RECT *bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        refreshFont(window, *dialog); layout(window); return 0;
    }
    case WM_ACTIVATE:
        if (LOWORD(wparam) == WA_INACTIVE) { dialog->focus = GetFocus(); return 0; }
        SetFocus(dialog->focus && IsChild(window, dialog->focus) ? dialog->focus : GetDlgItem(window, listID));
        return 0;
    case DM_GETDEFID: return MAKELRESULT(IDCANCEL, DC_HASDEFID);
    case refreshMessage: {
        Configuration latest = snapshot();
        if (latest.revision != dialog->config.revision) {
            dialog->config = std::move(latest);
            populate(window, *dialog);
        }
        return 0;
    }
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case listID:
            if (HIWORD(wparam) == LBN_SELCHANGE) {
                const LRESULT chosen = SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0);
                dialog->selected = chosen == LB_ERR ? -1 : static_cast<int>(chosen);
                updateActions(window, *dialog);
            }
            return 0;
        case downloadID: if (HIWORD(wparam) == BN_CLICKED) act(*dialog, JSTI_LOCAL_MODEL_DOWNLOAD); return 0;
        case cancelDownloadID: if (HIWORD(wparam) == BN_CLICKED) act(*dialog, JSTI_LOCAL_MODEL_CANCEL); return 0;
        case removeID: if (HIWORD(wparam) == BN_CLICKED) act(*dialog, JSTI_LOCAL_MODEL_REMOVE); return 0;
        case importID: if (HIWORD(wparam) == BN_CLICKED) requestImport(window, *dialog); return 0;
        case browseID:
            if (HIWORD(wparam) == BN_CLICKED) ShellExecuteW(window, L"open", browseAddress, nullptr, nullptr, SW_SHOWNORMAL);
            return 0;
        case gpuID:
            if (HIWORD(wparam) == BN_CLICKED) {
                act(*dialog, IsDlgButtonChecked(window, gpuID) == BST_CHECKED ? JSTI_LOCAL_MODEL_GPU_ON
                                                                                : JSTI_LOCAL_MODEL_GPU_OFF);
            }
            return 0;
        case IDCANCEL: if (HIWORD(wparam) == BN_CLICKED) close(window); return 0;
        }
        break;
    case WM_CLOSE: close(window); return 0;
    case WM_DESTROY:
        if (dialog->font) { DeleteObject(dialog->font); dialog->font = nullptr; }
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

HWND createDialog(HWND owner, Dialog &dialog) {
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItLocalModels";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT frame{0, 0, scale(owner, 620), scale(owner, 500)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(owner));
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    HWND window = CreateWindowExW(windowExStyle, type.lpszClassName, L"Local models — Just Speak to It", windowStyle,
        bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), frame.right - frame.left,
        frame.bottom - frame.top, owner, nullptr, instance, &dialog);
    if (window) {
        std::lock_guard<std::mutex> lock(configurationMutex);
        openDialog = window;
    }
    return window;
}
} // namespace

int jsti_local_models_import_fields(char *repository, size_t repositoryCapacity, char *file, size_t fileCapacity) {
    if (!repository || !file || pendingRepository.empty() || pendingFile.empty() ||
        pendingRepository.size() >= repositoryCapacity || pendingFile.size() >= fileCapacity) return -1;
    std::memcpy(repository, pendingRepository.c_str(), pendingRepository.size() + 1);
    std::memcpy(file, pendingFile.c_str(), pendingFile.size() + 1);
    return 0;
}

bool jsti_local_models_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr && !configuration.rows.empty();
}

std::wstring jsti_local_models_summary() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.runtime;
}

void jsti_show_local_models(HWND owner) {
    Dialog dialog;
    dialog.config = snapshot();
    if (!dialog.config.callback || dialog.config.rows.empty()) return;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening local models").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, listID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) close(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading local model messages").c_str(), nullptr, -1);
}

int jsti_window_set_local_models(const JSTILocalModelRow *rows, size_t count, const char *runtimeStatus, int useGPU,
                                 JSTILocalModelCallback callback, void *context) {
    if (!callback || (count && !rows) || count > 256 || (useGPU != 0 && useGPU != 1)) return -1;
    HWND dialog = nullptr;
    try {
        Configuration updated;
        for (size_t index = 0; index < count; ++index) {
            Row row;
            if (!jsti::wide(rows[index].name, row.name) || row.name.empty() || row.name.size() > 256 ||
                !jsti::wide(rows[index].detail, row.detail) || row.detail.size() > 256 ||
                !jsti::wide(rows[index].about, row.about) || row.about.size() > 2048 ||
                rows[index].state < JSTI_LOCAL_MODEL_NOT_INSTALLED || rows[index].state > JSTI_LOCAL_MODEL_INSTALLED) {
                return -1;
            }
            row.state = rows[index].state;
            updated.rows.push_back(std::move(row));
        }
        if (runtimeStatus && (!jsti::wide(runtimeStatus, updated.runtime) || updated.runtime.size() > 1024)) return -1;
        updated.useGPU = useGPU == 1;
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

void jsti_window_clear_local_models(void) {
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = Configuration(); }
    jsti_window_update(nullptr, nullptr, -1);
}

// ---- self-test -------------------------------------------------------------

namespace {
struct Actions { std::vector<std::pair<int, int>> calls; std::string repository, file; };
void recordAction(int action, int index, void *context) {
    auto *actions = static_cast<Actions *>(context);
    actions->calls.emplace_back(action, index);
    if (action == JSTI_LOCAL_MODEL_IMPORT) {
        char repository[256] = {}, file[600] = {};
        if (jsti_local_models_import_fields(repository, sizeof(repository), file, sizeof(file)) == 0) {
            actions->repository = repository;
            actions->file = file;
        }
    }
}
} // namespace

// Validation, per-state buttons, every action with the row it names, a live
// refresh while open, the GPU choice and Close emitting nothing.
bool jsti_local_models_self_test(HWND owner, std::string &error) {
    const Configuration original = snapshot();
    Actions actions;
    bool passed = false;
    try {
        JSTILocalModelRow rows[] = {
            {"Tiny", "75 MB \xC2\xB7 Not downloaded", "About tiny", JSTI_LOCAL_MODEL_NOT_INSTALLED},
            {"Base", "141 MB \xC2\xB7 Downloaded", "About base", JSTI_LOCAL_MODEL_INSTALLED},
            {"Small", "465 MB \xC2\xB7 12% downloaded", "About small", JSTI_LOCAL_MODEL_PARTIAL}
        };
        JSTILocalModelRow invalid = rows[0];
        invalid.state = 9;
        if (jsti_window_set_local_models(&invalid, 1, "", 1, recordAction, &actions) != -1 ||
            jsti_window_set_local_models(rows, 3, "", 1, nullptr, &actions) != -1 ||
            jsti_window_set_local_models(rows, 3, "Runtime fixture", 1, recordAction, &actions) != 0 ||
            !jsti_local_models_available() || jsti_local_models_summary() != L"Runtime fixture") {
            error = "Local model configuration accepted an invalid row or rejected a valid one.";
        } else {
            Dialog dialog;
            dialog.config = snapshot();
            HWND window = createDialog(owner, dialog);
            if (!window) {
                error = jsti::systemError("Creating the local models fixture");
            } else {
                auto select = [&](int index) {
                    SendDlgItemMessageW(window, listID, LB_SETCURSEL, static_cast<WPARAM>(index), 0);
                    SendMessageW(window, WM_COMMAND, MAKEWPARAM(listID, LBN_SELCHANGE), 0);
                };
                auto click = [&](int id) { SendMessageW(window, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED), 0); };
                auto enabled = [&](int id) { return IsWindowEnabled(GetDlgItem(window, id)) != FALSE; };
                const bool listed = SendDlgItemMessageW(window, listID, LB_GETCOUNT, 0, 0) == 3;
                select(0);
                const bool notInstalled = enabled(downloadID) && !enabled(cancelDownloadID) && !enabled(removeID);
                click(downloadID);
                select(1);
                const bool installed = !enabled(downloadID) && !enabled(cancelDownloadID) && enabled(removeID);
                click(removeID);
                select(2);
                wchar_t resume[64] = {};
                GetDlgItemTextW(window, downloadID, resume, 64);
                const bool partial = enabled(downloadID) && enabled(removeID) && std::wstring(resume) == L"&Resume download";
                rows[2].state = JSTI_LOCAL_MODEL_DOWNLOADING;
                rows[2].detail = "465 MB \xC2\xB7 Downloading 40%";
                jsti_window_set_local_models(rows, 3, "Runtime fixture", 0, recordAction, &actions);
                SendMessageW(window, refreshMessage, 0, 0);
                const bool downloading = !enabled(downloadID) && enabled(cancelDownloadID) && !enabled(removeID) &&
                    IsDlgButtonChecked(window, gpuID) == BST_UNCHECKED;
                click(cancelDownloadID);
                CheckDlgButton(window, gpuID, BST_CHECKED);
                click(gpuID);
                const size_t beforeEmptyImport = actions.calls.size();
                click(importID); // Nothing entered: nothing is requested.
                const bool emptyIgnored = actions.calls.size() == beforeEmptyImport;
                SetDlgItemTextW(window, repositoryID, L"ggerganov/whisper.cpp");
                SetDlgItemTextW(window, fileID, L"ggml-small.en-q5_1.bin");
                click(importID);
                const bool imported = emptyIgnored && actions.repository == "ggerganov/whisper.cpp" &&
                    actions.file == "ggml-small.en-q5_1.bin" && GetWindowTextLengthW(GetDlgItem(window, fileID)) == 0 &&
                    GetWindowTextLengthW(GetDlgItem(window, repositoryID)) > 0;
                const size_t beforeClose = actions.calls.size();
                click(IDCANCEL);
                const bool closed = !IsWindow(window) && actions.calls.size() == beforeClose;
                if (IsWindow(window)) DestroyWindow(window);
                const std::vector<std::pair<int, int>> expected = {
                    {JSTI_LOCAL_MODEL_DOWNLOAD, 0}, {JSTI_LOCAL_MODEL_REMOVE, 1}, {JSTI_LOCAL_MODEL_CANCEL, 2},
                    {JSTI_LOCAL_MODEL_GPU_ON, -1}, {JSTI_LOCAL_MODEL_IMPORT, -1}
                };
                passed = listed && notInstalled && installed && partial && downloading && closed && imported &&
                    actions.calls == expected;
                if (!passed) error = "The Local models dialog did not match its row states or reported the wrong action.";
            }
        }
    } catch (const std::exception &) { error = "The local models self-test could not allocate its fixtures."; }
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        const uint64_t revision = configuration.revision;
        configuration = original;
        configuration.revision = revision + 1;
    }
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
