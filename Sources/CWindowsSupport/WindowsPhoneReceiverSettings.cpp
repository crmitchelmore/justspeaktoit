#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include "WindowsWindowInternal.hpp"
#include <atomic>
#include <mutex>
#include <vector>

// The Send from phone dialog (F46): turn receiving on, read the pairing code,
// make a new one and forget paired phones. Unlike the other settings dialogs
// it stays open after each action: the host answers every change with a new
// snapshot, which an open dialog shows at once. Actions call back on the UI
// thread with the callback current at that moment, so a cleared host is never
// called.

namespace {
enum Control { enableID = 1000, statusID, codeID, newCodeID, devicesLabelID, devicesID, forgetID, noteID };
constexpr UINT refreshMessage = WM_APP + 41;
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 560, minimumClientHeight = 420;

struct Configuration {
    std::wstring status, code;
    bool available = false, enabled = false;
    std::vector<std::string> deviceIDs;
    std::vector<std::wstring> deviceNames;
    JSTIPhoneReceiverCallback callback = nullptr;
    void *context = nullptr;
};
std::mutex configurationMutex;
Configuration configuration;
// The open dialog, which a new snapshot refreshes. Only the UI thread sets it;
// hosts read it from any thread to post a refresh.
std::atomic<HWND> openDialog{nullptr};

struct Dialog {
    Configuration config;
    HFONT font = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
};

using jsti::chrome::scale;

Configuration snapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), button = at(32), gap = at(10), width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(enableID, margin, at(14), width, at(26));
    move(statusID, margin, at(46), width, at(44));
    const int codeButton = std::min(at(190), width / 2);
    move(codeID, margin, at(98), width - codeButton - gap, at(30));
    move(newCodeID, margin + width - codeButton, at(96), codeButton, button);
    move(devicesLabelID, margin, at(140), width, at(22));
    const int bottom = static_cast<int>(bounds.bottom) - margin - button;
    const int noteTop = bottom - gap - at(52);
    move(noteID, margin, noteTop, width, at(52));
    move(devicesID, margin, at(164), width, std::max(at(48), noteTop - gap - at(164)));
    const int buttonWidth = std::min(at(160), (width - gap) / 2);
    move(forgetID, margin, bottom, buttonWidth, button);
    move(IDCANCEL, margin + width - buttonWidth, bottom, buttonWidth, button);
}

void refreshFont(HWND window, Dialog &dialog) { jsti::chrome::refreshDialogFont(window, dialog.controls, dialog.font); }

std::wstring codeText(const Configuration &config) {
    if (!config.enabled || config.code.size() != 6) return L"Pairing code: shown once receiving is on";
    return L"Pairing code: " + config.code.substr(0, 3) + L" " + config.code.substr(3);
}

void updateEnabled(HWND window, const Dialog &dialog) {
    const bool usable = dialog.config.available;
    const bool selected = SendDlgItemMessageW(window, devicesID, LB_GETCURSEL, 0, 0) != LB_ERR;
    EnableWindow(GetDlgItem(window, enableID), usable);
    EnableWindow(GetDlgItem(window, newCodeID), usable && dialog.config.enabled);
    EnableWindow(GetDlgItem(window, devicesID), usable && !dialog.config.deviceIDs.empty());
    EnableWindow(GetDlgItem(window, forgetID), usable && selected);
    // Keep focus on something the user can act on when its control turns off.
    const HWND focused = GetFocus();
    if (focused && GetParent(focused) == window && !IsWindowEnabled(focused)) {
        SetFocus(GetDlgItem(window, usable ? enableID : IDCANCEL));
    }
}

