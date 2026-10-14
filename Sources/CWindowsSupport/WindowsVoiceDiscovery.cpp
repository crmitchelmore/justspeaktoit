#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <objbase.h>
#include <cstring>
#include <cctype>
#include <vector>
#include <algorithm>

int32_t jsti_save_owned_window_snapshot(HWND window, const char *path, char *error, size_t capacity);
uint64_t jsti_voice_provider_generation();
bool jsti_voice_provider_enter(uint64_t generation);
void jsti_voice_provider_leave();
void jsti_show_voice_provider_credentials(HWND owner, uint64_t generation,
    const std::string &session, const std::string &epoch, const std::string &provider);

namespace {
enum { headingID = 990, voicesID, statusID, refreshID, chooseID, closeID, providerID = 1040, keyID = 185 };
constexpr UINT inventoryMessage = WM_APP + 28;
struct Inventory {
    uint64_t generation = 0;
    std::string token;
    std::vector<std::wstring> labels;
    std::vector<std::string> identifiers;
    std::wstring status;
    int selected = -1;
    bool loading = false;
};
struct Dialog {
    std::string token;
    JSTIVoiceSourceCallback callback;
    void *context;
    HFONT font = nullptr;
    Inventory shown;
    uint64_t generation = 0;
    bool modern = false, proposed = false, acknowledged = false, inventoryMatched = false, applying = false;
    std::string epoch, provider;
    std::vector<std::string> providers;
};
struct Providers {
    uint64_t generation = 0;
    std::string session, epoch;
    std::vector<std::string> ids;
    std::vector<std::wstring> labels;
    int selected = -1;
};
std::mutex mutex;
HWND active = nullptr;
std::string activeToken;
Inventory pending;
std::vector<Providers> pendingProviders;
bool activeModern = false;
std::string activeEpoch;
bool uuid(const char *value) {
    if (!value || strlen(value) != 36) return false;
    for (size_t index = 0; index < 36; ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (value[index] != '-') return false;
        } else if (!isxdigit(static_cast<unsigned char>(value[index]))) return false;
    }
    return true;
}
bool sameUUID(const std::string &first, const std::string &second) {
    return uuid(first.c_str()) && uuid(second.c_str()) && _stricmp(first.c_str(), second.c_str()) == 0;
}
std::string newUUID() {
    GUID identifier{}; wchar_t token[40]{};
    if (FAILED(CoCreateGuid(&identifier)) || !StringFromGUID2(identifier, token, 40)) return {};
    return jsti::utf8(std::wstring(token + 1, 36));
}
struct Admission {
    bool admitted;
    explicit Admission(const Dialog &dialog) :
        admitted(!dialog.modern || jsti_voice_provider_enter(dialog.generation)), guarded(dialog.modern && admitted) {}
    ~Admission() { if (guarded) jsti_voice_provider_leave(); }
    bool guarded;
};
void emit(Dialog &dialog, const char *path, const std::string &text = "", bool session = false) {
    Admission admission(dialog);
    if (!admission.admitted) return;
    const auto &identity = dialog.modern && !session ? dialog.epoch : dialog.token;
    dialog.callback(118, -1, text.c_str(), identity.c_str(), path, dialog.context);
}
int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
bool rows(const char *text, std::vector<std::string> &result) {
    if (!text || strlen(text) > 262144) return false;
    if (!text[0]) return true;
    std::string value(text);
    size_t start = 0;
    do {
        const auto end = value.find('\n', start);
        auto row = value.substr(start, end == std::string::npos ? end : end - start);
        if (row.empty() || row.find('\r') != std::string::npos || result.size() >= 514) return false;
        result.push_back(std::move(row));
        if (end == std::string::npos) break;
        start = end + 1;
    } while (true);
    return true;
}
void layout(HWND window) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int margin = scale(window, 20), gap = scale(window, 10), height = scale(window, 36);
    const int width = bounds.right - 2 * margin, bottom = bounds.bottom - margin - height;
    MoveWindow(GetDlgItem(window, headingID), margin, margin, width, scale(window, 44), TRUE);
    MoveWindow(GetDlgItem(window, providerID), margin, scale(window, 76),
        width - scale(window, 170), scale(window, 200), TRUE);
    MoveWindow(GetDlgItem(window, keyID), bounds.right - margin - scale(window, 160),
        scale(window, 76), scale(window, 160), height, TRUE);
    MoveWindow(GetDlgItem(window, voicesID), margin, scale(window, 126), width,
        bottom - scale(window, 246), TRUE);
    MoveWindow(GetDlgItem(window, statusID), margin, bottom - scale(window, 110), width, scale(window, 100), TRUE);
    MoveWindow(GetDlgItem(window, refreshID), margin, bottom, scale(window, 140), height, TRUE);
    MoveWindow(GetDlgItem(window, chooseID), bounds.right - margin - scale(window, 250) - gap,
        bottom, scale(window, 130), height, TRUE);
    MoveWindow(GetDlgItem(window, closeID), bounds.right - margin - scale(window, 120),
        bottom, scale(window, 120), height, TRUE);
}
void font(HWND window, Dialog &dialog) {
    HFONT next = CreateFontW(-MulDiv(10, GetDpiForWindow(window), 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!next) return;
    for (int id : {headingID, providerID, keyID, voicesID, statusID, refreshID, chooseID, closeID})
        SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(next), TRUE);
    if (dialog.font) DeleteObject(dialog.font);
    dialog.font = next;
}
void sensitivity(HWND window, const Dialog &dialog) {
    const auto selected = SendDlgItemMessageW(window, voicesID, LB_GETCURSEL, 0, 0);
    const bool ready = !dialog.shown.loading && (!dialog.modern ||
        (dialog.acknowledged && dialog.inventoryMatched && dialog.generation == jsti_voice_provider_generation()));
    EnableWindow(GetDlgItem(window, providerID), dialog.modern && ready);
    EnableWindow(GetDlgItem(window, keyID), dialog.modern && ready);
    EnableWindow(GetDlgItem(window, refreshID), ready);
    EnableWindow(GetDlgItem(window, voicesID), ready);
    EnableWindow(GetDlgItem(window, chooseID), ready && selected >= 0 &&
        static_cast<size_t>(selected) < dialog.shown.identifiers.size());
}
void propose(HWND window, Dialog &dialog, int selected) {
    if (selected < 0 || static_cast<size_t>(selected) >= dialog.providers.size()) return;
    const auto epoch = newUUID();
    if (epoch.empty() || sameUUID(epoch, dialog.epoch)) {
        SetDlgItemTextW(window, statusID, L"A provider transition could not be created. Close and retry."); return;
    }
    dialog.provider = dialog.providers[static_cast<size_t>(selected)]; dialog.epoch = epoch;
    dialog.proposed = true; dialog.acknowledged = false; dialog.inventoryMatched = false;
    dialog.shown = {}; dialog.shown.loading = true;
    { std::lock_guard<std::mutex> lock(mutex); activeEpoch = epoch; pending = {}; }
    SendDlgItemMessageW(window, voicesID, LB_RESETCONTENT, 0, 0);
    SetDlgItemTextW(window, statusID, L"Waiting for the selected account provider. No key lookup is started.");
    sensitivity(window, dialog);
    emit(dialog, "account-provider", dialog.provider + "\n" + epoch, true);
}
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == inventoryMessage) {
        const auto generation = jsti_voice_provider_generation();
        std::lock_guard<std::mutex> lock(mutex);
        if (activeModern) {
            if (active != window) return 0;
            const bool eligible = generation &&
                ((pending.generation == generation && sameUUID(pending.token, activeEpoch)) ||
                std::any_of(pendingProviders.begin(), pendingProviders.end(), [&](const Providers &value) {
                    return value.generation == generation && sameUUID(value.session, activeToken);
                }));
            if (!eligible) { pending = {}; pendingProviders.clear(); return 0; }
        }
    }
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: {
        auto add = [&](const wchar_t *type, const wchar_t *text, DWORD style, int id, DWORD extended = 0) {
            return CreateWindowExW(extended, type, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 1, 1, window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
        };
        if (!add(L"STATIC", L"Account Voice &provider: presets and explicitly refreshed account voices", 0, headingID) ||
            !add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, providerID) ||
            !add(L"BUTTON", L"Provider &key...", BS_PUSHBUTTON | WS_TABSTOP, keyID) ||
            !add(L"LISTBOX", L"", LBS_NOTIFY | WS_VSCROLL | WS_HSCROLL | WS_TABSTOP, voicesID, WS_EX_CLIENTEDGE) ||
            !add(L"STATIC", L"Preparing choices. No source text is sent.", 0, statusID) ||
            !add(L"BUTTON", L"&Refresh", BS_PUSHBUTTON | WS_TABSTOP, refreshID) ||
            !add(L"BUTTON", L"&Choose voice", BS_DEFPUSHBUTTON | WS_TABSTOP, chooseID) ||
            !add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, closeID)) return -1;
        EnableWindow(GetDlgItem(window, chooseID), FALSE);
        sensitivity(window, *dialog);
        font(window, *dialog); layout(window);
        std::lock_guard<std::mutex> lock(mutex);
        active = window; activeToken = dialog->token; activeModern = dialog->modern; activeEpoch.clear();
        return 0;
    }
    case inventoryMessage: {
        std::vector<Providers> providers;
        { std::lock_guard<std::mutex> lock(mutex); providers.swap(pendingProviders); }
        for (const auto &projection : providers) {
            if (!dialog->modern || projection.generation != dialog->generation ||
                projection.generation != jsti_voice_provider_generation() ||
                !sameUUID(projection.session, dialog->token)) continue;
            if (!dialog->proposed) {
                dialog->providers = projection.ids;
                dialog->applying = true;
                SendDlgItemMessageW(window, providerID, CB_RESETCONTENT, 0, 0);
                bool added = true;
                for (const auto &label : projection.labels) {
                    const auto result = SendDlgItemMessageW(window, providerID, CB_ADDSTRING, 0,
                        reinterpret_cast<LPARAM>(label.c_str()));
                    if (result == CB_ERR || result == CB_ERRSPACE) { added = false; break; }
                }
                SendDlgItemMessageW(window, providerID, CB_SETCURSEL, projection.selected, 0);
                dialog->applying = false;
                if (!added) {
                    dialog->shown.loading = true; sensitivity(window, *dialog);
                    SetDlgItemTextW(window, statusID, L"The provider choices could not be shown. Close and retry.");
                    continue;
                }
                dialog->epoch = projection.epoch;
                propose(window, *dialog, projection.selected);
            } else if (sameUUID(projection.epoch, dialog->epoch) &&
                projection.ids[static_cast<size_t>(projection.selected)] == dialog->provider &&
                projection.ids == dialog->providers) {
                dialog->acknowledged = true;
            }
        }
        {
            std::lock_guard<std::mutex> lock(mutex);
            const bool matched = dialog->modern ? sameUUID(pending.token, dialog->epoch) : pending.token == dialog->token;
            if (active != window || activeToken != dialog->token || !matched ||
                (dialog->modern && (dialog->generation != jsti_voice_provider_generation() ||
                    pending.generation != dialog->generation))) {
                sensitivity(window, *dialog); return 0;
            }
            dialog->shown = pending;
        }
        if (dialog->modern) {
            for (const auto &identifier : dialog->shown.identifiers) {
                if (identifier.rfind(dialog->provider + "/", 0) != 0) {
                    dialog->inventoryMatched = false; dialog->shown.loading = true;
                    sensitivity(window, *dialog); return 0;
                }
            }
            dialog->inventoryMatched = true;
        }
        SendDlgItemMessageW(window, voicesID, LB_RESETCONTENT, 0, 0);
        for (const auto &label : dialog->shown.labels) {
            const auto result = SendDlgItemMessageW(window, voicesID, LB_ADDSTRING, 0,
                reinterpret_cast<LPARAM>(label.c_str()));
            if (result == LB_ERR || result == LB_ERRSPACE) {
                dialog->shown.identifiers.clear();
                SendDlgItemMessageW(window, voicesID, LB_RESETCONTENT, 0, 0);
                SetDlgItemTextW(window, statusID, L"The voice list could not be shown. Retry Refresh.");
                sensitivity(window, *dialog); return 0;
            }
        }
        SendDlgItemMessageW(window, voicesID, LB_SETCURSEL, dialog->shown.selected, 0);
        SetDlgItemTextW(window, statusID, dialog->shown.status.c_str());
        sensitivity(window, *dialog); return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == providerID && HIWORD(wparam) == CBN_SELCHANGE && !dialog->applying &&
            IsWindowEnabled(GetDlgItem(window, providerID))) {
            propose(window, *dialog, static_cast<int>(SendDlgItemMessageW(window, providerID, CB_GETCURSEL, 0, 0)));
            return 0;
        }
        if (LOWORD(wparam) == voicesID && HIWORD(wparam) == LBN_SELCHANGE) {
            sensitivity(window, *dialog); return 0;
        }
        if (HIWORD(wparam) != BN_CLICKED) break;
        if (LOWORD(wparam) == closeID || LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; }
        if (LOWORD(wparam) == keyID && IsWindowEnabled(GetDlgItem(window, keyID))) {
            jsti_show_voice_provider_credentials(window, dialog->generation, dialog->token,
                dialog->epoch, dialog->provider); return 0;
        }
        if (LOWORD(wparam) == refreshID && IsWindowEnabled(GetDlgItem(window, refreshID))) {
            dialog->shown.loading = true; sensitivity(window, *dialog);
            SetDlgItemTextW(window, statusID, L"Listing account voices. Close cancels.");
            emit(*dialog, "account-refresh"); return 0;
        }
        if (LOWORD(wparam) == chooseID && IsWindowEnabled(GetDlgItem(window, chooseID))) {
            const auto index = SendDlgItemMessageW(window, voicesID, LB_GETCURSEL, 0, 0);
            if (index >= 0 && static_cast<size_t>(index) < dialog->shown.identifiers.size())
                emit(*dialog, "account-choose", dialog->shown.identifiers[index]);
            return 0;
        }
        break;
    case WM_SIZE: layout(window); return 0;
    case WM_GETMINMAXINFO: {
        RECT size{0, 0, scale(window, 600), scale(window, 460)};
        AdjustWindowRectExForDpi(&size, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(window));
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {size.right - size.left, size.bottom - size.top};
        return 0;
    }
    case WM_DPICHANGED: {
        const auto bounds = reinterpret_cast<const RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
            bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
        font(window, *dialog); layout(window); return 0;
    }
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        { std::lock_guard<std::mutex> lock(mutex);
          if (active == window) {
              active = nullptr; activeToken.clear(); activeEpoch.clear(); pending = {}; pendingProviders.clear();
          } }
        emit(*dialog, "account-close", "", true);
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
HWND makeDialog(HWND owner, Dialog &dialog) {
    WNDCLASSW type{}; type.lpfnWndProc = procedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItVoiceDiscovery"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT bounds{0, 0, scale(owner, 660), scale(owner, 520)};
    AdjustWindowRectExForDpi(&bounds, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(owner));
    return CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName, L"Account Voice providers",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left, bounds.bottom - bounds.top,
        owner, nullptr, type.hInstance, &dialog);
}
}

