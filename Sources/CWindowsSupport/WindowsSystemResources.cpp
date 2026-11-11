// General > App behaviour > "System resources in use" (issue #1473): what
// the app holds now (microphone, audio output, connections, background work,
// the dictation shortcut) with release buttons, and what Windows reports about
// the microphone. The host publishes through jsti_window_set_system_resources
// whether or not the window is open; the window shows the latest view.
#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <mutex>
#include <string>
#include <vector>

int32_t jsti_owned_window_save_snapshot(HWND window, const char *path, char *error, size_t capacity);

namespace {
enum { headlineID = 1001, warningID, listLabelID, listID, detailID, microphoneID, releaseID, releaseAllID };
constexpr UINT refreshMessage = WM_APP + 41;
constexpr int32_t maximumRows = 64;
constexpr size_t maximumText = 4096;

struct Row { std::string id; std::wstring title, reason, caption, releaseTitle; bool releasing = false; };
struct View {
    std::wstring headline = L"Nothing is in use.", warning, empty = L"Just Speak to It isn't holding anything.",
        microphone;
    std::vector<Row> rows;
    bool canReleaseEverything = false;
};

std::mutex viewMutex;
View latest;
HWND active = nullptr;

using Emit = void (*)(HWND owner, int event, const char *text);
struct Dialog {
    HWND owner = nullptr;
    Emit emit = nullptr;
    HFONT font = nullptr;
    View shown;
};

bool copy(const char *text, std::wstring &result, bool optional = false) {
    if (!text) { result.clear(); return optional; }
    return strlen(text) <= maximumText && jsti::wide(text, result);
}

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void layout(HWND window, const Dialog &dialog) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int margin = scale(window, 20), width = bounds.right - 2 * margin, row = scale(window, 34);
    const int gap = scale(window, 8);
    int y = margin;
    MoveWindow(GetDlgItem(window, headlineID), margin, y, width, scale(window, 24), TRUE);
    y += scale(window, 24) + gap;
    const bool warning = !dialog.shown.warning.empty();
    ShowWindow(GetDlgItem(window, warningID), warning ? SW_SHOW : SW_HIDE);
    if (warning) {
        MoveWindow(GetDlgItem(window, warningID), margin, y, width, scale(window, 44), TRUE);
        y += scale(window, 44) + gap;
    }
    MoveWindow(GetDlgItem(window, listLabelID), margin, y, width, scale(window, 20), TRUE);
    y += scale(window, 22);
    const int buttons = bounds.bottom - margin - row;
    const int microphone = buttons - gap - scale(window, 40);
    const int detail = microphone - gap - scale(window, 44);
    MoveWindow(GetDlgItem(window, listID), margin, y, width, detail - gap - y, TRUE);
    MoveWindow(GetDlgItem(window, detailID), margin, detail, width, scale(window, 44), TRUE);
    MoveWindow(GetDlgItem(window, microphoneID), margin, microphone, width, scale(window, 40), TRUE);
    MoveWindow(GetDlgItem(window, releaseID), margin, buttons, scale(window, 180), row, TRUE);
    MoveWindow(GetDlgItem(window, releaseAllID), margin + scale(window, 188), buttons, scale(window, 180), row, TRUE);
    MoveWindow(GetDlgItem(window, IDCANCEL), bounds.right - margin - scale(window, 120), buttons,
        scale(window, 120), row, TRUE);
}

void font(HWND window, Dialog &dialog) {
    HFONT next = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!next) return;
    const int ids[] = {headlineID, warningID, listLabelID, listID, detailID, microphoneID, releaseID, releaseAllID,
                       IDCANCEL};
    for (int id : ids) SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(next), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = next;
}

int selectedRow(HWND window, const Dialog &dialog) {
    const LRESULT index = SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0);
    return index >= 0 && static_cast<size_t>(index) < dialog.shown.rows.size() ? static_cast<int>(index) : -1;
}