// Shows `dialog.config`, keeping the selected phone while it is still paired.
void show(HWND window, Dialog &dialog) {
    SendDlgItemMessageW(window, enableID, BM_SETCHECK, dialog.config.enabled ? BST_CHECKED : BST_UNCHECKED, 0);
    SetDlgItemTextW(window, statusID, dialog.config.status.c_str());
    SetDlgItemTextW(window, codeID, codeText(dialog.config).c_str());
    const HWND list = GetDlgItem(window, devicesID);
    std::string selectedID;
    const LRESULT selected = SendMessageW(list, LB_GETCURSEL, 0, 0);
    if (selected != LB_ERR) {
        const LRESULT index = SendMessageW(list, LB_GETITEMDATA, static_cast<WPARAM>(selected), 0);
        if (index >= 0 && static_cast<size_t>(index) < dialog.config.deviceIDs.size()) {
            selectedID = dialog.config.deviceIDs[static_cast<size_t>(index)];
        }
    }
    SendMessageW(list, WM_SETREDRAW, FALSE, 0);
    SendMessageW(list, LB_RESETCONTENT, 0, 0);
    if (dialog.config.deviceNames.empty()) {
        // An entry rather than an empty, silent list.
        SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"No phones paired yet"));
        SendMessageW(list, LB_SETITEMDATA, 0, static_cast<LPARAM>(-1));
    }
    for (size_t index = 0; index < dialog.config.deviceNames.size(); ++index) {
        const LRESULT row = SendMessageW(list, LB_ADDSTRING, 0,
                                         reinterpret_cast<LPARAM>(dialog.config.deviceNames[index].c_str()));
        if (row >= 0) SendMessageW(list, LB_SETITEMDATA, static_cast<WPARAM>(row), static_cast<LPARAM>(index));
    }
    // Restoring the selection is safe only while the list has focus; elsewhere
    // the proxy would announce it as a focus change.
    if (!selectedID.empty() && GetFocus() == list) {
        for (size_t index = 0; index < dialog.config.deviceIDs.size(); ++index) {
            if (dialog.config.deviceIDs[index] == selectedID) {
                SendMessageW(list, LB_SETCURSEL, index, 0);
                break;
            }
        }
    }
    SendMessageW(list, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(list, nullptr, TRUE);
    updateEnabled(window, dialog);
}

bool createControls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id, DWORD exStyle = 0) {
        HWND control = CreateWindowExW(exStyle, kind, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool okay =
        add(L"BUTTON", L"&Receive transcripts from a phone", BS_AUTOCHECKBOX | WS_TABSTOP | WS_GROUP, enableID) &&
        add(L"STATIC", L"", SS_LEFT | SS_NOPREFIX, statusID) &&
        add(L"STATIC", L"", SS_LEFT | SS_NOPREFIX | SS_CENTERIMAGE, codeID) &&
        add(L"BUTTON", L"&New pairing code", BS_PUSHBUTTON | WS_TABSTOP, newCodeID) &&
        add(L"STATIC", L"&Paired phones", SS_LEFT, devicesLabelID) &&
        add(L"LISTBOX", L"", LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | WS_VSCROLL | WS_TABSTOP, devicesID,
            WS_EX_CLIENTEDGE) &&
        add(L"BUTTON", L"&Forget phone", BS_PUSHBUTTON | WS_TABSTOP, forgetID) &&
        add(L"STATIC", L"On the iPhone or iPad, open Send to Mac in Just Speak to It's settings, choose this "
            L"computer and enter the code. Windows may ask to let Just Speak to It through the firewall; allow "
            L"private networks.", SS_LEFT, noteID) &&
        add(L"BUTTON", L"Close", BS_DEFPUSHBUTTON | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    refreshFont(window, dialog);
    layout(window);
    show(window, dialog);
    return true;
}

void forget(HWND window) {
    HWND expected = window;
    openDialog.compare_exchange_strong(expected, nullptr);
}

void close(HWND window) {
    forget(window);
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

// Calls the host with the callback current now, not the one the dialog opened with.
void act(int action, int value, const char *deviceID) {
    const Configuration current = snapshot();
    if (current.callback) current.callback(action, value, deviceID, current.context);
}

void forgetSelected(HWND window, const Dialog &dialog) {
    const LRESULT selected = SendDlgItemMessageW(window, devicesID, LB_GETCURSEL, 0, 0);
    if (selected == LB_ERR) return;
    const LRESULT index = SendDlgItemMessageW(window, devicesID, LB_GETITEMDATA, static_cast<WPARAM>(selected), 0);
    if (index < 0 || static_cast<size_t>(index) >= dialog.config.deviceIDs.size()) return;
    const std::string deviceID = dialog.config.deviceIDs[static_cast<size_t>(index)];
    SetFocus(GetDlgItem(window, devicesID));
    act(JSTI_PHONE_RECEIVER_FORGET, 0, deviceID.c_str());
}

constexpr jsti::chrome::DialogFrame dialogFrame{
    minimumClientWidth, minimumClientHeight, windowStyle, windowExStyle, enableID, IDCANCEL};

bool handle(HWND window, Dialog &dialog, UINT message, WPARAM wparam, LPARAM, LRESULT &) {
    switch (message) {
    case refreshMessage: {
        const std::wstring previous = dialog.config.status;
        dialog.config = snapshot();
        show(window, dialog);
        if (dialog.config.status != previous && !dialog.config.status.empty() && GetForegroundWindow() == window) {
            jsti::accessibility::announce(window, dialog.config.status, false);
        }
        return true;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == devicesID && HIWORD(wparam) == LBN_SELCHANGE) {
            updateEnabled(window, dialog);
            return true;
        }
        if (HIWORD(wparam) != BN_CLICKED) return false;
        switch (LOWORD(wparam)) {
        case enableID:
            act(JSTI_PHONE_RECEIVER_ENABLE,
                SendDlgItemMessageW(window, enableID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0, nullptr);
            return true;
        case newCodeID: act(JSTI_PHONE_RECEIVER_NEW_CODE, 0, nullptr); return true;
        case forgetID: forgetSelected(window, dialog); return true;
        case IDCANCEL: close(window); return true;
        default: return true;
        }
    case WM_DESTROY: forget(window); return false;
    }
    return false;
}

const jsti::chrome::DialogProcedure<Dialog> dialogParts{dialogFrame, layout, refreshFont, createControls, close, handle};

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    return jsti::chrome::dialogProcedure(dialogParts, window, message, wparam, lparam);
}

HWND createDialog(HWND owner, Dialog &dialog) {
    return jsti::chrome::createOwnedDialog(owner, L"JustSpeakToItPhoneReceiver", procedure,
        L"Send from phone — Just Speak to It", 600, 440, windowStyle, windowExStyle, &dialog);
}

void refreshOpenDialog() {
    // PostMessageW is safe from any thread; a closed dialog's handle is
    // refused or, if reused, ignored by a window that does not know the message.
    if (HWND window = openDialog.load()) PostMessageW(window, refreshMessage, 0, 0);
}
} // namespace

bool jsti_phone_receiver_available() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration.callback != nullptr;
}

void jsti_show_phone_receiver_settings(HWND owner) {
    Dialog dialog;
    dialog.config = snapshot();
    if (!dialog.config.callback) return;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening Send from phone settings").c_str(), nullptr, -1);
        return;
    }
    openDialog = window;
    // A snapshot that arrived between the copy above and now.
    PostMessageW(window, refreshMessage, 0, 0);
    jsti::chrome::runModalDialog(owner, window, enableID, close, "Send from phone");
    forget(window);
}

