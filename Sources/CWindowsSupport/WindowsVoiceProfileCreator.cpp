#include "WindowsVoiceSourcesInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <commdlg.h>
#include <objbase.h>
#include <deque>
#include <optional>

namespace {
using jsti::chrome::scale;
enum { nameLabel = 2600, nameID, languageLabel, languageID, referenceID, chooseID,
       transcriptLabel, transcriptID, consentID, saveID, recordID, previewID, transcribeID, addID, statusID, profilesLabel, profilesID, removeID };
struct Form {
    jsti::voiceSources::Dialog &source;
    std::string reference;
    std::string session;
    HFONT font = nullptr;
    bool ready = false, pending = false, recording = false;
    int added = 0;
    std::vector<std::string> profileIDs;
};

constexpr UINT profileMessage = WM_APP + 66;
struct Result { int phase; std::wstring status; std::optional<std::wstring> transcript; };
std::mutex profileMutex;
HWND active = nullptr;
std::string activeSession;
std::deque<Result> results;

std::string field(HWND window, int id) {
    HWND child = GetDlgItem(window, id);
    std::wstring value(GetWindowTextLengthW(child) + 1, L'\0');
    value.resize(GetWindowTextW(child, value.data(), static_cast<int>(value.size())));
    return jsti::utf8(value);
}

void refresh(HWND window, const Form &form) {
    bool consent = IsDlgButtonChecked(window, consentID) == BST_CHECKED;
    bool idle = !form.pending && !form.recording;
    bool words = GetWindowTextLengthW(GetDlgItem(window, transcriptID)) > 0;
    EnableWindow(GetDlgItem(window, removeID), idle && !form.profileIDs.empty());
    EnableWindow(GetDlgItem(window, chooseID), idle);
    EnableWindow(GetDlgItem(window, recordID), !form.pending);
    SetDlgItemTextW(window, recordID, form.recording ? L"Stop recording" : L"Record guided script");
    EnableWindow(GetDlgItem(window, previewID), idle && form.ready);
    EnableWindow(GetDlgItem(window, transcribeID), idle && form.ready);
    EnableWindow(GetDlgItem(window, addID), idle && form.ready && words && form.added < 2);
    SendDlgItemMessageW(window, transcriptID, EM_SETREADONLY, !idle || !form.ready, 0);
    EnableWindow(GetDlgItem(window, saveID), idle && consent && (form.ready ? words : form.added > 0) &&
        !field(window, nameID).empty() && !field(window, languageID).empty());
}

void request(HWND window, Form &form, int op) {
    const auto text = field(window, transcriptID);
    std::string metadata = form.session;
    if (op == 4) metadata += "\nconsent-v1\n" + field(window, nameID) + "\n" + field(window, languageID);
    form.pending = true;
    refresh(window, form);
    form.source.config.callback(120, op, text.c_str(), metadata.c_str(), form.reference.c_str(), form.source.config.context);
}

void applyResult(HWND window, Form &form) {
    Result result;
    {
        std::lock_guard<std::mutex> lock(profileMutex);
        if (active != window || results.empty()) return;
        result = std::move(results.front());
        results.pop_front();
    }
    if (result.phase == 7) {
        form.profileIDs.clear();
        SendDlgItemMessageW(window, profilesID, CB_RESETCONTENT, 0, 0);
        return;
    }
    if (result.phase == 6 && result.transcript) {
        form.profileIDs.push_back(jsti::utf8(result.status));
        SendDlgItemMessageW(window, profilesID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(result.transcript->c_str()));
        if (form.profileIDs.size() == 1) SendDlgItemMessageW(window, profilesID, CB_SETCURSEL, 0, 0);
        return;
    }
    if (result.phase == 8 && result.transcript) {
        bool confirmed = MessageBoxW(window, result.status.c_str(), L"Delete voice profile?",
            MB_YESNO | MB_DEFBUTTON2 | MB_ICONWARNING) == IDYES;
        form.pending = confirmed;
        refresh(window, form);
        if (confirmed) form.source.config.callback(120, 9, "", form.session.c_str(),
            jsti::utf8(*result.transcript).c_str(), form.source.config.context);
        return;
    }
    if (result.phase == 1) {
        SetDlgItemTextW(GetWindow(window, GW_OWNER), jsti::voiceSources::noticeID, result.status.c_str());
        DestroyWindow(window);
        return;
    }
    SetDlgItemTextW(window, statusID, result.status.c_str());
    if (result.phase == 4) return;
    jsti::accessibility::announce(GetDlgItem(window, statusID), result.status, false);
    form.pending = false;
    form.recording = result.phase == 3;
    if (result.phase == 5) form.ready = true;
    if (result.phase == 2) { ++form.added; form.ready = false; }
    if (result.transcript) SetDlgItemTextW(window, transcriptID, result.transcript->c_str());
    refresh(window, form);
}

void choose(HWND window, Form &form) {
    wchar_t path[32768]{};
    OPENFILENAMEW picker{};
    picker.lStructSize = sizeof(picker);
    picker.hwndOwner = window;
    picker.lpstrFile = path;
    picker.nMaxFile = 32768;
    picker.lpstrFilter = L"Reference audio (*.wav;*.m4a;*.mp3)\0*.wav;*.m4a;*.mp3\0";
    picker.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&picker)) return;
    form.reference = jsti::utf8(path);
    SetDlgItemTextW(window, referenceID, path + picker.nFileOffset);
    SetDlgItemTextW(window, transcriptID, L"");
    form.ready = false;
    request(window, form, 0);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    Form *form = jsti::chrome::dialogInstance<Form>(window, message, lparam);
    if (!form) return DefWindowProcW(window, message, wparam, lparam);
    if (message == profileMessage) { applyResult(window, *form); return 0; }
    if (message == WM_CREATE) {
        form->font = jsti::chrome::dialogFont(window);
        auto add = [&](const wchar_t *type, const wchar_t *title, DWORD style, int id, int top, int height, int x = 16, int width = 490) {
            bool added = jsti::chrome::addControl(window, type, title, style, id,
                style & WS_TABSTOP && std::wstring(type) == L"EDIT" ? WS_EX_CLIENTEDGE : 0);
            if (!added) return false;
            HWND child = GetDlgItem(window, id);
            MoveWindow(child, scale(window, x), scale(window, top), scale(window, width), scale(window, height), TRUE);
            SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(form->font), TRUE);
            return true;
        };
        if (!add(L"STATIC", L"Profile &name", 0, nameLabel, 12, 20) ||
            !add(L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL, nameID, 34, 26) ||
            !add(L"STATIC", L"&Language", 0, languageLabel, 66, 20) ||
            !add(L"EDIT", L"", WS_TABSTOP | ES_AUTOHSCROLL, languageID, 88, 26) ||
            !add(L"STATIC", form->reference.empty() ? L"Choose a reference clip." : L"Reference: selected History recording",
                 0, referenceID, 120, 24) ||
            !add(L"BUTTON", L"Choose audio &file...", WS_TABSTOP, chooseID, 148, 32) ||
            !add(L"STATIC", L"Reference clip &transcript", 0, transcriptLabel, 190, 20) ||
            !add(L"EDIT", L"", WS_TABSTOP | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL, transcriptID, 212, 70) ||
            !add(L"BUTTON", L"Record guided script", WS_TABSTOP, recordID, 290, 34, 16, 150) ||
            !add(L"BUTTON", L"Play clip", WS_TABSTOP, previewID, 290, 34, 170, 85) ||
            !add(L"BUTTON", L"Auto-fill transcript", WS_TABSTOP, transcribeID, 290, 34, 259, 146) ||
            !add(L"BUTTON", L"Add clip", WS_TABSTOP, addID, 290, 34, 409, 97) ||
            !add(L"STATIC", L"", 0, statusID, 332, 48) ||
            !add(L"BUTTON", L"This is my voice, or I have the speaker's permission to copy it. "
                 L"I'll use it only for my own read aloud.", WS_TABSTOP | BS_AUTOCHECKBOX | BS_MULTILINE, consentID, 388, 52) ||
            !add(L"BUTTON", L"&Save voice profile", WS_TABSTOP | BS_PUSHBUTTON, saveID, 445, 32) ||
            !add(L"STATIC", L"Saved voice &profiles", 0, profilesLabel, 488, 20) ||
            !add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, profilesID, 511, 180, 16, 320) ||
            !add(L"BUTTON", L"Delete selected...", WS_TABSTOP, removeID, 511, 32, 345, 161)) return -1;
        refresh(window, *form);
        return 0;
    }
    if (message == WM_COMMAND) {
        if (HIWORD(wparam) == EN_CHANGE || LOWORD(wparam) == consentID) refresh(window, *form);
        if (LOWORD(wparam) == chooseID && HIWORD(wparam) == BN_CLICKED) choose(window, *form);
        if (LOWORD(wparam) == IDCANCEL) DestroyWindow(window);
        if (HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, LOWORD(wparam)))) {
            switch (LOWORD(wparam)) {
            case removeID: {
                auto index = SendDlgItemMessageW(window, profilesID, CB_GETCURSEL, 0, 0);
                if (index >= 0 && static_cast<size_t>(index) < form->profileIDs.size()) {
                    form->pending = true;
                    refresh(window, *form);
                    form->source.config.callback(120, 8, "", form->session.c_str(),
                        form->profileIDs[index].c_str(), form->source.config.context);
                }
                break;
            }
            case previewID: request(window, *form, 1); break;
            case transcribeID: request(window, *form, 2); break;
            case addID: request(window, *form, 3); break;
            case saveID: request(window, *form, 4); break;
            case recordID:
                if (!form->recording) form->ready = false;
                request(window, *form, form->recording ? 7 : 6);
                break;
            }
        }
        return 0;
    }
    if (message == WM_DESTROY) {
        {
            std::lock_guard<std::mutex> lock(profileMutex);
            if (active == window) { active = nullptr; activeSession.clear(); results.clear(); }
        }
        form->source.config.callback(120, 5, "", form->session.c_str(), "", form->source.config.context);
        if (form->font) DeleteObject(form->font);
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

void jsti_show_voice_profile(HWND owner, jsti::voiceSources::Dialog &source) {
    GUID guid{};
    wchar_t token[40]{};
    if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, token, 40)) return;
    std::string session = jsti::utf8(std::wstring(token + 1, 36));
    for (char &ch : session) if (ch >= 'A' && ch <= 'F') ch += 'a' - 'A';
    Form form{source, source.record, session};
    HWND window = jsti::chrome::createOwnedDialog(owner, L"JustSpeakToItVoiceProfile", procedure,
        L"Create voice profile", 524, 560, WS_CAPTION | WS_SYSMENU, WS_EX_CONTROLPARENT, &form);
    if (!window) { jsti_window_update("The voice profile editor could not open.", nullptr, -1); return; }
    {
        std::lock_guard<std::mutex> lock(profileMutex);
        active = window; activeSession = session;
    }
    request(window, form, 0);
    jsti::chrome::runModalDialog(owner, window, nameID, [](HWND child) { DestroyWindow(child); }, "voice profile");
}

int32_t jsti_window_voice_profile_result(const char *session, int32_t phase, const char *status, const char *transcript) {
    Result result{phase, {}, std::nullopt};
    if (!session || !status || !jsti::wide(status, result.status)) return -1;
    if (transcript && !jsti::wide(transcript, result.transcript.emplace())) return -1;
    std::lock_guard<std::mutex> lock(profileMutex);
    if (!active || activeSession != session) return 0;
    if (!PostMessageW(active, profileMessage, 0, 0)) return -1;
    results.push_back(std::move(result));
    return 0;
}
