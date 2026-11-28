#include "WindowsVoiceSourcesInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <commdlg.h>

namespace {
using jsti::chrome::scale;
enum { nameLabel = 2600, nameID, languageLabel, languageID, referenceID, chooseID,
       transcriptLabel, transcriptID, consentID, saveID };
struct Form {
    jsti::voiceSources::Dialog &source;
    std::string reference;
    HFONT font = nullptr;
};

std::string field(HWND window, int id) {
    HWND child = GetDlgItem(window, id);
    std::wstring value(GetWindowTextLengthW(child) + 1, L'\0');
    value.resize(GetWindowTextW(child, value.data(), static_cast<int>(value.size())));
    return jsti::utf8(value);
}

void refresh(HWND window, const Form &form) {
    bool consent = IsDlgButtonChecked(window, consentID) == BST_CHECKED;
    EnableWindow(GetDlgItem(window, saveID), consent && !form.reference.empty() &&
        !field(window, nameID).empty() && !field(window, languageID).empty() && !field(window, transcriptID).empty());
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
    refresh(window, form);
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    Form *form = jsti::chrome::dialogInstance<Form>(window, message, lparam);
    if (!form) return DefWindowProcW(window, message, wparam, lparam);
    if (message == WM_CREATE) {
        form->font = jsti::chrome::dialogFont(window);
        auto add = [&](const wchar_t *type, const wchar_t *title, DWORD style, int id, int top, int height) {
            bool added = jsti::chrome::addControl(window, type, title, style, id,
                style & WS_TABSTOP && std::wstring(type) == L"EDIT" ? WS_EX_CLIENTEDGE : 0);
            if (!added) return false;
            HWND child = GetDlgItem(window, id);
            MoveWindow(child, scale(window, 16), scale(window, top), scale(window, 490), scale(window, height), TRUE);
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
            !add(L"BUTTON", L"This is my voice, or I have the speaker's permission to copy it. "
                 L"I'll use it only for my own read aloud.", WS_TABSTOP | BS_AUTOCHECKBOX | BS_MULTILINE, consentID, 290, 52) ||
            !add(L"BUTTON", L"&Save voice profile", WS_TABSTOP | BS_PUSHBUTTON, saveID, 350, 32)) return -1;
        refresh(window, *form);
        return 0;
    }
    if (message == WM_COMMAND) {
        if (HIWORD(wparam) == EN_CHANGE || LOWORD(wparam) == consentID) refresh(window, *form);
        if (LOWORD(wparam) == chooseID && HIWORD(wparam) == BN_CLICKED) choose(window, *form);
        if (LOWORD(wparam) == IDCANCEL) DestroyWindow(window);
        if (LOWORD(wparam) == saveID && HIWORD(wparam) == BN_CLICKED && IsWindowEnabled(GetDlgItem(window, saveID))) {
            auto metadata = field(window, nameID) + "\n" + field(window, languageID);
            form->source.config.callback(120, 1, field(window, transcriptID).c_str(), metadata.c_str(),
                form->reference.c_str(), form->source.config.context);
            SetDlgItemTextW(GetWindow(window, GW_OWNER), jsti::voiceSources::noticeID,
                L"Check the main window for the profile save result.");
            DestroyWindow(window);
        }
        return 0;
    }
    if (message == WM_DESTROY && form->font) DeleteObject(form->font);
    return DefWindowProcW(window, message, wparam, lparam);
}
}

void jsti_show_voice_profile(HWND owner, jsti::voiceSources::Dialog &source) {
    Form form{source, source.record};
    HWND window = jsti::chrome::createOwnedDialog(owner, L"JustSpeakToItVoiceProfile", procedure,
        L"Create voice profile", 524, 400, WS_CAPTION | WS_SYSMENU, WS_EX_CONTROLPARENT, &form);
    if (!window) { jsti_window_update("The voice profile editor could not open.", nullptr, -1); return; }
    jsti::chrome::runModalDialog(owner, window, nameID, [](HWND child) { DestroyWindow(child); }, "voice profile");
}