int jsti_window_set_phone_receiver(const JSTIPhoneReceiverView *view, JSTIPhoneReceiverCallback callback,
                                   void *context) {
    if (!view || !callback || view->device_count < 0 || view->device_count > 256 ||
        (view->device_count > 0 && (!view->device_ids || !view->device_names))) return -1;
    try {
        Configuration updated;
        if (view->status && !jsti::wide(view->status, updated.status)) return -1;
        if (updated.status.size() > 1024) updated.status.resize(1024);
        if (view->pairing_code && !jsti::wide(view->pairing_code, updated.code)) return -1;
        if (updated.code.size() > 16) return -1;
        updated.available = view->available != 0;
        updated.enabled = view->enabled != 0;
        for (int32_t index = 0; index < view->device_count; ++index) {
            const char *id = view->device_ids[index];
            const char *name = view->device_names[index];
            std::wstring wideName;
            if (!id || !*id || !name || !jsti::wide(name, wideName)) return -1;
            if (wideName.size() > 256) wideName.resize(256);
            updated.deviceIDs.emplace_back(id);
            updated.deviceNames.push_back(std::move(wideName));
        }
        updated.callback = callback;
        updated.context = context;
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(updated);
    } catch (const std::exception &) { return -1; }
    refreshOpenDialog();
    jsti_window_update(nullptr, nullptr, -1);
    return 0;
}

void jsti_window_clear_phone_receiver(void) {
    { std::lock_guard<std::mutex> lock(configurationMutex); configuration = Configuration(); }
    if (HWND window = openDialog.load()) PostMessageW(window, WM_CLOSE, 0, 0);
    jsti_window_update(nullptr, nullptr, -1);
}

// ---- self-test -------------------------------------------------------------