// The selected row's reason, and its release button. Rows without a release
// (the dictation shortcut) keep a disabled, generic button.
void selectionChanged(HWND window, const Dialog &dialog) {
    const int index = selectedRow(window, dialog);
    if (index < 0) {
        SetDlgItemTextW(window, detailID, dialog.shown.rows.empty() ? dialog.shown.empty.c_str()
                                                                    : L"Select a resource to see why it is held.");
        SetDlgItemTextW(window, releaseID, L"&Release");
        EnableWindow(GetDlgItem(window, releaseID), FALSE);
        return;
    }
    const Row &row = dialog.shown.rows[static_cast<size_t>(index)];
    SetDlgItemTextW(window, detailID, row.reason.c_str());
    const bool releasable = !row.releaseTitle.empty();
    SetDlgItemTextW(window, releaseID, releasable ? (L"&" + row.releaseTitle).c_str() : L"&Release");
    EnableWindow(GetDlgItem(window, releaseID), releasable && !row.releasing);
}

void refresh(HWND window, Dialog &dialog) {
    std::string selected;
    if (const int index = selectedRow(window, dialog); index >= 0)
        selected = dialog.shown.rows[static_cast<size_t>(index)].id;
    {
        std::lock_guard<std::mutex> lock(viewMutex);
        dialog.shown = latest;
    }
    SetDlgItemTextW(window, headlineID, dialog.shown.headline.c_str());
    SetDlgItemTextW(window, warningID, dialog.shown.warning.c_str());
    SetDlgItemTextW(window, microphoneID, dialog.shown.microphone.c_str());
    HWND list = GetDlgItem(window, listID);
    SendMessageW(list, WM_SETREDRAW, FALSE, 0);
    SendMessageW(list, LB_RESETCONTENT, 0, 0);
    int reselect = -1;
    for (size_t index = 0; index < dialog.shown.rows.size(); ++index) {
        const Row &row = dialog.shown.rows[index];
        const std::wstring text = row.caption.empty() ? row.title : row.title + L" \u2014 " + row.caption;
        SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(text.c_str()));
        if (row.id == selected) reselect = static_cast<int>(index);
    }
    if (reselect < 0 && !dialog.shown.rows.empty()) reselect = 0;
    SendMessageW(list, LB_SETCURSEL, reselect, 0);
    SendMessageW(list, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(list, nullptr, TRUE);
    EnableWindow(list, !dialog.shown.rows.empty());
    EnableWindow(GetDlgItem(window, releaseAllID), dialog.shown.canReleaseEverything);
    selectionChanged(window, dialog);
    layout(window, dialog);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    LRESULT themed = 0;
    if (jsti::chrome::dialogMessage(window, message, wparam, lparam, themed)) return themed;
    switch (message) {
    case WM_CREATE: {
        auto add = [&](const wchar_t *type, const wchar_t *text, DWORD style, int id, DWORD extended = 0) {
            return CreateWindowExW(extended, type, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 1, 1, window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
        };
        // The list's label comes right before it, so UI Automation names the list.
        if (!add(L"STATIC", L"", SS_NOPREFIX, headlineID) ||
            !add(L"STATIC", L"", SS_NOPREFIX, warningID) ||
            !add(L"STATIC", L"Resources &held", 0, listLabelID) ||
            !add(L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP, listID,
                 WS_EX_CLIENTEDGE) ||
            !add(L"STATIC", L"", SS_NOPREFIX, detailID) ||
            !add(L"STATIC", L"", SS_NOPREFIX, microphoneID) ||
            !add(L"BUTTON", L"&Release", BS_PUSHBUTTON | WS_TABSTOP, releaseID) ||
            !add(L"BUTTON", L"Release &everything", BS_PUSHBUTTON | WS_TABSTOP, releaseAllID) ||
            !add(L"BUTTON", L"Close", BS_DEFPUSHBUTTON | WS_TABSTOP, IDCANCEL)) return -1;
        font(window, *dialog);
        {
            std::lock_guard<std::mutex> lock(viewMutex);
            active = window;
        }
        refresh(window, *dialog);
        return 0;
    }
    case refreshMessage: refresh(window, *dialog); return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) == listID && HIWORD(wparam) == LBN_SELCHANGE) { selectionChanged(window, *dialog); return 0; }
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; }
        if (LOWORD(wparam) == releaseID) {
            const int index = selectedRow(window, *dialog);
            if (index < 0 || !IsWindowEnabled(GetDlgItem(window, releaseID))) return 0;
            // Disabled until the host's next view reports the release.
            EnableWindow(GetDlgItem(window, releaseID), FALSE);
            dialog->emit(dialog->owner, JSTI_EVENT_SYSTEM_RESOURCE_RELEASE,
                         dialog->shown.rows[static_cast<size_t>(index)].id.c_str());
            return 0;
        }
        if (LOWORD(wparam) == releaseAllID && IsWindowEnabled(GetDlgItem(window, releaseAllID))) {
            EnableWindow(GetDlgItem(window, releaseAllID), FALSE);
            dialog->emit(dialog->owner, JSTI_EVENT_SYSTEM_RESOURCES_RELEASE_ALL, "");
            return 0;
        }
        break;
    case WM_SIZE: layout(window, *dialog); return 0;
    case WM_GETMINMAXINFO: {
        RECT size{0, 0, scale(window, 560), scale(window, 440)};
        AdjustWindowRectExForDpi(&size, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(window));
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {size.right - size.left, size.bottom - size.top};
        return 0;
    }
    case WM_DPICHANGED: {
        const auto bounds = reinterpret_cast<const RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        font(window, *dialog); layout(window, *dialog); return 0;
    }
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY: {
        std::lock_guard<std::mutex> lock(viewMutex);
        if (active == window) active = nullptr;
    }
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

