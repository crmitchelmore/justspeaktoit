#include "WindowsVoiceSourcesInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <commdlg.h>
#include <objbase.h>
#include <mutex>
#include <vector>
#include <algorithm>

int jsti_owned_window_save_snapshot(HWND window, const char *path, char *error, size_t capacity);
void jsti_show_voice_controls(HWND owner, JSTIVoiceSourceCallback callback, void *context);
void jsti_show_voice_usage(HWND owner, const std::string &snapshot, JSTIVoiceSourceCallback callback, void *context);
void jsti_show_voice_discovery(HWND owner, JSTIVoiceSourceCallback callback, void *context);

namespace jsti::voiceSources {
std::mutex mutex;
Configuration configuration;
MarkupConfiguration markupConfiguration;
FormatState formatState;
GenerationState generationState;
HWND generationWindow = nullptr;
ImportResult importResult;

using jsti::chrome::scale;
std::wstring text(HWND window) {
    HWND editor = GetDlgItem(window, textID);
    const int count = GetWindowTextLengthW(editor);
    std::wstring value(static_cast<size_t>(count) + 1, 0);
    GetWindowTextW(editor, value.data(), count + 1);
    value.resize(static_cast<size_t>(count));
    return value;
}
static bool hasText(const std::wstring &value) {
    return value.find_first_not_of(L" \r\n\t") != std::wstring::npos;
}
bool canEditMarkup(const Dialog &dialog) {
    std::lock_guard<std::mutex> lock(mutex);
    return markupConfiguration.enabled && markupConfiguration.wrap && dialog.importToken.empty() &&
        (dialog.source == 1 || dialog.source == 3);
}
void refresh(HWND window, Dialog &dialog) {
    const bool ready = !dialog.generation.working && dialog.importToken.empty() && hasText(text(window)) &&
        (dialog.source != 0 || !dialog.record.empty());
    EnableWindow(GetDlgItem(window, readID), ready);
    const bool formatReady = !dialog.formatPending && (dialog.formats.identifiers.empty() ||
        (dialog.formats.selected >= 0 && static_cast<size_t>(dialog.formats.selected) < dialog.formats.identifiers.size() &&
         !dialog.formats.identifiers[dialog.formats.selected].empty()));
    EnableWindow(GetDlgItem(window, exportID), ready && formatReady);
    EnableWindow(GetDlgItem(window, generateID), ready && formatReady);
    const bool resultReady = !dialog.generation.working && !dialog.generation.resultID.empty();
    EnableWindow(GetDlgItem(window, playResultID), resultReady);
    EnableWindow(GetDlgItem(window, exportResultID), resultReady);
    EnableWindow(GetDlgItem(window, loadID), dialog.importToken.empty() && dialog.source >= 2);
    SetDlgItemTextW(window, loadID, dialog.source == 3 ? L"&Choose file..." : L"&Load clipboard");
    SendDlgItemMessageW(window, textID, EM_SETREADONLY, dialog.source != 1 && dialog.source != 3, 0);
    const bool markup = canEditMarkup(dialog);
    EnableWindow(GetDlgItem(window, helperID), markup);
    if (IsWindow(dialog.markupWindow)) EnableWindow(GetDlgItem(dialog.markupWindow, markupWrapID), markup);
}
std::string selectedFormat(const Dialog &dialog) {
    if (dialog.formats.selected < 0 || static_cast<size_t>(dialog.formats.selected) >= dialog.formats.identifiers.size())
        return "";
    return dialog.formats.identifiers[dialog.formats.selected];
}
static void showFormats(HWND window, Dialog &dialog) {
    SendDlgItemMessageW(window, formatID, CB_RESETCONTENT, 0, 0);
    for (const auto &label : dialog.formats.labels)
        SendDlgItemMessageW(window, formatID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
    SendDlgItemMessageW(window, formatID, CB_SETCURSEL, dialog.formats.selected, 0);
    if (!dialog.formats.status.empty()) SetDlgItemTextW(window, noticeID, dialog.formats.status.c_str());
}
static bool copyMarkup(HWND window, const std::wstring &value, void *) {
    const size_t bytes = (value.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!memory) return false;
    void *target = GlobalLock(memory);
    if (!target) { GlobalFree(memory); return false; }
    memcpy(target, value.c_str(), bytes); GlobalUnlock(memory);
    if (!OpenClipboard(window)) { GlobalFree(memory); return false; }
    const bool copied = EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, memory);
    CloseClipboard();
    if (!copied) GlobalFree(memory);
    return copied;
}
static void selectMarkupExample(HWND window, const MarkupDialog &dialog) {
    const LRESULT index = SendDlgItemMessageW(window, markupListID, LB_GETCURSEL, 0, 0);
    if (index < 0 || static_cast<size_t>(index) >= dialog.config.examples.size()) return;
    SetDlgItemTextW(window, markupTextID, dialog.config.examples[static_cast<size_t>(index)].text.c_str());
}
bool applyMarkup(HWND window, MarkupDialog &dialog) {
    if (!IsWindow(dialog.owner) || !canEditMarkup(*dialog.source)) {
        SetDlgItemTextW(window, markupNoticeID, L"Choose an editable draft and enable SSML for a compatible voice.");
        return false;
    }
    const std::wstring original = text(dialog.owner);
    const std::string input = jsti::utf8(original);
    if (input.size() > 1'000'000) {
        SetDlgItemTextW(window, markupNoticeID, L"The draft is too large to wrap. Its text and selection are unchanged.");
        return false;
    }
    std::vector<char> result(input.size() + 1024, 0);
    int32_t leadingUTF16 = 0, leadingScalars = 0;
    std::wstring wrapped;
    if (!dialog.config.wrap || dialog.config.wrap(input.c_str(), result.data(), result.size(),
            &leadingUTF16, &leadingScalars) != 0 ||
        !memchr(result.data(), 0, result.size()) || !jsti::wide(result.data(), wrapped) ||
        wrapped.size() > 200000 || leadingUTF16 < 0 || static_cast<size_t>(leadingUTF16) > wrapped.size()) {
        SetDlgItemTextW(window, markupNoticeID, L"The draft could not be wrapped within the editor limit. Nothing changed.");
        return false;
    }
    HWND editor = GetDlgItem(dialog.owner, textID);
    DWORD start = 0, end = 0;
    SendMessageW(editor, EM_GETSEL, reinterpret_cast<WPARAM>(&start), reinterpret_cast<LPARAM>(&end));
    if (wrapped != original) {
        SendMessageW(editor, EM_SETSEL, 0, -1);
        SendMessageW(editor, EM_REPLACESEL, TRUE, reinterpret_cast<LPARAM>(wrapped.c_str()));
        SendMessageW(editor, EM_SETSEL, std::min<size_t>(start + leadingUTF16, wrapped.size()),
            static_cast<LPARAM>(std::min<size_t>(end + leadingUTF16, wrapped.size())));
    }
    SetDlgItemTextW(dialog.owner, noticeID, L"SSML draft updated. No speech was generated or settings saved.");
    return true;
}
static void layoutMarkup(HWND window) {
    auto move = [&](int id, int x, int y, int w, int h) {
        MoveWindow(GetDlgItem(window, id), scale(window, x), scale(window, y), scale(window, w), scale(window, h), TRUE);
    };
    move(985, 20, 18, 450, 44); move(986, 20, 70, 450, 22);
    move(markupListID, 20, 96, 450, 125); move(987, 20, 222, 315, 22);
    move(markupTextID, 20, 248, 315, 54);
    move(markupCopyID, 345, 248, 125, 34); move(markupNoticeID, 20, 314, 450, 44);
    move(IDCANCEL, 20, 370, 90, 34); move(markupWrapID, 270, 370, 200, 34);
}
static LRESULT CALLBACK markupProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = jsti::chrome::dialogInstance<MarkupDialog>(window, message, lparam);
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    LRESULT themed = 0;
    if (jsti::chrome::dialogMessage(window, message, wparam, lparam, themed)) return themed;
    if (message == DM_GETDEFID) return MAKELRESULT(markupWrapID, DC_HASDEFID);
    if (message == WM_CREATE) {
        dialog->source->markupWindow = window;
        auto add = [&](const wchar_t *kind, const wchar_t *value, DWORD style, int id) {
            return CreateWindowExW(0, kind, value, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
        };
        if (!add(L"STATIC", L"Wrap the entire draft with SSML tags. Copy examples to edit manually; "
                L"copying does not insert or replace text.", SS_LEFT, 985) ||
            !add(L"STATIC", L"Common &tags", 0, 986) ||
            !add(L"LISTBOX", L"", LBS_NOTIFY | WS_TABSTOP | WS_VSCROLL | WS_BORDER, markupListID) ||
            !add(L"STATIC", L"Example &markup", 0, 987) ||
            !add(L"EDIT", L"", ES_MULTILINE | ES_READONLY | WS_VSCROLL | WS_TABSTOP, markupTextID) ||
            !add(L"BUTTON", L"&Copy example", BS_PUSHBUTTON | WS_TABSTOP, markupCopyID) ||
            !add(L"STATIC", L"Closing leaves the draft and its selection unchanged.", SS_LEFT, markupNoticeID) ||
            !add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL) ||
            !add(L"BUTTON", L"&Wrap with <speak>", BS_DEFPUSHBUTTON | WS_TABSTOP, markupWrapID)) return -1;
        for (const auto &example : dialog->config.examples) {
            if (SendDlgItemMessageW(window, markupListID, LB_ADDSTRING, 0,
                reinterpret_cast<LPARAM>(example.description.c_str())) < 0) return -1;
        }
        SendDlgItemMessageW(window, markupListID, LB_SETCURSEL, 0, 0);
        selectMarkupExample(window, *dialog);
        SendMessageW(window, WM_DPICHANGED, MAKEWPARAM(GetDpiForWindow(window), GetDpiForWindow(window)), 0);
        return 0;
    }
    if (message == WM_DPICHANGED) {
        HFONT font = jsti::chrome::dialogFont(window);
        if (font) {
            for (HWND child = GetWindow(window, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT))
                SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
            if (dialog->font) DeleteObject(dialog->font);
            dialog->font = font;
        }
        if (lparam) {
            const RECT &position = *reinterpret_cast<const RECT *>(lparam);
            RECT bounds{0, 0, scale(window, 490), scale(window, 425)};
            AdjustWindowRectExForDpi(&bounds, WS_CAPTION | WS_SYSMENU, FALSE,
                WS_EX_CONTROLPARENT | WS_EX_DLGMODALFRAME, GetDpiForWindow(window));
            SetWindowPos(window, nullptr, position.left, position.top, bounds.right - bounds.left,
                bounds.bottom - bounds.top, SWP_NOZORDER | SWP_NOACTIVATE);
        }
        layoutMarkup(window); return 0;
    }
    if (message == WM_SIZE) { layoutMarkup(window); return 0; }
    if (message == WM_COMMAND) {
        if (LOWORD(wparam) == markupListID && HIWORD(wparam) == LBN_SELCHANGE) {
            selectMarkupExample(window, *dialog); return 0;
        }
        if (HIWORD(wparam) == BN_CLICKED) {
            if (LOWORD(wparam) == IDCANCEL) DestroyWindow(window);
            if ((LOWORD(wparam) == markupWrapID || LOWORD(wparam) == IDOK) && applyMarkup(window, *dialog))
                DestroyWindow(window);
            if (LOWORD(wparam) == markupCopyID) {
                const LRESULT index = SendDlgItemMessageW(window, markupListID, LB_GETCURSEL, 0, 0);
                const bool copied = index >= 0 && static_cast<size_t>(index) < dialog->config.examples.size() &&
                    dialog->copy && dialog->copy(window, dialog->config.examples[static_cast<size_t>(index)].text,
                        dialog->copyContext);
                SetDlgItemTextW(window, markupNoticeID, copied ? L"Example copied. The draft is unchanged."
                    : L"The example could not be copied. Try again.");
            }
            return 0;
        }
    }
    if (message == WM_CLOSE) { DestroyWindow(window); return 0; }
    if (message == WM_DESTROY) {
        dialog->source->markupWindow = nullptr;
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr; return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
HWND makeMarkupDialog(MarkupDialog &dialog) {
    WNDCLASSW type{};
    type.lpfnWndProc = markupProcedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItSSMLHelper"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    RECT bounds{0, 0, scale(dialog.owner, 490), scale(dialog.owner, 425)};
    AdjustWindowRectExForDpi(&bounds, WS_CAPTION | WS_SYSMENU, FALSE,
        WS_EX_CONTROLPARENT | WS_EX_DLGMODALFRAME, GetDpiForWindow(dialog.owner));
    return CreateWindowExW(WS_EX_CONTROLPARENT | WS_EX_DLGMODALFRAME, type.lpszClassName, L"SSML Helper",
        WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left, bounds.bottom - bounds.top,
        dialog.owner, nullptr, type.hInstance, &dialog);
}
static void showMarkup(HWND owner, Dialog &source) {
    if (!canEditMarkup(source)) return;
    MarkupDialog dialog; dialog.owner = owner; dialog.source = &source; dialog.copy = copyMarkup;
    { std::lock_guard<std::mutex> lock(mutex); dialog.config = markupConfiguration; }
    HWND window = makeMarkupDialog(dialog);
    if (!window) { SetDlgItemTextW(owner, noticeID, L"The SSML Helper could not be opened."); return; }
    source.markupWindow = window;
    EnableWindow(owner, FALSE); ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, markupListID));
    MSG message{}; BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) DestroyWindow(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); SetFocus(GetDlgItem(owner, textID)); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    if (result < 0) SetDlgItemTextW(owner, noticeID, L"Reading SSML Helper messages failed. The draft is retained.");
}
static void cancelImport(HWND window, Dialog &dialog) {
    if (dialog.importToken.empty()) return;
    const std::string token = std::move(dialog.importToken);
    dialog.importToken.clear();
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (importResult.window == window && importResult.token == token) importResult = {};
    }
    if (dialog.config.callback) dialog.config.callback(114, 4, "", token.c_str(), "", dialog.config.context);
}
void select(HWND window, Dialog &dialog) {
    cancelImport(window, dialog);
    if (dialog.source == 1) dialog.typed = text(window);
    if (dialog.source == 3) dialog.file = text(window);
    dialog.source = static_cast<int>(SendDlgItemMessageW(window, sourceID, CB_GETCURSEL, 0, 0));
    const auto &value = dialog.source == 0 ? dialog.history : dialog.source == 1 ? dialog.typed :
        dialog.source == 2 ? dialog.clipboard : dialog.file;
    SetDlgItemTextW(window, textID, value.c_str());
    SetDlgItemTextW(window, noticeID, dialog.source == 0 && dialog.record.empty()
        ? L"Choose a recording in History, then reopen this editor. History text is captured when this editor opens."
        : L"Read, Generate and Export text send this snapshot to the selected voice provider with your saved key. "
          L"Generate retains the selected file format and native-decoded playback; Play/Export reuse them without a provider request. "
          L"Voice controls show the selected route's actual capabilities. Stop cancels active voice work.");
    refresh(window, dialog);
}
static void importFile(HWND window, Dialog &dialog) {
    std::vector<wchar_t> path(32768, 0);
    OPENFILENAMEW choice{};
    choice.lStructSize = sizeof(choice); choice.hwndOwner = window;
    choice.lpstrFilter = L"Text files\0*.txt;*.md;*.csv;*.log\0All files\0*.*\0";
    choice.lpstrFile = path.data(); choice.nMaxFile = static_cast<DWORD>(path.size());
    choice.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&choice)) {
        if (CommDlgExtendedError()) SetDlgItemTextW(window, noticeID, L"The text file chooser could not be opened.");
        return;
    }
    if (!IsWindow(window) || dialog.source != 3) return;
    GUID identifier{};
    wchar_t token[40]{};
    if (FAILED(CoCreateGuid(&identifier)) || !StringFromGUID2(identifier, token, 40)) {
        SetDlgItemTextW(window, noticeID, L"A text import request could not be created.");
        return;
    }
    cancelImport(window, dialog);
    dialog.importToken = jsti::utf8(token);
    {
        std::lock_guard<std::mutex> lock(mutex);
        importResult = {window, dialog.importToken, {}, {}, false};
    }
    SetDlgItemTextW(window, noticeID, L"Reading UTF-8 text... Stop cancels. Editing or changing source discards the result.");
    refresh(window, dialog);
    const std::string destination = jsti::utf8(path.data());
    dialog.config.callback(113, 4, "", dialog.importToken.c_str(), destination.c_str(), dialog.config.context);
}
static void loadClipboard(HWND window, Dialog &dialog) {
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
void emit(HWND window, Dialog &dialog, int action, const std::string &path) {
    const std::string snapshot = jsti::utf8(text(window));
    const std::string record = dialog.source == 0 ? dialog.record : "";
    if (dialog.config.callback) {
        dialog.config.callback(action, dialog.source == 3 ? 4 : dialog.source,
            snapshot.c_str(), record.c_str(), path.c_str(), dialog.config.context);
    }
}
static void exportAudio(HWND window, Dialog &dialog, bool retained = false) {
    // The nested save loop may process editor messages: freeze the entire job first.
    const std::string snapshot = jsti::utf8(text(window));
    const std::string record = retained ? dialog.generation.resultID : dialog.source == 0 ? dialog.record : "";
    const int source = dialog.source == 3 ? 4 : dialog.source;
    const std::string format = retained ? dialog.generation.format
        : dialog.formats.identifiers.empty() ? "wav" : selectedFormat(dialog);
    if (format.empty()) { SetDlgItemTextW(window, noticeID, L"Choose an available file format first."); return; }
    const std::wstring extension(format.begin(), format.end());
    const std::wstring filename = L"voice-output." + extension;
    const std::wstring pattern = L"*." + extension;
    std::wstring filter = extension + L" audio (" + pattern + L")";
    filter.push_back(0); filter += pattern; filter.push_back(0); filter.push_back(0);
    std::vector<wchar_t> path(32768, 0);
    wcscpy_s(path.data(), path.size(), filename.c_str());
    OPENFILENAMEW choice{};
    choice.lStructSize = sizeof(choice);
    choice.hwndOwner = window;
    choice.lpstrFilter = filter.c_str();
    choice.lpstrFile = path.data();
    choice.nMaxFile = static_cast<DWORD>(path.size());
    choice.lpstrDefExt = extension.c_str();
    choice.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetSaveFileNameW(&choice)) {
        if (CommDlgExtendedError()) SetDlgItemTextW(window, noticeID, L"The audio save dialog could not be opened.");
        return;
    }
    const std::wstring chosen(path.data());
    const auto dot = chosen.find_last_of(L'.');
    if (dot == std::wstring::npos || _wcsicmp(chosen.c_str() + dot + 1, extension.c_str()) != 0) {
        SetDlgItemTextW(window, noticeID, L"Keep the selected file format's extension. No export was started.");
        return;
    }
    const std::string destination = jsti::utf8(path.data());
    if (dialog.config.callback) {
        cancelImport(window, dialog);
        dialog.config.callback(retained ? 117 : 111, source, snapshot.c_str(), record.c_str(),
            destination.c_str(), dialog.config.context);
    }
    SetDlgItemTextW(window, noticeID, L"Export started. Check the main window status for its result. Stop cancels it.");
}
static void layout(HWND window) {
    RECT bounds{}; GetClientRect(window, &bounds);
    const int margin = scale(window, 20), gap = scale(window, 10), height = scale(window, 34);
    const int width = bounds.right - 2 * margin, bottom = bounds.bottom - margin - height;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    move(sourceLabel, margin, margin, width - scale(window, 340), scale(window, 22));
    move(sourceID, margin, margin + scale(window, 26), width - scale(window, 340), scale(window, 240));
    move(formatLabelID, bounds.right - margin - scale(window, 330), margin, scale(window, 155), scale(window, 22));
    move(formatID, bounds.right - margin - scale(window, 330), margin + scale(window, 26),
         scale(window, 155), scale(window, 200));
    move(loadID, bounds.right - margin - scale(window, 160), margin + scale(window, 26), scale(window, 160), height);
    move(textLabel, margin, margin + scale(window, 70), width - scale(window, 180), scale(window, 22));
    move(helperID, bounds.right - margin - scale(window, 170), margin + scale(window, 64), scale(window, 170), height);
    const int resultRow = bottom - height - gap;
    const int optionsRow = resultRow - scale(window, 44) - gap;
    const int usageRow = optionsRow - height - gap;
    const int top = margin + scale(window, 104), note = usageRow - gap - scale(window, 90);
    move(textID, margin, top, width, std::max(scale(window, 110), note - gap - top));
    move(noticeID, margin, note, width, scale(window, 90));
    move(usageID, margin, usageRow, (width - gap) / 2, height);
    move(discoveryID, margin + (width + gap) / 2, usageRow, (width - gap) / 2, height);
    const int optionWidth = (width - 2 * gap) / 3;
    move(autoPlayID, margin, optionsRow, optionWidth, scale(window, 44));
    move(saveID, margin + optionWidth + gap, optionsRow, optionWidth, scale(window, 44));
    move(controlsID, margin + 2 * (optionWidth + gap), optionsRow, optionWidth, scale(window, 44));
    const int resultButton = (width - 2 * gap) / 3;
    const int results[] = {generateID, playResultID, exportResultID};
    for (int index = 0; index < 3; ++index) {
        move(results[index], margin + index * (resultButton + gap), resultRow, resultButton, height);
    }
    const int button = (width - 3 * gap) / 4;
    const int ids[] = {readID, exportID, stopID, IDCANCEL};
    for (int index = 0; index < 4; ++index) move(ids[index], margin + index * (button + gap), bottom, button, height);
}
static bool create(HWND window, Dialog &dialog) {
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
        !add(L"BUTTON", L"SSML &Helper...", BS_PUSHBUTTON | WS_TABSTOP, helperID) ||
        !add(L"STATIC", L"", SS_LEFT, noticeID) ||
        !add(L"BUTTON", L"&Usage and input estimate...", BS_PUSHBUTTON | WS_TABSTOP, usageID) ||
        !add(L"BUTTON", L"&Account voices...", BS_PUSHBUTTON | WS_TABSTOP, discoveryID) ||
        !add(L"STATIC", L"File &format", 0, formatLabelID) ||
        !add(L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_TABSTOP | WS_VSCROLL, formatID) ||
        !add(L"BUTTON", L"&Auto-play generated audio", BS_AUTOCHECKBOX | BS_MULTILINE | WS_TABSTOP, autoPlayID) ||
        !add(L"BUTTON", L"Save audio to recordings", BS_AUTOCHECKBOX | BS_MULTILINE | WS_TABSTOP, saveID) ||
        !add(L"BUTTON", L"Voice &controls...", BS_PUSHBUTTON | WS_TABSTOP, controlsID) ||
        !add(L"BUTTON", L"&Generate", BS_DEFPUSHBUTTON | WS_TABSTOP, generateID) ||
        !add(L"BUTTON", L"&Play result", BS_PUSHBUTTON | WS_TABSTOP, playResultID) ||
        !add(L"BUTTON", L"Export result...", BS_PUSHBUTTON | WS_TABSTOP, exportResultID) ||
        !add(L"BUTTON", L"&Read aloud", BS_PUSHBUTTON | WS_TABSTOP, readID) ||
        !add(L"BUTTON", L"&Export text...", BS_PUSHBUTTON | WS_TABSTOP, exportID) ||
        !add(L"BUTTON", L"&Stop", BS_PUSHBUTTON | WS_TABSTOP, stopID) ||
        !add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL)) return false;
    dialog.font = jsti::chrome::dialogFont(window);
    for (HWND child : dialog.controls) SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(dialog.font), TRUE);
    SendDlgItemMessageW(window, textID, EM_SETLIMITTEXT, 200000, 0);
    for (const auto &name : dialog.config.names) {
        if (SendDlgItemMessageW(window, sourceID, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(name.c_str())) < 0) return false;
    }
    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, 0, 0);
    { std::lock_guard<std::mutex> lock(mutex);
      dialog.generation = generationState; dialog.formats = formatState; generationWindow = window; }
    showFormats(window, dialog);
    SendDlgItemMessageW(window, autoPlayID, BM_SETCHECK, dialog.generation.flags & 1 ? BST_CHECKED : BST_UNCHECKED, 0);
    SendDlgItemMessageW(window, saveID, BM_SETCHECK, dialog.generation.flags & 2 ? BST_CHECKED : BST_UNCHECKED, 0);
    select(window, dialog); layout(window);
    return true;
}
static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = jsti::chrome::dialogInstance<Dialog>(window, message, lparam);
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    LRESULT themed = 0;
    if (jsti::chrome::dialogMessage(window, message, wparam, lparam, themed)) return themed;
    switch (message) {
    case formatMessage:
        { std::lock_guard<std::mutex> lock(mutex); dialog->formats = formatState; }
        dialog->formatPending = false; showFormats(window, *dialog); refresh(window, *dialog); return 0;
    case markupMessage: refresh(window, *dialog); return 0;
    case generationMessage: {
        GenerationState current;
        { std::lock_guard<std::mutex> lock(mutex); current = generationState; }
        if (wparam & 1) {
            dialog->generation.flags = current.flags;
            SendDlgItemMessageW(window, autoPlayID, BM_SETCHECK, current.flags & 1 ? BST_CHECKED : BST_UNCHECKED, 0);
            SendDlgItemMessageW(window, saveID, BM_SETCHECK, current.flags & 2 ? BST_CHECKED : BST_UNCHECKED, 0);
        }
        if (wparam & 2) {
            dialog->generation.resultID = std::move(current.resultID);
            dialog->generation.working = current.working;
            dialog->generation.format = current.format;
            SetDlgItemTextW(window, noticeID, current.message.c_str());
        }
        refresh(window, *dialog); return 0;
    }
    case importResultMessage: {
        ImportResult result;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (importResult.window != window || importResult.token != dialog->importToken || !importResult.ready) return 0;
            result = std::move(importResult); importResult = {};
        }
        dialog->importToken.clear();
        if (result.error.empty()) {
            dialog->file = std::move(result.text);
            SetDlgItemTextW(window, textID, dialog->file.c_str());
            SetDlgItemTextW(window, noticeID, L"Text file captured. You can edit it; later file changes do not change this snapshot.");
        } else {
            const std::wstring notice = result.error + L" Existing text is unchanged.";
            SetDlgItemTextW(window, noticeID, notice.c_str());
        }
        refresh(window, *dialog); return 0;
    }
    case WM_CREATE: return create(window, *dialog) ? 0 : -1;
    case WM_SIZE: layout(window); return 0;
    case WM_GETMINMAXINFO:
        jsti::chrome::minimumTrackSize(window, lparam, 620, 540, WS_OVERLAPPEDWINDOW, WS_EX_CONTROLPARENT);
        return 0;
    case WM_DPICHANGED: {
        jsti::chrome::applySuggestedBounds(window, lparam);
        HFONT font = jsti::chrome::dialogFont(window);
        if (font) {
            for (HWND child : dialog->controls) SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
            if (dialog->font) DeleteObject(dialog->font);
            dialog->font = font;
        }
        layout(window); return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == formatID && HIWORD(wparam) == CBN_SELCHANGE) {
            dialog->formats.selected = static_cast<int>(SendDlgItemMessageW(window, formatID, CB_GETCURSEL, 0, 0));
            const auto identifier = selectedFormat(*dialog);
            if (!identifier.empty() && dialog->config.callback) {
                dialog->formatPending = true; refresh(window, *dialog);
                SetDlgItemTextW(window, noticeID, L"Checking installed codecs before saving...");
                dialog->config.callback(118, -1, identifier.c_str(), "format", "audio-format", dialog->config.context);
            }
            return 0;
        }
        if (LOWORD(wparam) == sourceID && HIWORD(wparam) == CBN_SELCHANGE) { select(window, *dialog); return 0; }
        if (LOWORD(wparam) == textID && HIWORD(wparam) == EN_CHANGE) {
            const bool importing = !dialog->importToken.empty();
            cancelImport(window, *dialog);
            if (importing) SetDlgItemTextW(window, noticeID, L"Text import discarded. Your edits are preserved.");
            refresh(window, *dialog); return 0;
        }
        if (HIWORD(wparam) != BN_CLICKED) break;
        switch (LOWORD(wparam)) {
        case helperID: showMarkup(window, *dialog); return 0;
        case discoveryID:
            jsti_show_voice_discovery(window, dialog->config.callback, dialog->config.context); return 0;
        case usageID: {
            const auto snapshot = jsti::utf8(text(window));
            const auto count = std::count_if(snapshot.begin(), snapshot.end(),
                [](unsigned char byte) { return (byte & 0xC0) != 0x80; });
            if (count > 100000) SetDlgItemTextW(window, noticeID,
                L"Text exceeds 100,000 input characters. Shorten it before opening the usage estimate.");
            else jsti_show_voice_usage(window, snapshot, dialog->config.callback, dialog->config.context);
            break;
        }
        case controlsID: jsti_show_voice_controls(window, dialog->config.callback, dialog->config.context); break;
        case autoPlayID: case saveID:
            dialog->generation.flags = (SendDlgItemMessageW(window, autoPlayID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0) |
                (SendDlgItemMessageW(window, saveID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 2 : 0);
            dialog->config.callback(118, dialog->generation.flags, "", "", "", dialog->config.context); break;
        case generateID:
            if (IsWindowEnabled(GetDlgItem(window, generateID))) {
                const auto format = selectedFormat(*dialog);
                emit(window, *dialog, 115, std::to_string(dialog->generation.flags) +
                    (format.empty() ? "" : "|" + format));
            }
            break;
        case playResultID:
            if (IsWindowEnabled(GetDlgItem(window, playResultID))) {
                cancelImport(window, *dialog);
                dialog->config.callback(116, 0, "", dialog->generation.resultID.c_str(), "", dialog->config.context);
            }
            break;
        case exportResultID:
            if (IsWindowEnabled(GetDlgItem(window, exportResultID))) exportAudio(window, *dialog, true);
            break;
        case loadID: if (dialog->source == 3) importFile(window, *dialog); else loadClipboard(window, *dialog); break;
        case readID: if (IsWindowEnabled(GetDlgItem(window, readID))) emit(window, *dialog, 110); break;
        case exportID: if (IsWindowEnabled(GetDlgItem(window, exportID))) exportAudio(window, *dialog); break;
        case stopID:
            cancelImport(window, *dialog); refresh(window, *dialog);
            SetDlgItemTextW(window, noticeID, L"Stopped. The captured text is unchanged.");
            emit(window, *dialog, 112); break;
        case IDCANCEL: DestroyWindow(window); break;
        }
        return 0;
    case WM_CLOSE: DestroyWindow(window); return 0;
    case WM_DESTROY:
        cancelImport(window, *dialog);
        { std::lock_guard<std::mutex> lock(mutex); if (generationWindow == window) generationWindow = nullptr; }
        if (dialog->font) DeleteObject(dialog->font);
        dialog->font = nullptr; return 0;
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
} // namespace jsti::voiceSources

using namespace jsti::voiceSources;

int32_t jsti_window_set_voice_sources(const char *const *names, size_t count,
                                     JSTIVoiceSourceCallback callback, void *context) {
    if (!names || count != 4 || !callback) return -1;
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

int32_t jsti_window_set_voice_markup_helper(int32_t enabled, const JSTIVoiceMarkupExample *examples,
                                           size_t count, JSTIVoiceMarkupWrapCallback wrap) {
    if ((enabled != 0 && enabled != 1) || !examples || count == 0 || count > 32 || !wrap) return -1;
    MarkupConfiguration changed; changed.enabled = enabled != 0; changed.wrap = wrap;
    for (size_t index = 0; index < count; ++index) {
        MarkupExample example;
        if (!examples[index].text || !examples[index].description ||
            strlen(examples[index].text) > 8192 || strlen(examples[index].description) > 256 ||
            !jsti::wide(examples[index].text, example.text) || example.text.empty() ||
            !jsti::wide(examples[index].description, example.description) || example.description.empty()) return -1;
        changed.examples.push_back(std::move(example));
    }
    std::lock_guard<std::mutex> lock(mutex);
    markupConfiguration = std::move(changed);
    return generationWindow && !PostMessageW(generationWindow, markupMessage, 0, 0) ? -1 : 0;
}

int32_t jsti_window_set_voice_text_import(const char *token, const char *text, const char *error) {
    std::wstring value, failure;
    if (!token || !token[0] || std::strlen(token) > 64 ||
        !jsti::wide(text ? text : "", value) || !jsti::wide(error ? error : "", failure)) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    if (!importResult.window || importResult.token != token) return 1;
    importResult.text = std::move(value); importResult.error = std::move(failure); importResult.ready = true;
    if (!PostMessageW(importResult.window, importResultMessage, 0, 0)) { importResult = {}; return -1; }
    return 0;
}

int32_t jsti_window_set_voice_generation_options(int32_t flags) {
    if (flags < 0 || flags > 3) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    generationState.flags = flags;
    return generationWindow && !PostMessageW(generationWindow, generationMessage, 1, 0) ? -1 : 0;
}

int32_t jsti_window_set_voice_generated_result(const char *resultID, int32_t working, const char *message) {
    return jsti_window_set_voice_generated_result_with_format(resultID, working, message, "wav");
}
int32_t jsti_window_set_voice_generated_result_with_format(
    const char *resultID, int32_t working, const char *message, const char *format) {
    std::wstring value;
    if (!resultID || std::strlen(resultID) > 64 || !format || std::strlen(format) > 12 ||
        !*format || std::strspn(format, "abcdefghijklmnopqrstuvwxyz0123456789") != std::strlen(format) ||
        (working != 0 && working != 1) ||
        !jsti::wide(message ? message : "", value)) return -1;
    std::lock_guard<std::mutex> lock(mutex);
    generationState.resultID = resultID; generationState.working = working != 0;
    generationState.message = std::move(value);
    generationState.format = format;
    return generationWindow && !PostMessageW(generationWindow, generationMessage, 2, 0) ? -1 : 0;
}
int32_t jsti_window_set_voice_audio_formats(const char *rows, const char *selected, const char *status) {
    if (!rows || !selected || std::strlen(rows) > 8192 || std::strlen(selected) > 256) return -1;
    FormatState next;
    if (!jsti::wide(status ? status : "", next.status)) return -1;
    const std::string values(rows);
    size_t offset = 0;
    while (offset < values.size()) {
        const size_t end = values.find('\n', offset);
        const auto row = values.substr(offset, end == std::string::npos ? end : end - offset);
        const auto tab = row.find('\t');
        if (tab == std::string::npos || tab == 0 || tab > 12 || next.labels.size() >= 64) return -1;
        std::string identifier = row.substr(0, tab);
        if (identifier.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789") != std::string::npos) return -1;
        std::wstring label;
        if (!jsti::wide(row.substr(tab + 1).c_str(), label)) return -1;
        if (identifier == selected) next.selected = static_cast<int>(next.labels.size());
        next.identifiers.push_back(identifier); next.labels.push_back(std::move(label));
        if (end == std::string::npos) break;
        offset = end + 1;
    }
    if (next.labels.empty()) return -1;
    if (next.selected < 0) {
        next.selected = static_cast<int>(next.labels.size());
        next.labels.push_back(L"Unavailable stored format"); next.identifiers.push_back("");
    }
    std::lock_guard<std::mutex> lock(mutex); formatState = std::move(next);
    return generationWindow && !PostMessageW(generationWindow, formatMessage, 0, 0) ? -1 : 0;
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
