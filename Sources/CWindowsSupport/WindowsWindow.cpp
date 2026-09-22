#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commdlg.h>
#include <mutex>
#include <vector>

namespace {
constexpr UINT updateMessage = WM_APP + 1;
constexpr int hotkeyID = 1;
enum Control { modelID = 100, keyID, saveID, recordID, importID, copyID, transcriptID, statusID };
struct WindowState {
    std::mutex mutex;
    HWND window = nullptr;
    bool running = false;
    bool posted = false;
    bool statusChanged = false;
    bool transcriptChanged = false;
    int recording = 0;
    std::wstring status;
    std::wstring transcript;
    JSTIWindowCallback callback = nullptr;
    void *context = nullptr;
    HFONT font = nullptr;
    std::vector<HWND> controls;
} state;

int selection(HWND window) {
    return static_cast<int>(SendDlgItemMessageW(window, modelID, CB_GETCURSEL, 0, 0));
}

void emit(HWND window, int event, const char *text = "") {
    if (state.callback) state.callback(event, text, selection(window), state.context);
}

void showFailure(HWND window, const std::string &message) {
    emit(window, JSTI_EVENT_ERROR, message.c_str());
    std::wstring wide;
    if (jsti::wide(message.c_str(), wide)) SetDlgItemTextW(window, statusID, wide.c_str());
}

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    const int margin = scale(window, 20);
    const int gap = scale(window, 12);
    const int row = scale(window, 34);
    const int width = std::max(scale(window, 320), static_cast<int>(bounds.right) - 2 * margin);
    const int saveWidth = scale(window, 112);
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(90, margin, margin, width, scale(window, 22));
    move(modelID, margin, margin + scale(window, 26), width, scale(window, 260));
    move(91, margin, margin + scale(window, 70), width, scale(window, 22));
    const int keyTop = margin + scale(window, 96);
    move(keyID, margin, keyTop, width - saveWidth - gap, row);
    move(saveID, margin + width - saveWidth, keyTop, saveWidth, row);
    const int actionsTop = keyTop + row + gap;
    const int actionWidth = (width - 2 * gap) / 3;
    move(recordID, margin, actionsTop, actionWidth, row);
    move(importID, margin + actionWidth + gap, actionsTop, actionWidth, row);
    move(copyID, margin + 2 * (actionWidth + gap), actionsTop, actionWidth, row);
    move(92, margin, actionsTop + row + gap, width, scale(window, 22));
    const int transcriptTop = actionsTop + row + scale(window, 38);
    const int statusHeight = scale(window, 64);
    const int transcriptHeight = std::max(scale(window, 80), static_cast<int>(bounds.bottom) - transcriptTop - statusHeight - 2 * margin);
    move(transcriptID, margin, transcriptTop, width, transcriptHeight);
    move(statusID, margin, transcriptTop + transcriptHeight + gap, width, statusHeight);
}

void refreshFont(HWND window) {
    HFONT replacement = CreateFontW(-MulDiv(10, static_cast<int>(GetDpiForWindow(window)), 72),
        0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!replacement) return;
    for (HWND control : state.controls) SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(replacement), TRUE);
    if (state.font) DeleteObject(state.font);
    state.font = replacement;
}

bool createControls(HWND window) {
    auto add = [&](const wchar_t *kind, const wchar_t *label, DWORD style, int identifier) {
        HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, kind, label,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(identifier)), GetModuleHandleW(nullptr), nullptr);
        if (control) state.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay = add(L"STATIC", L"&Transcription model", 0, 90) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, modelID) &&
        add(L"STATIC", L"&API key for the selected provider (stored in Windows Credential Manager)", 0, 91) &&
        add(L"EDIT", L"", ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP, keyID) &&
        add(L"BUTTON", L"&Save key", BS_PUSHBUTTON | WS_TABSTOP, saveID) &&
        add(L"BUTTON", L"&Record", BS_PUSHBUTTON | WS_TABSTOP, recordID) &&
        add(L"BUTTON", L"&Import audio", BS_PUSHBUTTON | WS_TABSTOP, importID) &&
        add(L"BUTTON", L"&Copy transcript", BS_PUSHBUTTON | WS_TABSTOP, copyID) &&
        add(L"STATIC", L"Transcript — Ctrl+Alt+Space starts or stops recording", 0, 92) &&
        add(L"EDIT", L"", ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP, transcriptID) &&
        add(L"STATIC", L"Ready. Choose a model and save its API key to begin.", SS_LEFT, statusID);
    SendDlgItemMessageW(window, keyID, EM_LIMITTEXT, 2048, 0);
    SendDlgItemMessageW(window, transcriptID, EM_LIMITTEXT, 4 * 1024 * 1024, 0);
    refreshFont(window);
    return okay;
}