int32_t jsti_window_set_voice_account_inventory(const char *token, const char *labels, const char *identifiers,
                                               int32_t selected, const char *status, int32_t loading) {
    if (!token || !token[0] || strlen(token) > 64 || !status || strlen(status) > 4096 ||
        (loading != 0 && loading != 1)) return -1;
    Inventory inventory; inventory.token = token; inventory.selected = selected; inventory.loading = loading != 0;
    inventory.generation = jsti_voice_provider_generation();
    std::vector<std::string> names;
    if (!rows(labels, names) || !rows(identifiers, inventory.identifiers) ||
        names.size() != inventory.identifiers.size() || selected < -1 ||
        (names.empty() ? selected != -1 : selected >= static_cast<int>(names.size())) ||
        !jsti::wide(status, inventory.status)) return -1;
    for (size_t index = 0; index < names.size(); ++index) {
        std::wstring label;
        if (names[index].size() > 512 || !jsti::wide(names[index].c_str(), label) ||
            inventory.identifiers[index].size() > 260 || inventory.identifiers[index].find('/') == std::string::npos)
            return -1;
        inventory.labels.push_back(std::move(label));
    }
    std::lock_guard<std::mutex> lock(mutex);
    if (!active || (activeModern ? !sameUUID(activeEpoch, token) : activeToken != token)) return 0;
    if (!activeModern) {
        for (const auto &identifier : inventory.identifiers)
            if (identifier.rfind("xai/", 0) != 0) return -1;
    }
    pending = std::move(inventory);
    return PostMessageW(active, inventoryMessage, 0, 0) ? 0 : -1;
}