HWND makeDialog(HWND owner, Dialog &dialog) {
    WNDCLASSW type{};
    type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItSystemResources"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT bounds{0, 0, scale(owner, 620), scale(owner, 500)};
    AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(owner));
    return CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName, L"System resources in use — Just Speak to It",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left, bounds.bottom - bounds.top,
        owner, nullptr, type.hInstance, &dialog);
}

struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~Apartment() { if (SUCCEEDED(result)) CoUninitialize(); }
    bool available() const { return SUCCEEDED(result) || result == RPC_E_CHANGED_MODE; }
};

// 1 when one of this process's sessions on `device` is active, 0 when none
// is, -1 when Windows would not say.
int deviceCapturing(IMMDevice *device, DWORD process) {
    jsti::COM<IAudioSessionManager2> manager;
    if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void **>(&manager.value)))) return -1;
    jsti::COM<IAudioSessionEnumerator> sessions;
    if (FAILED(manager->GetSessionEnumerator(&sessions.value))) return -1;
    int count = 0;
    if (FAILED(sessions->GetCount(&count))) return -1;
    int result = 0;
    for (int index = 0; index < count; ++index) {
        jsti::COM<IAudioSessionControl> control;
        if (FAILED(sessions->GetSession(index, &control.value))) { result = -1; continue; }
        jsti::COM<IAudioSessionControl2> extended;
        if (FAILED(control->QueryInterface(__uuidof(IAudioSessionControl2),
                                           reinterpret_cast<void **>(&extended.value)))) { result = -1; continue; }
        DWORD owner = 0;
        // A multi-process session reports AUDCLNT_S_NO_SINGLE_PROCESS; it is not ours alone.
        if (extended->GetProcessId(&owner) != S_OK || owner != process) continue;
        AudioSessionState state = AudioSessionStateInactive;
        if (FAILED(control->GetState(&state))) { result = -1; continue; }
        if (state == AudioSessionStateActive) return 1;
    }
    return result;
}

struct FixtureEvent { int event = 0; std::string text; int calls = 0; };
FixtureEvent *fixtureEvent = nullptr;
} // namespace

int32_t jsti_window_set_system_resources(const JSTISystemResourcesView *view) {
    if (!view || view->row_count < 0 || view->row_count > maximumRows || (view->row_count && !view->rows))
        return -1;
    View next;
    if (!copy(view->headline, next.headline) || !copy(view->warning, next.warning, true) ||
        !copy(view->empty, next.empty) || !copy(view->microphone, next.microphone)) return -1;
    next.canReleaseEverything = view->can_release_everything != 0;
    for (int32_t index = 0; index < view->row_count; ++index) {
        const JSTISystemResourceRow &source = view->rows[index];
        Row row;
        if (!source.id || !source.id[0] || strlen(source.id) > maximumText || !copy(source.title, row.title) ||
            !copy(source.reason, row.reason) || !copy(source.caption, row.caption) ||
            !copy(source.release_title, row.releaseTitle, true)) return -1;
        row.id = source.id;
        row.releasing = source.releasing != 0;
        next.rows.push_back(std::move(row));
    }
    std::lock_guard<std::mutex> lock(viewMutex);
    latest = std::move(next);
    if (active) PostMessageW(active, refreshMessage, 0, 0);
    return 0;
}

