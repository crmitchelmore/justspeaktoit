#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <vector>

// Native Voice output dialog: chooses the canonical voice that Read aloud uses.
// The host supplies the catalogue labels; the dialog returns an index.

namespace {
enum Control { introID = 900, voiceLabelID, voiceID, noteID };
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 500, minimumClientHeight = 300;

struct Configuration {
    std::vector<std::wstring> voices;
    int selected = 0;
    JSTIVoiceOutputCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex configurationMutex;
Configuration configuration;

struct Dialog {
    Configuration config;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    bool applied = false;
};

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), button = at(32), gap = at(10), buttonWidth = at(100);
    const int width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(introID, margin, at(16), width, at(44));
    move(voiceLabelID, margin, at(66), width, at(22));
    move(voiceID, margin, at(90), width, at(260));
    const int top = static_cast<int>(bounds.bottom) - margin - button;
    move(noteID, margin, at(130), width, std::max(at(44), top - gap - at(130)));
    move(IDOK, static_cast<int>(bounds.right) - margin - 2 * buttonWidth - gap, top, buttonWidth, button);
    move(IDCANCEL, static_cast<int>(bounds.right) - margin - buttonWidth, top, buttonWidth, button);
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

bool createControls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        HWND control = CreateWindowExW(0, kind, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay =
        add(L"STATIC", L"Read aloud speaks the displayed transcript of the selected recording with this voice.",
            SS_LEFT, introID) &&
        add(L"STATIC", L"&Voice", 0, voiceLabelID) &&
        add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP, voiceID) &&
        add(L"STATIC", L"Speech is synthesized by Deepgram: the transcript is sent to Deepgram with the Deepgram "
            L"API key saved in Windows Credential Manager. Long transcripts are spoken in parts.", SS_LEFT, noteID) &&
        add(L"BUTTON", L"&Apply", BS_DEFPUSHBUTTON | WS_GROUP | WS_TABSTOP, IDOK) &&
        add(L"BUTTON", L"Cancel", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    for (const auto &voice : dialog.config.voices) {
        const LRESULT added = SendDlgItemMessageW(window, voiceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(voice.c_str()));
        if (added == CB_ERR || added == CB_ERRSPACE) return false;
    }
    SendDlgItemMessageW(window, voiceID, CB_SETCURSEL, static_cast<WPARAM>(dialog.config.selected), 0);
    refreshFont(window, dialog);
    layout(window);
    return true;
}

void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

void apply(HWND window, Dialog &dialog) {
    if (dialog.applied) return;
    const int voice = static_cast<int>(SendDlgItemMessageW(window, voiceID, CB_GETCURSEL, 0, 0));
    if (voice < 0 || static_cast<size_t>(voice) >= dialog.config.voices.size()) return;
    dialog.applied = true;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration.selected = voice;
    }
    if (dialog.config.callback) dialog.config.callback(voice, dialog.config.context);
    close(window);
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
        SetFocus(dialog->focus && IsChild(window, dialog->focus) ? dialog->focus : GetDlgItem(window, voiceID));
        return 0;
    case DM_GETDEFID: return MAKELRESULT(IDOK, DC_HASDEFID);
    case WM_COMMAND:
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == IDOK) { apply(window, *dialog); return 0; }
        if (LOWORD(wparam) == IDCANCEL) { close(window); return 0; }
        return 0;
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
    type.lpszClassName = L"JustSpeakToItVoiceOutput";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT frame{0, 0, scale(owner, 520), scale(owner, 320)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(owner));
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    return CreateWindowExW(windowExStyle, type.lpszClassName, L"Voice output — Just Speak to It", windowStyle,
        bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), frame.right - frame.left,
        frame.bottom - frame.top, owner, nullptr, instance, &dialog);
}

Configuration snapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}
} // namespace

bool jsti_voice_output_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr && !configuration.voices.empty();
}

void jsti_show_voice_settings(HWND owner) {
    Dialog dialog;
    dialog.config = snapshot();
    if (!dialog.config.callback || dialog.config.voices.empty()) return;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening voice output settings").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, voiceID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) close(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading voice output messages").c_str(), nullptr, -1);
}

int jsti_window_set_voice_output(const char *const *voiceNames, size_t voiceCount, int selected,
                                 JSTIVoiceOutputCallback callback, void *context) {
    if (!callback || !voiceNames || !voiceCount || voiceCount > 1024 || selected < 0 ||
        static_cast<size_t>(selected) >= voiceCount) return -1;
    try {
        Configuration updated;
        for (size_t index = 0; index < voiceCount; ++index) {
            std::wstring name;
            if (!jsti::wide(voiceNames[index], name) || name.empty() || name.size() > 256) return -1;
            updated.voices.push_back(std::move(name));
        }
        updated.selected = selected;
        updated.callback = callback;
        updated.context = context;
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(updated);
    } catch (const std::exception &) { return -1; }
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

void jsti_window_clear_voice_output(void) {
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = Configuration(); }
    jsti_window_update(nullptr, nullptr, -1);
}

// ---- self-test -------------------------------------------------------------

namespace {
struct Applied { int calls = 0, voice = -1; };
void recordVoice(int voice, void *context) {
    auto &applied = *static_cast<Applied *>(context);
    ++applied.calls;
    applied.voice = voice;
}
} // namespace

// Configuration validation, Apply of a changed voice, and Cancel emitting nothing.
bool jsti_voice_settings_self_test(HWND owner, std::string &error) {
    const Configuration original = snapshot();
    Applied applied;
    bool passed = false;
    try {
        const char *voices[] = {"Alpha voice", "Beta voice", "Gamma voice"};
        if (jsti_window_set_voice_output(voices, 3, 3, recordVoice, &applied) != -1 ||
            jsti_window_set_voice_output(voices, 3, 0, nullptr, &applied) != -1 ||
            jsti_window_set_voice_output(voices, 3, 1, recordVoice, &applied) != 0 || !jsti_voice_output_available()) {
            error = "Voice output configuration accepted an invalid choice or rejected a valid one.";
        } else {
            Dialog dialog;
            dialog.config = snapshot();
            HWND window = createDialog(owner, dialog);
            if (!window) {
                error = jsti::systemError("Creating the voice output fixture");
            } else {
                const bool shown = SendDlgItemMessageW(window, voiceID, CB_GETCURSEL, 0, 0) == 1 &&
                    SendDlgItemMessageW(window, voiceID, CB_GETCOUNT, 0, 0) == 3;
                SendDlgItemMessageW(window, voiceID, CB_SETCURSEL, 2, 0);
                SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
                const bool closed = !IsWindow(window);
                if (IsWindow(window)) DestroyWindow(window);
                Dialog cancelled;
                cancelled.config = snapshot();
                HWND second = createDialog(owner, cancelled);
                const bool reopened = second && SendDlgItemMessageW(second, voiceID, CB_GETCURSEL, 0, 0) == 2;
                if (second) {
                    SendDlgItemMessageW(second, voiceID, CB_SETCURSEL, 0, 0);
                    SendMessageW(second, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
                    if (IsWindow(second)) DestroyWindow(second);
                }
                passed = shown && closed && reopened && applied.calls == 1 && applied.voice == 2;
                if (!passed) error = "The Voice output dialog did not show, apply or cancel its voice choice exactly once.";
            }
        }
    } catch (const std::exception &) { error = "The voice output self-test could not allocate its fixtures."; }
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = original;
    }
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