int32_t jsti_window_set_voice_account_providers(const char *session, const char *epoch,
    const char *ids, const char *labels, int32_t selected) {
    if (!uuid(session) || !uuid(epoch)) return -1;
    Providers projection; projection.session = session; projection.epoch = epoch; projection.selected = selected;
    projection.generation = jsti_voice_provider_generation();
    std::vector<std::string> names;
    if (!rows(ids, projection.ids) || !rows(labels, names) || projection.ids.empty() ||
        projection.ids.size() != names.size() || selected < 0 ||
        static_cast<size_t>(selected) >= names.size()) return -1;
    for (size_t index = 0; index < names.size(); ++index) {
        const auto &id = projection.ids[index];
        if (id.empty() || id.size() > 32 || id.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-") !=
            std::string::npos || names[index].size() > 512 ||
            std::find(projection.ids.begin(), projection.ids.begin() + index, id) != projection.ids.begin() + index)
            return -1;
        std::wstring label;
        if (!jsti::wide(names[index].c_str(), label)) return -1;
        projection.labels.push_back(std::move(label));
    }
    std::lock_guard<std::mutex> lock(mutex);
    if (!active || !activeModern || !projection.generation || !sameUUID(activeToken, session)) return 0;
    pendingProviders.push_back(std::move(projection));
    if (PostMessageW(active, inventoryMessage, 0, 0)) return 0;
    pendingProviders.pop_back(); return -1;
}