int32_t jsti_audio_process_capturing(void) {
    try {
        Apartment apartment;
        if (!apartment.available()) return -1;
        jsti::COM<IMMDeviceEnumerator> enumerator;
        if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator.value)))) return -1;
        jsti::COM<IMMDeviceCollection> devices;
        if (FAILED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &devices.value))) return -1;
        UINT count = 0;
        if (FAILED(devices->GetCount(&count))) return -1;
        const DWORD process = GetCurrentProcessId();
        int result = 0;
        for (UINT index = 0; index < count; ++index) {
            jsti::COM<IMMDevice> device;
            if (FAILED(devices->Item(index, &device.value))) { result = -1; continue; }
            const int capturing = deviceCapturing(device.value, process);
            if (capturing == 1) return 1;
            if (capturing < 0) result = -1;
        }
        return result;
    } catch (...) {
        return -1;
    }
}

void jsti_show_system_resources(HWND owner, Emit emit) {
    {
        std::lock_guard<std::mutex> lock(viewMutex);
        if (active) { SetForegroundWindow(active); return; }
    }
    Dialog dialog{owner, emit};
    HWND window = makeDialog(owner, dialog);
    if (!window) { jsti_window_update("System resources in use could not be opened.", nullptr, -1); return; }
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, listID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) jsti_window_update("Reading System resources in use messages failed.", nullptr, -1);
}