void applyUpdate(HWND window) {
    std::wstring status, transcript;
    bool statusChanged, transcriptChanged;
    int recording;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        status.swap(state.status); transcript.swap(state.transcript);
        statusChanged = state.statusChanged; transcriptChanged = state.transcriptChanged;
        state.statusChanged = false; state.transcriptChanged = false;
        state.posted = false;
        recording = state.recording;
    }
    if (statusChanged) SetDlgItemTextW(window, statusID, status.c_str());
    if (transcriptChanged) SetDlgItemTextW(window, transcriptID, transcript.c_str());
    SetDlgItemTextW(window, recordID, recording == 1 ? L"&Stop recording" : (recording == 2 ? L"Working…" : L"&Record"));
    EnableWindow(GetDlgItem(window, recordID), recording != 2);
    for (int id : {modelID, keyID, saveID, importID}) EnableWindow(GetDlgItem(window, id), recording == 0);
}

void importAudio(HWND window) {
    std::vector<wchar_t> path(32768);
    OPENFILENAMEW chooser{};
    chooser.lStructSize = sizeof(chooser);
    chooser.hwndOwner = window;
    chooser.lpstrFilter = L"Audio files\0*.wav;*.mp3;*.m4a;*.flac;*.ogg;*.webm\0All files\0*.*\0\0";
    chooser.lpstrFile = path.data();
    chooser.nMaxFile = static_cast<DWORD>(path.size());
    chooser.lpstrTitle = L"Choose audio to transcribe";
    chooser.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
    if (GetOpenFileNameW(&chooser)) {
        const std::string text = jsti::utf8(path.data());
        emit(window, JSTI_EVENT_IMPORT_AUDIO, text.c_str());
    } else {
        const DWORD error = CommDlgExtendedError();
        if (error) showFailure(window, jsti::systemError("Opening audio picker", error));
    }
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_CREATE:
        return createControls(window) ? 0 : -1;
    case WM_GETMINMAXINFO: {
        auto info = reinterpret_cast<MINMAXINFO *>(lparam);
        info->ptMinTrackSize = {scale(window, 560), scale(window, 480)};
        return 0;
    }
    case WM_SIZE:
        layout(window); return 0;
    case WM_DPICHANGED: {
        auto bounds = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        refreshFont(window); layout(window); return 0;
    }
    case updateMessage:
        applyUpdate(window); return 0;
    case WM_HOTKEY:
        if (wparam == hotkeyID && IsWindowEnabled(GetDlgItem(window, recordID))) emit(window, JSTI_EVENT_TOGGLE_RECORDING);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wparam)) {
        case recordID: emit(window, JSTI_EVENT_TOGGLE_RECORDING); return 0;
        case importID: importAudio(window); return 0;
        case copyID: emit(window, JSTI_EVENT_COPY_TRANSCRIPT); return 0;
        case modelID:
            if (HIWORD(wparam) == CBN_SELCHANGE) {
                SetDlgItemTextW(window, keyID, L"");
                emit(window, JSTI_EVENT_MODEL_CHANGED);
            }
            return 0;
        case saveID: {
            const int count = GetWindowTextLengthW(GetDlgItem(window, keyID));
            if (count <= 0) { showFailure(window, "Enter an API key before saving."); return 0; }
            std::wstring secret(static_cast<size_t>(count) + 1, 0);
            GetDlgItemTextW(window, keyID, &secret[0], count + 1);
            secret.resize(count);
            std::string text = jsti::utf8(secret);
            emit(window, JSTI_EVENT_SAVE_CREDENTIAL, text.c_str());
            SetDlgItemTextW(window, keyID, L"");
            SecureZeroMemory(&secret[0], secret.size() * sizeof(wchar_t));
            if (!text.empty()) SecureZeroMemory(&text[0], text.size());
            return 0;
        }
        }
        break;
    case WM_CLOSE:
        emit(window, JSTI_EVENT_CLOSING);
        DestroyWindow(window); return 0;
    case WM_DESTROY:
        UnregisterHotKey(window, hotkeyID);
        { std::lock_guard<std::mutex> lock(state.mutex); state.window = nullptr; state.posted = false; }
        PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

