#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commdlg.h>
#include <mutex>
#include <vector>

int jsti_save_owned_window_snapshot(HWND window, const char *path, char *error, size_t capacity);

namespace {
enum { sourceLabel = 920, sourceID, textLabel, textID, loadID, noticeID, readID, exportID, stopID };
struct Configuration {
    std::vector<std::wstring> names;
    JSTIVoiceSourceCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex mutex;
Configuration configuration;
struct Dialog {
    Configuration config;
    std::string record;
    std::wstring history, typed, clipboard;
    int source = 0;
    HFONT font = nullptr;
    std::vector<HWND> controls;
};

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
std::wstring text(HWND window) {
    HWND editor = GetDlgItem(window, textID);
    const int count = GetWindowTextLengthW(editor);
    std::wstring value(static_cast<size_t>(count) + 1, 0);
    GetWindowTextW(editor, value.data(), count + 1);
    value.resize(static_cast<size_t>(count));
    return value;
}
bool hasText(const std::wstring &value) {
    return value.find_first_not_of(L" \r\n\t") != std::wstring::npos;
}
void refresh(HWND window, Dialog &dialog) {
    const bool ready = dialog.source != 3 && hasText(text(window)) &&
        (dialog.source != 0 || !dialog.record.empty());
    EnableWindow(GetDlgItem(window, readID), ready);
    EnableWindow(GetDlgItem(window, exportID), ready);
    EnableWindow(GetDlgItem(window, loadID), dialog.source == 2);
    SendDlgItemMessageW(window, textID, EM_SETREADONLY, dialog.source != 1, 0);
}
void select(HWND window, Dialog &dialog) {
    if (dialog.source == 1) dialog.typed = text(window);
    dialog.source = static_cast<int>(SendDlgItemMessageW(window, sourceID, CB_GETCURSEL, 0, 0));
    const auto &value = dialog.source == 0 ? dialog.history : dialog.source == 1 ? dialog.typed : dialog.clipboard;
    SetDlgItemTextW(window, textID, dialog.source == 3 ? L"" : value.c_str());
    SetDlgItemTextW(window, noticeID, dialog.source == 3
        ? L"Unavailable: this app has no captured external selection target. It will never read its own focused "
          L"control or silently use the clipboard. Copy explicitly, then choose Clipboard snapshot."
        : dialog.source == 0 && dialog.record.empty()
        ? L"Choose a recording in History, then reopen this editor. History text is captured when this editor opens."
        : L"Read and Export send this text to Deepgram using your saved key. Export creates a 24 kHz mono PCM16 WAV "
          L"without playback. Speed is the engine default. Stop cancels synthesis, playback or export.");
    refresh(window, dialog);
}
void loadClipboard(HWND window, Dialog &dialog) {
    dialog.clipboard.clear();
    SetDlgItemTextW(window, textID, L"");
    refresh(window, dialog);
    if (!OpenClipboard(window)) {
        SetDlgItemTextW(window, noticeID, L"The clipboard is busy. Try Load clipboard again.");
        return;
    }
    std::wstring captured;
    std::wstring failure;
    HANDLE memory = GetClipboardData(CF_UNICODETEXT);
    if (!memory) failure = L"The clipboard has no text.";
    else {
        const SIZE_T bytes = GlobalSize(memory);
        const auto value = static_cast<const wchar_t *>(GlobalLock(memory));
        if (!value) failure = L"The clipboard text could not be read.";
        else {
            const size_t capacity = bytes / sizeof(wchar_t);
            size_t count = 0;
            while (count < capacity && count <= 200000 && value[count]) ++count;
            if (count >= capacity || count > 200000) failure = L"Clipboard text is too large or invalid.";
            else captured.assign(value, count);
            GlobalUnlock(memory);
        }
    }
    CloseClipboard();
    if (!failure.empty()) { SetDlgItemTextW(window, noticeID, failure.c_str()); return; }
    dialog.clipboard = std::move(captured);
    SetDlgItemTextW(window, textID, dialog.clipboard.c_str());
    SetDlgItemTextW(window, noticeID, L"Clipboard text captured. Later clipboard changes cannot change this snapshot.");
    refresh(window, dialog);
}
void emit(HWND window, Dialog &dialog, int action, const std::string &path = "") {
    const std::string snapshot = jsti::utf8(text(window));
    const std::string record = dialog.source == 0 ? dialog.record : "";
    if (dialog.config.callback) {
        dialog.config.callback(action, dialog.source, snapshot.c_str(), record.c_str(), path.c_str(), dialog.config.context);
    }
}
void exportAudio(HWND window, Dialog &dialog) {
    // The nested save loop may process editor messages: freeze the entire job first.
    const std::string snapshot = jsti::utf8(text(window));
    const std::string record = dialog.source == 0 ? dialog.record : "";
    const int source = dialog.source;
    std::vector<wchar_t> path(32768, 0);
    wcscpy_s(path.data(), path.size(), L"voice-output.wav");
    OPENFILENAMEW choice{};
    choice.lStructSize = sizeof(choice);
    choice.hwndOwner = window;
    choice.lpstrFilter = L"WAV audio (*.wav)\0*.wav\0";
    choice.lpstrFile = path.data();
    choice.nMaxFile = static_cast<DWORD>(path.size());
    choice.lpstrDefExt = L"wav";
    choice.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetSaveFileNameW(&choice)) {
        if (CommDlgExtendedError()) SetDlgItemTextW(window, noticeID, L"The audio save dialog could not be opened.");
        return;
    }
    const std::string destination = jsti::utf8(path.data());
    if (dialog.config.callback) {
        dialog.config.callback(111, source, snapshot.c_str(), record.c_str(), destination.c_str(), dialog.config.context);
    }
    SetDlgItemTextW(window, noticeID, L"Export started. Check the main window status for its result. Stop cancels it.");
}
void layout(HWND window) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int margin = scale(window, 20), gap = scale(window, 10), height = scale(window, 34);
    const int width = bounds.right - 2 * margin, bottom = bounds.bottom - margin - height;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(sourceLabel, margin, margin, width, scale(window, 22));
    move(sourceID, margin, margin + scale(window, 26), width - scale(window, 170), scale(window, 240));
    move(loadID, bounds.right - margin - scale(window, 160), margin + scale(window, 26), scale(window, 160), height);
    move(textLabel, margin, margin + scale(window, 70), width, scale(window, 22));
    const int top = margin + scale(window, 96), note = bottom - gap - scale(window, 90);
    move(textID, margin, top, width, std::max(scale(window, 110), note - gap - top));
    move(noticeID, margin, note, width, scale(window, 90));
    const int button = (width - 3 * gap) / 4;
    const int ids[] = {readID, exportID, stopID, IDCANCEL};
    for (int index = 0; index < 4; ++index) move(ids[index], margin + index * (button + gap), bottom, button, height);
}
bool create(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *label, DWORD style, int id, DWORD ex = 0) {
        HWND child = CreateWindowExW(ex, kind, label, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (child) dialog.controls.push_back(child);
        return child != nullptr;
    };
    if (!add(L"STATIC", L"&Source", 0, sourceLabel) ||
        !add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, sourceID) ||
        !add(L"BUTTON", L"&Load clipboard", BS_PUSHBUTTON | WS_TABSTOP, loadID) ||
        !add(L"STATIC", L"&Text snapshot", 0, textLabel) ||
        !add(L"EDIT", L"", ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL | WS_TABSTOP,
             textID, WS_EX_CLIENTEDGE) ||
        !add(L"STATIC", L"", SS_LEFT, noticeID) ||
        !add(L"BUTTON", L"&Read aloud", BS_DEFPUSHBUTTON | WS_TABSTOP, readID) ||
        !add(L"BUTTON", L"&Export WAV...", BS_PUSHBUTTON | WS_TABSTOP, exportID) ||
        !add(L"BUTTON", L"&Stop", BS_PUSHBUTTON | WS_TABSTOP, stopID) ||
        !add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL)) return false;
    dialog.font = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    for (HWND child : dialog.controls) SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(dialog.font), TRUE);
    SendDlgItemMessageW(window, textID, EM_SETLIMITTEXT, 200000, 0);
    for (const auto &name : dialog.config.names) {
        if (SendDlgItemMessageW(window, sourceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str())) < 0) return false;
    }
    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, 0, 0);
    select(window, dialog); layout(window);
    return true;
}
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: return create(window, *dialog) ? 0 : -1;
    case WM_SIZE: layout(window); return 0;
    case WM_GETMINMAXINFO: {
        RECT size{0, 0, scale(window, 620), scale(window, 540)};
        AdjustWindowRectExForDpi(&size, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(window));
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {size.right - size.left, size.bottom - size.top};
        return 0;
    }
    case WM_DPICHANGED: {
        const auto bounds = reinterpret_cast<const RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        HFONT font = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        if (font) {
            for (HWND child : dialog->controls) SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
            if (dialog->font) DeleteObject(dialog->font);
            dialog->font = font;
        }
        layout(window); return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == sourceID && HIWORD(wparam) == CBN_SELCHANGE) { select(window, *dialog); return 0; }
        if (LOWORD(wparam) == textID && HIWORD(wparam) == EN_CHANGE) { refresh(window, *dialog); return 0; }
        if (HIWORD(wparam) != BN_CLICKED) break;
        switch (LOWORD(wparam)) {
        case loadID: loadClipboard(window, *dialog); break;
        case readID: if (IsWindowEnabled(GetDlgItem(window, readID))) emit(window, *dialog, 110); break;
        case exportID: if (IsWindowEnabled(GetDlgItem(window, exportID))) exportAudio(window, *dialog); break;
        case stopID: emit(window, *dialog, 112); break;
        case IDCANCEL: DestroyWindow(window); break;
        }
        return 0;
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY: if (dialog->font) DeleteObject(dialog->font); dialog->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
HWND makeDialog(HWND owner, Dialog &dialog) {
    WNDCLASSW type{};
    type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItVoiceSources"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    return CreateWindowExW(WS_EX_CONTROLPARENT | WS_EX_DLGMODALFRAME, type.lpszClassName,
        L"Voice Output text and export", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
        scale(owner, 700), scale(owner, 650), owner, nullptr, type.hInstance, &dialog);
}
} // namespace

