// The Voice Output sources dialog's checks, run by the window self-test.
#include "../CWindowsSupport/WindowsVoiceSourcesInternal.hpp"
#include "../CWindowsSupport/WindowsWindowChrome.hpp"
#include <algorithm>
#include <cstring>

int jsti_owned_window_save_snapshot(HWND window, const char *path, char *error, size_t capacity);

using namespace jsti::voiceSources;
using jsti::chrome::scale;

bool jsti_voice_controls_self_test(HWND owner, std::string &error);
bool jsti_voice_usage_self_test(HWND owner, std::string &error);
bool jsti_voice_discovery_self_test(HWND owner, std::string &error);
namespace {
bool markupSelfTest(HWND window, Dialog &source) {
    MarkupConfiguration original = exchangeMarkupConfiguration({});
    bool passed = !canEditMarkup(source);
    const auto originalText = text(window);
    const int originalSource = source.source;
    MarkupConfiguration fixture;
    fixture.enabled = true;
    fixture.examples = {{L"Synthetic & <tag>", L"First synthetic example"},
        {L"Synthetic \u0259 & <other>", L"Second synthetic example"}};
    fixture.wrap = [](const char *input, char *output, size_t capacity, int32_t *utf16, int32_t *scalars) -> int32_t {
        if (!strcmp(input, "Reject")) return -1;
        const std::string text(input);
        const bool wrapped = text.find("<fixture>") != std::string::npos;
        const std::string result = wrapped ? text : "<fixture>" + text + "</fixture>";
        if (result.size() + 1 > capacity) return -1;
        memcpy(output, result.c_str(), result.size() + 1); *utf16 = *scalars = wrapped ? 0 : 9;
        return 0;
    };
    exchangeMarkupConfiguration(fixture);
    source.source = 3; refresh(window, source);
    MarkupDialog helper; helper.owner = window; helper.source = &source; helper.config = fixture;
    std::wstring copied;
    helper.copyContext = &copied;
    helper.copy = [](HWND, const std::wstring &value, void *context) -> bool {
        *static_cast<std::wstring *>(context) = value; return true;
    };
    const std::wstring draft = L"\u03A9 \U0001F600 & <";
    SetDlgItemTextW(window, textID, draft.c_str());
    SendDlgItemMessageW(window, textID, EM_SETSEL, 2, 4);
    HWND popup = makeMarkupDialog(helper);
    passed = popup != nullptr && passed;
    if (popup) {
        SendDlgItemMessageW(popup, markupListID, LB_SETCURSEL, 1, 0);
        SendMessageW(popup, WM_COMMAND, MAKEWPARAM(markupListID, LBN_SELCHANGE), 0);
        SendMessageW(popup, WM_COMMAND, MAKEWPARAM(markupCopyID, BN_CLICKED), 0);
        passed = passed && copied == fixture.examples[1].text && text(window) == draft &&
            (GetWindowLongW(GetDlgItem(popup, markupWrapID), GWL_STYLE) & WS_TABSTOP) &&
            LOWORD(SendMessageW(popup, DM_GETDEFID, 0, 0)) == markupWrapID;
        SendMessageW(popup, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
        DWORD start = 0, end = 0;
        SendDlgItemMessageW(window, textID, EM_GETSEL,
            reinterpret_cast<WPARAM>(&start), reinterpret_cast<LPARAM>(&end));
        passed = passed && text(window) == draft && start == 2 && end == 4;
    }
    popup = makeMarkupDialog(helper);
    if (popup) {
        // The Mac binding wraps the current draft at apply, not a stale open snapshot.
        const std::wstring current = draft + L" newer";
        SetDlgItemTextW(window, textID, current.c_str());
        SendDlgItemMessageW(window, textID, EM_SETSEL, 2, 4);
        SendMessageW(popup, WM_COMMAND, MAKEWPARAM(IDOK, BN_CLICKED), 0);
        DWORD start = 0, end = 0;
        SendDlgItemMessageW(window, textID, EM_GETSEL,
            reinterpret_cast<WPARAM>(&start), reinterpret_cast<LPARAM>(&end));
        passed = passed && !IsWindow(popup) && text(window) == L"<fixture>" + current + L"</fixture>" &&
            start == 11 && end == 13;
        SendDlgItemMessageW(window, textID, EM_UNDO, 0, 0);
        passed = passed && text(window) == current;
    } else passed = false;
    SetDlgItemTextW(window, textID, L"<fixture>Already wrapped</fixture>");
    SendDlgItemMessageW(window, textID, EM_SETSEL, 9, 16);
    popup = makeMarkupDialog(helper);
    if (popup) {
        passed = applyMarkup(popup, helper) && passed;
        DWORD start = 0, end = 0;
        SendDlgItemMessageW(window, textID, EM_GETSEL,
            reinterpret_cast<WPARAM>(&start), reinterpret_cast<LPARAM>(&end));
        passed = passed && text(window) == L"<fixture>Already wrapped</fixture>" && start == 9 && end == 16;
        SetDlgItemTextW(window, textID, L"Reject");
        passed = !applyMarkup(popup, helper) && text(window) == L"Reject" && passed;
        setMarkupEnabled(false);
        refresh(window, source);
        passed = !IsWindowEnabled(GetDlgItem(window, helperID)) &&
            !IsWindowEnabled(GetDlgItem(popup, markupWrapID)) && !applyMarkup(popup, helper) && passed;
        DestroyWindow(popup);
    } else passed = false;
    setMarkupEnabled(true);
    for (int readOnlySource : {0, 2}) {
        source.source = readOnlySource; refresh(window, source);
        passed = !IsWindowEnabled(GetDlgItem(window, helperID)) && !canEditMarkup(source) && passed;
    }
    source.source = 3; source.importToken = "synthetic-helper-import"; refresh(window, source);
    passed = !IsWindowEnabled(GetDlgItem(window, helperID)) && passed;
    source.importToken.clear();
    passed = jsti_window_set_voice_markup_helper(2, nullptr, 0, nullptr) == -1 && passed;
    exchangeMarkupConfiguration(std::move(original));
    source.source = originalSource; SetDlgItemTextW(window, textID, originalText.c_str()); refresh(window, source);
    return passed;
}
}
namespace {
bool formatSelfTest(HWND window, Dialog &dialog) {
    struct Received { std::string request, format, generated; int action = 0; } received;
    const auto callback = dialog.config.callback;
    void *context = dialog.config.context;
    dialog.config.callback = [](int32_t action, int32_t source, const char *text,
                                const char *, const char *path, void *value) {
        auto &result = *static_cast<Received *>(value);
        if (action == 115) result.generated = path;
        if (action == 118 && source == -1) {
            result.action = action; result.format = text; result.request = path;
        }
    };
    dialog.config.context = &received;
    const char *rows = "mp3\tMP3\nm4a\tAAC (M4A)\nwav\tWAV";
    bool passed = jsti_window_set_voice_audio_formats(rows, "wav", "") == 0;
    SendMessageW(window, formatMessage, 0, 0);
    passed = SendDlgItemMessageW(window, formatID, CB_GETCOUNT, 0, 0) == 3 &&
        SendDlgItemMessageW(window, formatID, CB_GETCURSEL, 0, 0) == 2 && passed;
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(generateID, BN_CLICKED), 0);
    passed = received.generated == "2|wav" && passed;
    SendDlgItemMessageW(window, formatID, CB_SETCURSEL, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(formatID, CBN_SELCHANGE), 0);
    passed = received.action == 118 && received.format == "mp3" && received.request == "audio-format" &&
        !IsWindowEnabled(GetDlgItem(window, generateID)) && passed;
    passed = jsti_window_set_voice_audio_formats(rows, "mp3", "Synthetic codec available.") == 0 && passed;
    SendMessageW(window, formatMessage, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(generateID, BN_CLICKED), 0);
    passed = received.generated == "2|mp3" && passed;
    passed = jsti_window_set_voice_generated_result_with_format("synthetic-m4a", 0, "", "m4a") == 0 && passed;
    SendMessageW(window, generationMessage, 2, 0);
    passed = dialog.generation.format == "m4a" && selectedFormat(dialog) == "mp3" &&
        IsWindowEnabled(GetDlgItem(window, exportResultID)) && passed;
    passed = jsti_window_set_voice_audio_formats(rows, "future", "Synthetic unsupported format.") == 0 && passed;
    SendMessageW(window, formatMessage, 0, 0);
    passed = SendDlgItemMessageW(window, formatID, CB_GETCOUNT, 0, 0) == 4 &&
        !IsWindowEnabled(GetDlgItem(window, generateID)) && !IsWindowEnabled(GetDlgItem(window, exportID)) &&
        IsWindowEnabled(GetDlgItem(window, readID)) && IsWindowEnabled(GetDlgItem(window, exportResultID)) && passed;
    dialog.config.callback = callback; dialog.config.context = context;
    return passed;
}
}
bool jsti_voice_sources_self_test(HWND owner, std::string &error) {
    struct Received {
        int calls = 0, source = -1, generated = 0, flags = -1;
        std::string text, record, generateFlags, playedResult;
    } received;
    GenerationState originalGeneration = hostGeneration();
    FormatState originalFormats = exchangeFormats({});
    Dialog dialog;
    dialog.config = hostConfiguration();
    dialog.config.callback = [](int32_t action, int32_t source, const char *value,
                                const char *record, const char *path, void *context) {
        auto &result = *static_cast<Received *>(context);
        if (action == 110) { ++result.calls; result.source = source; result.text = value; result.record = record; }
        if (action == 115) { ++result.generated; result.generateFlags = path; }
        if (action == 116) result.playedResult = record;
        if (action == 118) result.flags = source;
    };
    dialog.config.context = &received;
    dialog.record = "synthetic-record"; dialog.history = L"Synthetic History snapshot";
    HWND window = makeDialog(owner, dialog);
    if (!window) {
        exchangeFormats(std::move(originalFormats));
        error = "Voice sources fixture could not open."; return false;
    }
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
        captured = jsti_owned_window_save_snapshot(window, path.c_str(), failure, sizeof(failure)) == 0;
        if (!captured) error = failure;
    }
    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, 2, 0); select(window, dialog);
    const bool unavailable = !IsWindowEnabled(GetDlgItem(window, readID)) &&
        !IsWindowEnabled(GetDlgItem(window, exportID)) && text(window).empty() &&
        SendDlgItemMessageW(window, sourceID, CB_GETCOUNT, 0, 0) == 4;
    dialog.clipboard = L"Synthetic clipboard snapshot";
    SetDlgItemTextW(window, textID, dialog.clipboard.c_str());
    refresh(window, dialog);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(readID, BN_CLICKED), 0);
    const bool clipboardSnapshot = received.calls == 3 && received.source == 2 &&
        received.record.empty() && received.text == "Synthetic clipboard snapshot";
    SendDlgItemMessageW(window, sourceID, CB_SETCURSEL, 3, 0); select(window, dialog);
    dialog.importToken = "synthetic-import";
    expectImport(window, dialog.importToken);
    const bool queuedImport = jsti_window_set_voice_text_import("synthetic-import", "Synthetic file text", "") == 0;
    SendMessageW(window, importResultMessage, 0, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(readID, BN_CLICKED), 0);
    const bool fileSnapshot = queuedImport && received.calls == 4 && received.source == 4 &&
        received.record.empty() && received.text == "Synthetic file text" &&
        !(GetWindowLongW(GetDlgItem(window, textID), GWL_STYLE) & ES_READONLY);
    const bool staleImport = jsti_window_set_voice_text_import("synthetic-import", "Stale text", "") == 1 &&
        text(window) == L"Synthetic file text";
    if (length && length < snapshotPath.size()) {
        const std::string path = jsti::utf8(snapshotPath.data()) + ".file-source.bmp";
        char failure[1024]{};
        captured = jsti_owned_window_save_snapshot(window, path.c_str(), failure, sizeof(failure)) == 0 && captured;
        if (!captured && failure[0]) error = failure;
    }
    dialog.importToken = "synthetic-failure";
    expectImport(window, dialog.importToken);
    jsti_window_set_voice_text_import("synthetic-failure", "", "Synthetic read error.");
    SendMessageW(window, importResultMessage, 0, 0);
    const bool failedImport = text(window) == L"Synthetic file text" && IsWindowEnabled(GetDlgItem(window, readID));
    dialog.importToken = "synthetic-edit";
    expectImport(window, dialog.importToken);
    SetDlgItemTextW(window, textID, L"Synthetic user edit");
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(textID, EN_CHANGE), 0);
    const bool editedImport = jsti_window_set_voice_text_import("synthetic-edit", "Late text", "") == 1 &&
        text(window) == L"Synthetic user edit";
    jsti_window_set_voice_generation_options(2);
    SendMessageW(window, generationMessage, 1, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(saveID, BN_CLICKED), 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(generateID, BN_CLICKED), 0);
    const bool generatedSnapshot = received.generated == 1 && received.generateFlags == "2" && received.flags == 2;
    jsti_window_set_voice_generated_result("synthetic-result", 1, "Synthetic generating state");
    SendMessageW(window, generationMessage, 2, 0);
    const bool busyResult = !IsWindowEnabled(GetDlgItem(window, generateID)) &&
        !IsWindowEnabled(GetDlgItem(window, playResultID));
    jsti_window_set_voice_generated_result("synthetic-result", 0, "Synthetic retained result");
    SendMessageW(window, generationMessage, 2, 0);
    SendMessageW(window, WM_COMMAND, MAKEWPARAM(playResultID, BN_CLICKED), 0);
    const bool retainedResult = received.playedResult == "synthetic-result" &&
        IsWindowEnabled(GetDlgItem(window, exportResultID));
    const bool markup = markupSelfTest(window, dialog) &&
        received.calls == 4 && received.generated == 1 && received.flags == 2;
    const bool formats = formatSelfTest(window, dialog);
    RECT minimum{0, 0, scale(window, 620), scale(window, 540)};
    AdjustWindowRectExForDpi(&minimum, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_CONTROLPARENT, GetDpiForWindow(window));
    SetWindowPos(window, nullptr, 0, 0, minimum.right - minimum.left, minimum.bottom - minimum.top,
        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    RECT client{}; GetClientRect(window, &client);
    bool boundedControls = true;
    for (HWND control : dialog.controls) {
        RECT bounds{}; GetWindowRect(control, &bounds);
        MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&bounds), 2);
        boundedControls = boundedControls && bounds.left >= 0 && bounds.top >= 0 &&
            bounds.right <= client.right && bounds.bottom <= client.bottom;
    }
    DestroyWindow(window);
    replaceGeneration(std::move(originalGeneration));
    exchangeFormats(std::move(originalFormats));
    const bool passed = history && typed && unavailable && historySnapshot && typedSnapshot &&
        clipboardSnapshot && fileSnapshot && staleImport && failedImport && editedImport &&
        generatedSnapshot && busyResult && retainedResult && boundedControls && markup && formats;
    if (!passed) {
        error = "Voice sources fixture failed: history=" + std::to_string(history) +
            ", typed=" + std::to_string(typed) + ", unloadedClipboard=" + std::to_string(unavailable) +
            ", historySnapshot=" + std::to_string(historySnapshot) +
            ", typedSnapshot=" + std::to_string(typedSnapshot) +
            ", clipboardSnapshot=" + std::to_string(clipboardSnapshot) +
            ", fileSnapshot=" + std::to_string(fileSnapshot) + ", staleImport=" + std::to_string(staleImport) +
            ", failedImport=" + std::to_string(failedImport) + ", editedImport=" + std::to_string(editedImport) +
            ", generatedSnapshot=" + std::to_string(generatedSnapshot) + ", busyResult=" + std::to_string(busyResult) +
            ", retainedResult=" + std::to_string(retainedResult) +
            ", boundedControls=" + std::to_string(boundedControls) + ", markup=" + std::to_string(markup) +
            ", formats=" + std::to_string(formats) + ".";
    }
    return passed && captured && jsti_voice_controls_self_test(owner, error) &&
        jsti_voice_usage_self_test(owner, error) && jsti_voice_discovery_self_test(owner, error);
}