bool jsti_system_resources_self_test(HWND owner, std::string &error) {
    View original;
    { std::lock_guard<std::mutex> lock(viewMutex); original = latest; }
    FixtureEvent observed;
    fixtureEvent = &observed;
    Dialog dialog{owner, [](HWND, int event, const char *text) {
        if (!fixtureEvent) return;
        fixtureEvent->event = event; fixtureEvent->text = text ? text : ""; ++fixtureEvent->calls;
    }};
    HWND window = makeDialog(owner, dialog);
    if (!window) { fixtureEvent = nullptr; error = "System resources fixture could not open."; return false; }
    auto drain = [&] {
        MSG message{};
        while (PeekMessageW(&message, window, refreshMessage, refreshMessage, PM_REMOVE)) DispatchMessageW(&message);
    };
    auto enabled = [&](int id) { return IsWindowEnabled(GetDlgItem(window, id)) != FALSE; };
    // The fixture window stays hidden, so IsWindowVisible is false for every
    // child; the style bit says whether layout shows it.
    auto shown = [](HWND control) { return (GetWindowLongPtrW(control, GWL_STYLE) & WS_VISIBLE) != 0; };
    // BM_CLICK can fail on an inactive window; deliver the click's command.
    auto click = [&](int id) {
        SendMessageW(window, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED),
                     reinterpret_cast<LPARAM>(GetDlgItem(window, id)));
    };
    auto text = [&](int id) {
        wchar_t buffer[512]{}; GetDlgItemTextW(window, id, buffer, 512); return std::wstring(buffer);
    };
    const JSTISystemResourceRow rows[] = {
        {"playback", "Audio output", "Plays a History recording.", "Since 10:00", "Stop playback", 0},
        {"hotKey", "Dictation hotkey", "Listens for your hotkey. Nothing is recorded.", "Ctrl+Alt+Space", nullptr, 0},
    };
    JSTISystemResourcesView view{"2 resources in use.", "Windows reports the microphone is open, but nothing in "
        "Just Speak to It claims it.", "Just Speak to It isn't holding anything.",
        "Windows: this app is recording from a microphone.", rows, 2, 1};
    // Records the first failed step, so a CI failure names it.
    std::string step;
    auto check = [&](bool ok, const char *name) {
        if (!ok && step.empty()) step = name;
        return ok;
    };
    bool passed = check(jsti_window_set_system_resources(nullptr) == -1, "a null view was accepted");
    JSTISystemResourcesView invalid = view;
    invalid.row_count = maximumRows + 1;
    passed = check(jsti_window_set_system_resources(&invalid) == -1, "too many rows were accepted") && passed;
    passed = check(jsti_window_set_system_resources(&view) == 0, "a valid view was refused") && passed;
    drain();
    passed = check(SendDlgItemMessageW(window, listID, LB_GETCOUNT, 0, 0) == 2 &&
        text(headlineID) == L"2 resources in use." && shown(GetDlgItem(window, warningID)),
        "the rows, headline or warning were not shown") && passed;
    passed = check(enabled(releaseID) && text(releaseID) == L"&Stop playback" && enabled(releaseAllID),
        "the first row's release buttons were not offered") && passed;
    click(releaseID);
    passed = check(observed.calls == 1 && observed.event == JSTI_EVENT_SYSTEM_RESOURCE_RELEASE &&
        observed.text == "playback" && !enabled(releaseID), "Release did not report the selected row once") && passed;
    // A hold without a release (the shortcut) keeps its button disabled.
    SendDlgItemMessageW(window, listID, LB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(listID, LBN_SELCHANGE),
                 reinterpret_cast<LPARAM>(GetDlgItem(window, listID)));
    passed = check(!enabled(releaseID) && text(detailID) == L"Listens for your hotkey. Nothing is recorded.",
        "a row without a release offered one, or did not show its reason") && passed;
    // A refresh keeps the selected row by id.
    passed = jsti_window_set_system_resources(&view) == 0 && passed;
    drain();
    passed = check(SendDlgItemMessageW(window, listID, LB_GETCURSEL, 0, 0) == 1,
        "a refresh lost the selected row") && passed;
    click(releaseAllID);
    passed = check(observed.calls == 2 && observed.event == JSTI_EVENT_SYSTEM_RESOURCES_RELEASE_ALL,
        "Release everything was not reported") && passed;
    JSTISystemResourcesView empty{"Nothing is in use.", nullptr, "Just Speak to It isn't holding anything.",
        "Windows: no microphone is in use by this app.", nullptr, 0, 0};
    passed = jsti_window_set_system_resources(&empty) == 0 && passed;
    drain();
    passed = check(SendDlgItemMessageW(window, listID, LB_GETCOUNT, 0, 0) == 0 &&
        !shown(GetDlgItem(window, warningID)) && !enabled(releaseID) && !enabled(releaseAllID) &&
        text(detailID) == L"Just Speak to It isn't holding anything.", "the empty state was wrong") && passed;
    passed = jsti_window_set_system_resources(&view) == 0 && passed;
    drain();
    auto fits = [&] {
        RECT client{}; GetClientRect(window, &client);
        for (HWND child = GetWindow(window, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
            if (!shown(child)) continue;
            RECT bounds{}; GetWindowRect(child, &bounds);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
            if (bounds.left < 0 || bounds.top < 0 || bounds.right > client.right || bounds.bottom > client.bottom)
                return false;
        }
        return true;
    };
    passed = check(fits(), "a control fell outside the window") && passed;
    RECT originalBounds{}; GetWindowRect(window, &originalBounds);
    MINMAXINFO minimum{}; SendMessageW(window, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&minimum));
    SetWindowPos(window, nullptr, 0, 0, minimum.ptMinTrackSize.x, minimum.ptMinTrackSize.y, SWP_NOMOVE | SWP_NOZORDER);
    passed = check(fits(), "a control fell outside the window at its minimum size") && passed;
    SetWindowPos(window, nullptr, 0, 0, originalBounds.right - originalBounds.left,
        originalBounds.bottom - originalBounds.top, SWP_NOMOVE | SWP_NOZORDER);
    std::vector<wchar_t> path(32768, 0);
    const DWORD length = GetEnvironmentVariableW(L"JSTI_UI_SNAPSHOT_PATH", path.data(), static_cast<DWORD>(path.size()));
    if (length && length < path.size()) {
        char failure[1024]{}; ShowWindow(window, SW_SHOWNOACTIVATE);
        passed = jsti_owned_window_save_snapshot(window, (jsti::utf8(path.data()) + ".system-resources.bmp").c_str(),
            failure, sizeof(failure)) == 0 && passed;
        if (failure[0]) error = failure;
    }
    DestroyWindow(window);
    fixtureEvent = nullptr;
    const int probe = jsti_audio_process_capturing();
    passed = check(probe >= -1 && probe <= 1, "the microphone probe returned an unknown value") && passed;
    {
        std::lock_guard<std::mutex> lock(viewMutex);
        latest = std::move(original);
    }
    if (!passed && error.empty()) error = "System resources fixture failed: " + step + ".";
    return passed;
}