int32_t jsti_window_set_voice_sources(const char *const *names, size_t count,
                                     JSTIVoiceSourceCallback callback, void *context) {
    if (!names || count != 3 || !callback) return -1;
    Configuration changed;
    for (size_t index = 0; index < count; ++index) {
        std::wstring name;
        if (!jsti::wide(names[index], name) || name.empty()) return -1;
        changed.names.push_back(std::move(name));
    }
    changed.callback = callback; changed.context = context;
    std::lock_guard<std::mutex> lock(mutex); configuration = std::move(changed);
    return 0;
}

void jsti_show_voice_sources(HWND owner, const char *record, const char *history) {
    Dialog dialog;
    { std::lock_guard<std::mutex> lock(mutex); dialog.config = configuration; }
    if (!dialog.config.callback) return;
    dialog.record = record ? record : "";
    if (!jsti::wide(history ? history : "", dialog.history)) return;
    HWND window = makeDialog(owner, dialog);
    if (!window) { jsti_window_update("The Voice Output editor could not be opened.", nullptr, -1); return; }
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, sourceID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) jsti_window_update("Reading Voice Output messages failed.", nullptr, -1);
}

void jsti_voice_sources_stop() {
    Configuration config;
    { std::lock_guard<std::mutex> lock(mutex); config = configuration; }
    if (config.callback) config.callback(112, 0, "", "", "", config.context);
}