void jsti_show_voice_discovery(HWND owner, JSTIVoiceSourceCallback callback, void *context) {
    const auto token = newUUID();
    const auto generation = jsti_voice_provider_generation();
    if (!callback || token.empty() || !generation) {
        jsti_window_update("An account voice request could not be created.", nullptr, -1); return;
    }
    Dialog dialog{token, callback, context};
    dialog.modern = true; dialog.generation = generation; dialog.shown.loading = true;
    HWND window = makeDialog(owner, dialog);
    if (!window) { jsti_window_update("The account voice chooser could not be opened.", nullptr, -1); return; }
    emit(dialog, "account-open-modern", "", true);
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, voicesID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0)
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) jsti_window_update("Reading account voice messages failed.", nullptr, -1);
}

bool jsti_voice_discovery_self_test(HWND owner, std::string &error) {
    struct Calls { std::string choice; int refreshed = 0, closed = 0; } calls;
    Dialog dialog{"synthetic-account-request", [](int32_t action, int32_t flag, const char *text,
        const char *, const char *path, void *context) {
        auto calls = static_cast<Calls *>(context);
        if (action != 118 || flag != -1) return;
        if (std::string(path) == "account-choose") calls->choice = text;
        if (std::string(path) == "account-refresh") ++calls->refreshed;
        if (std::string(path) == "account-close") ++calls->closed;
    }, &calls};
    HWND window = makeDialog(owner, dialog);
    if (!window) { error = "Account voice fixture could not open."; return false; }
    auto drain = [&] {
        MSG message{};
        while (PeekMessageW(&message, window, inventoryMessage, inventoryMessage, PM_REMOVE))
            DispatchMessageW(&message);
    };
    bool passed = jsti_window_set_voice_account_inventory(dialog.token.c_str(), "one", "xai/a\nxai/b", 0, "", 0) == -1;
    passed = jsti_window_set_voice_account_inventory("obsolete", "Wrong", "xai/wrong", 0, "", 0) == 0 && passed;
    drain(); passed = !IsWindowEnabled(GetDlgItem(window, chooseID)) && passed;
    const char *labels = "Eve - xAI Speech (documented preset)\nSynthetic account voice (account listing)";
    const char *ids = "xai/eve\nxai/Account-A";
    const char *status = "Synthetic fixture: no provider calls. Listing received: 1 additional account voice. "
        "Documented presets are labelled separately. Choose voice saves the stable identifier.";
    passed = jsti_window_set_voice_account_inventory(dialog.token.c_str(), labels, ids, 1, status, 0) == 0 && passed;
    drain(); SendDlgItemMessageW(window, chooseID, BM_CLICK, 0, 0);
    passed = calls.choice == "xai/Account-A" && passed;
    SendDlgItemMessageW(window, refreshID, BM_CLICK, 0, 0);
    passed = calls.refreshed == 1 && !IsWindowEnabled(GetDlgItem(window, chooseID)) && passed;
    passed = jsti_window_set_voice_account_inventory("obsolete", "Wrong", "xai/wrong", 0, "", 0) == 0 && passed;
    drain(); passed = !IsWindowEnabled(GetDlgItem(window, chooseID)) && passed;
    passed = jsti_window_set_voice_account_inventory(dialog.token.c_str(), labels, ids, 1, status, 0) == 0 && passed;
    drain();
    auto fits = [&] {
        RECT client{}; GetClientRect(window, &client);
        for (HWND child = GetWindow(window, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
            RECT bounds{}; GetWindowRect(child, &bounds);
            MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
            if (bounds.left < 0 || bounds.top < 0 || bounds.right > client.right || bounds.bottom > client.bottom)
                return false;
        }
        return true;
    };
    passed = fits() && passed;
    MINMAXINFO minimum{}; SendMessageW(window, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&minimum));
    SetWindowPos(window, nullptr, 0, 0, minimum.ptMinTrackSize.x, minimum.ptMinTrackSize.y, SWP_NOMOVE | SWP_NOZORDER);
    passed = fits() && passed;
    std::vector<wchar_t> path(32768, 0);
    const DWORD length = GetEnvironmentVariableW(L"JSTI_UI_SNAPSHOT_PATH", path.data(), static_cast<DWORD>(path.size()));
    if (length && length < path.size()) {
        char failure[1024]{}; ShowWindow(window, SW_SHOWNOACTIVATE);
        passed = jsti_save_owned_window_snapshot(window, (jsti::utf8(path.data()) + ".voice-discovery.bmp").c_str(),
            failure, sizeof(failure)) == 0 && passed;
        if (failure[0]) error = failure;
    }
    DestroyWindow(window);
    passed = calls.closed == 1 &&
        jsti_window_set_voice_account_inventory(dialog.token.c_str(), labels, ids, 1, status, 0) == 0 && passed;
    if (!passed && error.empty()) error = "Account voice fixture failed stable selection, loading, stale token or bounds.";
    return passed;
}