namespace {
struct Acted { int calls = 0, action = 0, value = -1; std::string device; };
void recordAction(int action, int value, const char *deviceID, void *context) {
    auto &acted = *static_cast<Acted *>(context);
    ++acted.calls;
    acted.action = action;
    acted.value = value;
    acted.device = deviceID ? deviceID : "";
}

std::wstring controlText(HWND window, int id) {
    std::wstring text(static_cast<size_t>(GetWindowTextLengthW(GetDlgItem(window, id))) + 1, L'\0');
    GetDlgItemTextW(window, id, &text[0], static_cast<int>(text.size()));
    text.resize(wcslen(text.c_str()));
    return text;
}

// Drives a fixture dialog: the code and phones shown, every action reaching
// the host with the right values, a new snapshot shown live, and the audit.
bool exerciseDialog(HWND owner, Acted &acted, std::string &error) {
    Dialog dialog;
    dialog.config = snapshot();
    HWND window = createDialog(owner, dialog);
    if (!window) {
        error = jsti::systemError("Creating the Send from phone fixture");
        return false;
    }
    std::string audit;
    const bool audited = jsti::accessibility::audit(window, audit) > 0;
    const bool shown = controlText(window, codeID) == L"Pairing code: 123 456" &&
        SendDlgItemMessageW(window, devicesID, LB_GETCOUNT, 0, 0) == 2 &&
        IsWindowEnabled(GetDlgItem(window, newCodeID)) && !IsWindowEnabled(GetDlgItem(window, forgetID));
    SendDlgItemMessageW(window, devicesID, LB_SETCURSEL, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(devicesID, LBN_SELCHANGE), 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(forgetID, BN_CLICKED), 0);
    const bool forgot = acted.calls == 1 && acted.action == JSTI_PHONE_RECEIVER_FORGET && acted.device == "device-b";
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(newCodeID, BN_CLICKED), 0);
    const bool renewed = acted.calls == 2 && acted.action == JSTI_PHONE_RECEIVER_NEW_CODE;
    SendDlgItemMessageW(window, enableID, BM_SETCHECK, BST_UNCHECKED, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(enableID, BN_CLICKED), 0);
    const bool switched = acted.calls == 3 && acted.action == JSTI_PHONE_RECEIVER_ENABLE && acted.value == 0;
    JSTIPhoneReceiverView off{"Receiving is off.", "", 1, 0, 0, nullptr, nullptr};
    jsti_window_set_phone_receiver(&off, recordAction, &acted);
    SendMessageW(window, refreshMessage, 0, 0);
    const bool refreshed = controlText(window, statusID) == L"Receiving is off." &&
        SendDlgItemMessageW(window, devicesID, LB_GETCOUNT, 0, 0) == 1 &&
        !IsWindowEnabled(GetDlgItem(window, newCodeID)) && !IsWindowEnabled(GetDlgItem(window, forgetID)) &&
        SendDlgItemMessageW(window, enableID, BM_GETCHECK, 0, 0) == BST_UNCHECKED;
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
    const bool closed = !IsWindow(window) && acted.calls == 3;
    if (IsWindow(window)) DestroyWindow(window);
    if (!audited) error = audit.empty() ? "The Send from phone dialog has no focusable controls." : audit;
    else if (!shown) error = "The Send from phone dialog did not show the pairing code and paired phones.";
    else if (!forgot || !renewed || !switched) error = "The Send from phone dialog did not report its actions.";
    else if (!refreshed) error = "The Send from phone dialog did not show a new snapshot.";
    else if (!closed) error = "Closing the Send from phone dialog emitted an action.";
    return audited && shown && forgot && renewed && switched && refreshed && closed;
}
} // namespace

bool jsti_phone_receiver_settings_self_test(HWND owner, std::string &error) {
    const Configuration original = snapshot();
    Acted acted;
    bool passed = false;
    try {
        const char *ids[] = {"device-a", "device-b"};
        const char *names[] = {"Chris's iPhone", "iPad <b>"};
        JSTIPhoneReceiverView view{"Ready for phones. Paired: 2.", "123456", 1, 1, 2, ids, names};
        JSTIPhoneReceiverView missing{"Ready.", "123456", 1, 1, 2, nullptr, nullptr};
        if (jsti_window_set_phone_receiver(nullptr, recordAction, &acted) != -1 ||
            jsti_window_set_phone_receiver(&view, nullptr, &acted) != -1 ||
            jsti_window_set_phone_receiver(&missing, recordAction, &acted) != -1 ||
            jsti_window_set_phone_receiver(&view, recordAction, &acted) != 0 || !jsti_phone_receiver_available()) {
            error = "Send from phone configuration accepted an invalid view or refused a valid one.";
        } else {
            passed = exerciseDialog(owner, acted, error);
        }
        if (passed) {
            jsti_window_clear_phone_receiver();
            if (jsti_phone_receiver_available()) {
                passed = false;
                error = "Clearing Send from phone left its host attached.";
            }
        }
    } catch (const std::exception &) { error = "The Send from phone self-test could not allocate its fixtures."; }
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = original;
    }
    jsti_window_update(nullptr, nullptr, -1);
    return passed;
}