bool jsti_voice_sources_self_test(HWND owner, std::string &error) {
    struct Received { int calls = 0, source = -1; std::string text, record; } received;
    Dialog dialog;
    { std::lock_guard<std::mutex> lock(mutex); dialog.config = configuration; }
    dialog.config.callback = [](int32_t action, int32_t source, const char *value,
                                const char *record, const char *, void *context) {
        auto &result = *static_cast<Received *>(context);
        if (action == 110) { ++result.calls; result.source = source; result.text = value; result.record = record; }
    };
    dialog.config.context = &received;
    dialog.record = "synthetic-record"; dialog.history = L"Synthetic History snapshot";
    HWND window = makeDialog(owner, dialog);
    if (!window) { error = "Voice sources fixture could not open."; return false; }
    const bool history = text(window) == dialog.history && IsWindowEnabled(GetDlgItem(window, readID));
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(readID, BN_CLICKED), 0);
    const bool historySnapshot = received.calls == 1 && received.source == 0 &&
        received.record == "synthetic-record" && received.text == "Synthetic History snapshot";
    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, 1, 0); select(window, dialog);
    SetDlgItemTextW(window, textID, L"Synthetic typed text");
    // Multiline WM_SETTEXT does not emit EN_CHANGE; simulate the user edit notification.
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(textID, EN_CHANGE), 0);
    const bool typed = IsWindowEnabled(GetDlgItem(window, exportID)) &&
        !(GetWindowLongW(GetDlgItem(window, textID), GWL_STYLE) & ES_READONLY);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(readID, BN_CLICKED), 0);
    const bool typedSnapshot = received.calls == 2 && received.source == 1 &&
        received.record.empty() && received.text == "Synthetic typed text";
    bool captured = true;
    std::vector<wchar_t> snapshotPath(32768, 0);
    const DWORD length = GetEnvironmentVariableW(L"JSTI_UI_SNAPSHOT_PATH", snapshotPath.data(),
                                                static_cast<DWORD>(snapshotPath.size()));
    if (length && length < snapshotPath.size()) {
        const std::string path = jsti::utf8(snapshotPath.data()) + ".voice-sources.bmp";
        char failure[1024]{};
        ShowWindow(window, SW_SHOWNOACTIVATE);
        captured = jsti_save_owned_window_snapshot(window, path.c_str(), failure, sizeof(failure)) == 0;
        if (!captured) error = failure;
    }
    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, 2, 0); select(window, dialog);
    const bool unavailable = !IsWindowEnabled(GetDlgItem(window, readID)) &&
        !IsWindowEnabled(GetDlgItem(window, exportID)) && text(window).empty() &&
        SendDlgItemMessageW(window, sourceID, CB_GETCOUNT, 0, 0) == 3;
    dialog.clipboard = L"Synthetic clipboard snapshot";
    SetDlgItemTextW(window, textID, dialog.clipboard.c_str());
    refresh(window, dialog);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(readID, BN_CLICKED), 0);
    const bool clipboardSnapshot = received.calls == 3 && received.source == 2 &&
        received.record.empty() && received.text == "Synthetic clipboard snapshot";
    DestroyWindow(window);
    const bool passed = history && typed && unavailable && historySnapshot && typedSnapshot && clipboardSnapshot;
    if (!passed) {
        error = "Voice sources fixture failed: history=" + std::to_string(history) +
            ", typed=" + std::to_string(typed) + ", unloadedClipboard=" + std::to_string(unavailable) +
            ", historySnapshot=" + std::to_string(historySnapshot) +
            ", typedSnapshot=" + std::to_string(typedSnapshot) +
            ", clipboardSnapshot=" + std::to_string(clipboardSnapshot) + ".";
    }
    return passed && captured;
}