int jsti_window_run(const char *const *models, size_t count, int selected,
                    JSTIWindowCallback callback, void *context, char *error, size_t capacity) {
    if (!models || count == 0 || !callback || count > 10000) return jsti::fail("No transcription models or event callback.", error, capacity);
    std::vector<std::wstring> names(count);
    for (size_t i = 0; i < count; ++i) {
        if (!jsti::wide(models[i], names[i])) return jsti::fail("A model label is not valid UTF-8.", error, capacity);
    }
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) return jsti::fail("The desktop window is already running.", error, capacity);
        state.running = true;
        state.recording = 0;
        state.posted = false;
        state.statusChanged = false;
        state.transcriptChanged = false;
        state.status.clear(); state.transcript.clear();
    }
    state.callback = callback; state.context = context;
    state.controls.clear();
    // The process may already have a manifest-defined awareness context.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItWindows";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    type.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    const ATOM registered = RegisterClassW(&type);
    HWND window = registered ? CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName,
        L"Just Speak to It — Windows Preview", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
        800, 660, nullptr, nullptr, instance, nullptr) : nullptr;
    int outcome = 0;
    if (!window) outcome = jsti::fail(jsti::systemError("Creating native desktop window"), error, capacity);
    else {
        { std::lock_guard<std::mutex> lock(state.mutex); state.window = window; }
        for (const auto &name : names) SendDlgItemMessageW(window, modelID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str()));
        SendDlgItemMessageW(window, modelID, CB_SETCURSEL, selected >= 0 && static_cast<size_t>(selected) < count ? selected : 0, 0);
        ShowWindow(window, SW_SHOWDEFAULT);
        UpdateWindow(window);
        emit(window, JSTI_EVENT_READY);
        if (!RegisterHotKey(window, hotkeyID, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_SPACE)) {
            showFailure(window, "Ctrl+Alt+Space is unavailable. Another app may own it; use Record in this window.");
        }
        MSG message{};
        BOOL result;
        while ((result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
            if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
        }
        if (result < 0) {
            outcome = jsti::fail(jsti::systemError("Reading desktop messages"), error, capacity);
            DestroyWindow(window);
        }
    }
    if (state.font) { DeleteObject(state.font); state.font = nullptr; }
    state.controls.clear(); state.callback = nullptr; state.context = nullptr;
    if (registered) UnregisterClassW(type.lpszClassName, instance);
    { std::lock_guard<std::mutex> lock(state.mutex); state.running = false; state.window = nullptr; }
    return outcome;
}

int jsti_window_update(const char *status, const char *transcript, int recording) {
    std::wstring wideStatus, wideTranscript;
    if ((status && !jsti::wide(status, wideStatus)) || (transcript && !jsti::wide(transcript, wideTranscript)) ||
        recording < -1 || recording > 2) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.window) return -1;
    if (status) { state.status = std::move(wideStatus); state.statusChanged = true; }
    if (transcript) { state.transcript = std::move(wideTranscript); state.transcriptChanged = true; }
    if (recording >= 0) state.recording = recording;
    if (!state.posted) {
        state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
        if (!state.posted) return -1;
    }
    return 0;
}

void jsti_window_request_close(void) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.window) PostMessageW(state.window, WM_CLOSE, 0, 0);
}
