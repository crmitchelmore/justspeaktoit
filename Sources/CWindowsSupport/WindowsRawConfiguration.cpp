#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <commdlg.h>
#include <algorithm>
#include <cstring>
#include <exception>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

// General > App behaviour > "Edit raw configuration" (#1670): every setting as
// JSON, checked and saved by the shared host (DesktopHostRawConfiguration)
// with the same schema and validator as macOS, iOS, Android and `speak
// config`. This window only edits text and picks files; each action is
// JSTI_EVENT_RAW_CONFIGURATION with its DesktopRawConfigurationAction as the
// model index, and the host answers through jsti_window_set_raw_configuration,
// from any thread, in the order it was asked.

namespace {
enum Control {
    descriptionID = 1100, editorLabelID, editorID, statusID, issuesLabelID, issuesID, resetID, importID, exportID,
    validateID, applyID
};
enum Action { loadAction = 0, validateAction, applyAction, defaultsAction, importAction, exportAction };
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 640, minimumClientHeight = 480;
constexpr UINT outcomeMessage = WM_APP + 43;
// The host refuses imports over 1 MB; leave room for its reformatting.
constexpr size_t maximumText = 4u << 20;
const wchar_t *const exportName = L"JustSpeakToIt-settings.json";

struct Outcome {
    bool hasText = false, failed = false;
    std::wstring text, status, issues, announcement;
};

using Emit = void (*)(HWND owner, int action, const char *text);
using Choose = bool (*)(HWND window, bool saving, std::wstring &path);

struct Dialog {
    HWND owner = nullptr;
    Emit emit = nullptr;
    Choose choose = nullptr;
    HFONT font = nullptr, mono = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    // This window's unanswered requests; actions wait for them.
    int outstanding = 0;
    bool loaded = false;
};

std::mutex outcomeMutex;
std::vector<Outcome> pending;
HWND active = nullptr;
// Requests sent and not yet answered, and how many of those answers belong to
// a window that has since closed and are dropped.
int unanswered = 0, discard = 0;

using jsti::chrome::scale;

// The EDIT control needs CRLF; the host speaks LF.
std::wstring editLines(const std::wstring &text) {
    std::wstring result;
    result.reserve(text.size() + text.size() / 16);
    for (wchar_t character : text) {
        if (character == L'\r') continue;
        if (character == L'\n') result += L'\r';
        result += character;
    }
    return result;
}

std::wstring hostLines(std::wstring text) {
    std::wstring result;
    result.reserve(text.size());
    for (wchar_t character : text) if (character != L'\r') result += character;
    return result;
}

std::wstring controlText(HWND window, int id) {
    HWND control = GetDlgItem(window, id);
    std::wstring text(static_cast<size_t>(GetWindowTextLengthW(control)) + 1, L'\0');
    text.resize(static_cast<size_t>(GetWindowTextW(control, &text[0], static_cast<int>(text.size()))));
    return text;
}

bool issuesShown(HWND window) { return GetWindowTextLengthW(GetDlgItem(window, issuesID)) > 0; }

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), gap = at(8), button = at(32), width = static_cast<int>(bounds.right) - 2 * margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    int y = margin;
    move(descriptionID, margin, y, width, at(40));
    y += at(40) + gap;
    move(editorLabelID, margin, y, width, at(20));
    y += at(22);
    const int buttons = static_cast<int>(bounds.bottom) - margin - button;
    const bool issues = issuesShown(window);
    const int issuesHeight = issues ? at(22) + at(84) + gap : 0;
    const int status = buttons - gap - at(24) - issuesHeight;
    move(editorID, margin, y, width, std::max(at(80), status - gap - y));
    move(statusID, margin, status, width, at(24));
    ShowWindow(GetDlgItem(window, issuesLabelID), issues ? SW_SHOW : SW_HIDE);
    ShowWindow(GetDlgItem(window, issuesID), issues ? SW_SHOW : SW_HIDE);
    if (issues) {
        move(issuesLabelID, margin, status + at(24) + gap, width, at(20));
        move(issuesID, margin, status + at(24) + gap + at(22), width, at(84));
    }
    int x = margin;
    const std::pair<int, int> leading[] = {{resetID, 150}, {importID, 100}, {exportID, 100}};
    for (const auto &[id, w] : leading) { move(id, x, buttons, at(w), button); x += at(w) + gap; }
    x = static_cast<int>(bounds.right) - margin;
    const std::pair<int, int> trailing[] = {{applyID, 100}, {validateID, 100}, {IDCANCEL, 90}};
    for (const auto &[id, w] : trailing) { x -= at(w); move(id, x, buttons, at(w), button); x -= gap; }
}

void refreshFont(HWND window, Dialog &dialog) {
    jsti::chrome::refreshDialogFont(window, dialog.controls, dialog.font);
    HFONT mono = CreateFontW(-MulDiv(10, static_cast<int>(GetDpiForWindow(window)), 72), 0, 0, 0, FW_NORMAL, FALSE,
        FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH,
        L"Consolas");
    if (!mono) return;
    for (int id : {editorID, issuesID})
        SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(mono), TRUE);
    if (dialog.mono) DeleteObject(dialog.mono);
    dialog.mono = mono;
}

void updateEnabled(HWND window, const Dialog &dialog) {
    const bool idle = dialog.outstanding == 0;
    for (int id : {resetID, importID, exportID, validateID}) EnableWindow(GetDlgItem(window, id), idle);
    EnableWindow(GetDlgItem(window, applyID), idle && dialog.loaded);
}

void show(HWND window, Dialog &dialog, const Outcome &outcome) {
    if (outcome.hasText) {
        SetDlgItemTextW(window, editorID, editLines(outcome.text).c_str());
        dialog.loaded = true;
    }
    SetDlgItemTextW(window, statusID, outcome.status.c_str());
    SetDlgItemTextW(window, issuesID, editLines(outcome.issues).c_str());
    layout(window);
    updateEnabled(window, dialog);
    const std::wstring &spoken = outcome.announcement.empty() ? outcome.status : outcome.announcement;
    if (!spoken.empty()) jsti::accessibility::announce(GetDlgItem(window, statusID), spoken, outcome.failed);
}

void localError(HWND window, Dialog &dialog, const wchar_t *status, const wchar_t *issue) {
    Outcome outcome;
    outcome.failed = true;
    outcome.status = status;
    outcome.issues = std::wstring(L"Error: ") + issue;
    outcome.announcement = std::wstring(status) + L" " + issue;
    show(window, dialog, outcome);
}

void request(HWND window, Dialog &dialog, int action, const std::string &text) {
    {
        std::lock_guard<std::mutex> lock(outcomeMutex);
        ++unanswered;
    }
    ++dialog.outstanding;
    updateEnabled(window, dialog);
    dialog.emit(dialog.owner, action, text.c_str());
}

std::string editorJSON(HWND window) { return jsti::utf8(hostLines(controlText(window, editorID))); }

bool chooseFile(HWND window, bool saving, std::wstring &path) {
    std::vector<wchar_t> buffer(32768, L'\0');
    if (saving) std::wstring(exportName).copy(buffer.data(), buffer.size() - 1);
    OPENFILENAMEW chooser{};
    chooser.lStructSize = sizeof(chooser);
    chooser.hwndOwner = window;
    chooser.lpstrFilter = L"JSON (*.json)\0*.json\0All files (*.*)\0*.*\0\0";
    chooser.lpstrFile = buffer.data();
    chooser.nMaxFile = static_cast<DWORD>(buffer.size());
    chooser.lpstrDefExt = L"json";
    chooser.Flags = OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST | (saving ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    if (!(saving ? GetSaveFileNameW(&chooser) : GetOpenFileNameW(&chooser))) return false;
    path = buffer.data();
    return true;
}

void transfer(HWND window, Dialog &dialog, bool saving) {
    std::wstring path;
    if (!dialog.choose(window, saving, path)) {
        if (dialog.choose == chooseFile && CommDlgExtendedError() != 0)
            localError(window, dialog, L"Nothing was changed.", L"The file dialog could not be opened.");
        return;
    }
    if (path.empty() || path.find_first_of(L"\r\n") != std::wstring::npos) {
        localError(window, dialog, saving ? L"Could not export." : L"Could not import.",
                   L"Choose a file whose name has no line breaks.");
        return;
    }
    if (saving) request(window, dialog, exportAction, jsti::utf8(path) + "\n" + editorJSON(window));
    else request(window, dialog, importAction, jsti::utf8(path));
}

void deliver(HWND window, Dialog &dialog) {
    std::vector<Outcome> ready;
    {
        std::lock_guard<std::mutex> lock(outcomeMutex);
        ready.swap(pending);
    }
    for (const Outcome &outcome : ready) {
        if (dialog.outstanding > 0) --dialog.outstanding;
        show(window, dialog, outcome);
    }
}

bool createControls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id, DWORD extended = 0) {
        HWND control = CreateWindowExW(extended, kind, text, WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    // Each field's label comes right before it, so UI Automation names the field.
    const bool okay =
        add(L"STATIC", L"Every setting as JSON, checked against the same schema as the Mac, iPhone and Android "
            L"apps. Validate checks it; Apply saves all of it or nothing. API keys are never shown or imported.",
            SS_LEFT | SS_NOPREFIX, descriptionID) &&
        add(L"STATIC", L"Raw configuration &JSON", 0, editorLabelID) &&
        add(L"EDIT", L"", ES_MULTILINE | ES_AUTOVSCROLL | ES_AUTOHSCROLL | ES_WANTRETURN | ES_NOHIDESEL |
            WS_VSCROLL | WS_HSCROLL | WS_TABSTOP | WS_GROUP, editorID, WS_EX_CLIENTEDGE) &&
        add(L"STATIC", L"Loading…", SS_LEFT | SS_NOPREFIX, statusID) &&
        add(L"STATIC", L"Is&sues", 0, issuesLabelID) &&
        add(L"EDIT", L"", ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY | WS_VSCROLL | WS_TABSTOP, issuesID,
            WS_EX_CLIENTEDGE) &&
        add(L"BUTTON", L"Reset to &Defaults", BS_PUSHBUTTON | WS_TABSTOP | WS_GROUP, resetID) &&
        add(L"BUTTON", L"&Import…", BS_PUSHBUTTON | WS_TABSTOP, importID) &&
        add(L"BUTTON", L"E&xport…", BS_PUSHBUTTON | WS_TABSTOP, exportID) &&
        add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, IDCANCEL) &&
        add(L"BUTTON", L"&Validate", BS_DEFPUSHBUTTON | WS_TABSTOP, validateID) &&
        add(L"BUTTON", L"&Apply", BS_PUSHBUTTON | WS_TABSTOP, applyID);
    if (!okay) return false;
    SendDlgItemMessageW(window, editorID, EM_SETLIMITTEXT, static_cast<WPARAM>(maximumText), 0);
    refreshFont(window, dialog);
    {
        std::lock_guard<std::mutex> lock(outcomeMutex);
        active = window;
        pending.clear();
    }
    layout(window);
    request(window, dialog, loadAction, "");
    return true;
}

void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

constexpr jsti::chrome::DialogFrame dialogFrame{
    minimumClientWidth, minimumClientHeight, windowStyle, windowExStyle, editorID, validateID};

bool handle(HWND window, Dialog &dialog, UINT message, WPARAM wparam, LPARAM, LRESULT &) {
    switch (message) {
    case outcomeMessage: deliver(window, dialog); return true;
    case WM_COMMAND: {
        if (HIWORD(wparam) != BN_CLICKED) return false;
        const int id = LOWORD(wparam);
        if (id == IDCANCEL) { close(window); return true; }
        if (!IsWindowEnabled(GetDlgItem(window, id))) return true;
        switch (id) {
        case validateID: request(window, dialog, validateAction, editorJSON(window)); return true;
        case applyID: request(window, dialog, applyAction, editorJSON(window)); return true;
        case resetID: request(window, dialog, defaultsAction, ""); return true;
        case importID: transfer(window, dialog, false); return true;
        case exportID: transfer(window, dialog, true); return true;
        default: return true;
        }
    }
    case WM_DESTROY: {
        std::lock_guard<std::mutex> lock(outcomeMutex);
        if (active == window) {
            active = nullptr;
            pending.clear();
            // Answers still on their way belong to this window; drop them.
            discard = unanswered;
        }
    }
        if (dialog.mono) { DeleteObject(dialog.mono); dialog.mono = nullptr; }
        return false;
    default: return false;
    }
}

const jsti::chrome::DialogProcedure<Dialog> dialogParts{dialogFrame, layout, refreshFont, createControls, close, handle};

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    return jsti::chrome::dialogProcedure(dialogParts, window, message, wparam, lparam);
}

HWND createDialog(HWND owner, Dialog &dialog) {
    return jsti::chrome::createOwnedDialog(owner, L"JustSpeakToItRawConfiguration", procedure,
        L"Edit raw configuration — Just Speak to It", 760, 640, windowStyle, windowExStyle, &dialog);
}
} // namespace

int32_t jsti_window_set_raw_configuration(
    const char *text, const char *status, const char *issues, const char *announcement, int32_t failed) {
    try {
        Outcome outcome;
        outcome.hasText = text != nullptr;
        outcome.failed = failed != 0;
        if ((text && (strlen(text) > maximumText || !jsti::wide(text, outcome.text))) ||
            (status && !jsti::wide(status, outcome.status)) || (issues && !jsti::wide(issues, outcome.issues)) ||
            (announcement && !jsti::wide(announcement, outcome.announcement))) return -1;
        std::lock_guard<std::mutex> lock(outcomeMutex);
        if (unanswered > 0) --unanswered;
        if (discard > 0) { --discard; return 0; }
        if (!active) return 0;
        pending.push_back(std::move(outcome));
        PostMessageW(active, outcomeMessage, 0, 0);
    } catch (const std::exception &) { return -1; }
    return 0;
}

void jsti_show_raw_configuration(HWND owner, void (*emit)(HWND owner, int action, const char *text)) {
    {
        std::lock_guard<std::mutex> lock(outcomeMutex);
        if (active) { SetForegroundWindow(active); return; }
    }
    Dialog dialog;
    dialog.owner = owner;
    dialog.emit = emit;
    dialog.choose = chooseFile;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening Edit raw configuration").c_str(), nullptr, -1);
        return;
    }
    jsti::chrome::runModalDialog(owner, window, editorID, close, "Edit raw configuration");
}

// ---- self-test -------------------------------------------------------------

namespace {
struct Requested { int calls = 0, action = -1; std::string text; };
Requested *requested = nullptr;
std::wstring chosenPath;
} // namespace

// Load on open, Apply waiting for it, every action's request, a refused
// answer keeping the typed JSON with its issues shown, local refusal of a
// path with a line break, the accessibility audit, and dropping answers to a
// closed window.
bool jsti_raw_configuration_self_test(HWND owner, std::string &error) {
    Requested observed;
    requested = &observed;
    bool passed = false;
    std::string step;
    try {
        Dialog dialog;
        dialog.owner = owner;
        dialog.emit = [](HWND, int action, const char *text) {
            if (!requested) return;
            ++requested->calls;
            requested->action = action;
            requested->text = text ? text : "";
        };
        dialog.choose = [](HWND, bool, std::wstring &path) { path = chosenPath; return !path.empty(); };
        HWND window = createDialog(owner, dialog);
        if (!window) {
            requested = nullptr;
            error = jsti::systemError("Creating the raw configuration fixture");
            return false;
        }
        auto drain = [&] {
            MSG message{};
            while (PeekMessageW(&message, window, outcomeMessage, outcomeMessage, PM_REMOVE)) DispatchMessageW(&message);
        };
        auto enabled = [&](int id) { return IsWindowEnabled(GetDlgItem(window, id)) != FALSE; };
        auto shown = [&](int id) { return (GetWindowLongPtrW(GetDlgItem(window, id), GWL_STYLE) & WS_VISIBLE) != 0; };
        auto click = [&](int id) {
            SendMessageW(window, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED), reinterpret_cast<LPARAM>(GetDlgItem(window, id)));
        };
        auto check = [&](bool ok, const char *name) {
            if (!ok && step.empty()) step = name;
            return ok;
        };
        passed = check(observed.calls == 1 && observed.action == loadAction, "opening did not load");
        passed = check(!enabled(applyID) && !enabled(validateID), "actions were offered before the load answered") &&
            passed;
        passed = check(jsti_window_set_raw_configuration("{\n  \"settings\" : {}\n}", "", "", "", 0) == 0 &&
            jsti_window_set_raw_configuration("\xff", "", "", "", 0) == -1, "answers were not checked") && passed;
        drain();
        passed = check(controlText(window, editorID) == L"{\r\n  \"settings\" : {}\r\n}" && enabled(applyID) &&
            !shown(issuesID), "the loaded document was not shown") && passed;
        SetDlgItemTextW(window, editorID, L"{ bad");
        click(applyID);
        passed = check(observed.calls == 2 && observed.action == applyAction && observed.text == "{ bad" &&
            !enabled(applyID), "Apply did not send the editor's JSON once") && passed;
        jsti_window_set_raw_configuration(nullptr, "The configuration is not valid. Nothing was saved.",
            "Error: Expected a value.\nWarning: Unknown key.", "The configuration is not valid.", 1);
        drain();
        passed = check(controlText(window, editorID) == L"{ bad" && shown(issuesID) && shown(issuesLabelID) &&
            controlText(window, issuesID) == L"Error: Expected a value.\r\nWarning: Unknown key." &&
            controlText(window, statusID) == L"The configuration is not valid. Nothing was saved.",
            "a refused Apply lost the typed JSON or hid its issues") && passed;
        click(validateID);
        passed = check(observed.action == validateAction && observed.text == "{ bad", "Validate was not sent") && passed;
        jsti_window_set_raw_configuration(nullptr, "Valid.", "", "", 0);
        drain();
        passed = check(!shown(issuesID), "issues stayed after a clean answer") && passed;
        click(resetID);
        passed = check(observed.action == defaultsAction, "Reset to Defaults was not sent") && passed;
        jsti_window_set_raw_configuration("{}", "Defaults loaded. Apply to save them.", "", "", 0);
        drain();
        chosenPath = L"C:\\Settings\\import.json";
        click(importID);
        passed = check(observed.action == importAction && observed.text == "C:\\Settings\\import.json",
            "Import did not send the chosen path") && passed;
        jsti_window_set_raw_configuration("{}", "Valid. Nothing to change.", "", "", 0);
        drain();
        chosenPath = L"C:\\Settings\\export.json";
        click(exportID);
        passed = check(observed.action == exportAction && observed.text == "C:\\Settings\\export.json\n{}",
            "Export did not send the path and the JSON") && passed;
        jsti_window_set_raw_configuration(nullptr, "Exported to export.json.", "", "", 0);
        drain();
        const int before = observed.calls;
        chosenPath = L"C:\\Settings\\a\nb.json";
        click(exportID);
        passed = check(observed.calls == before && shown(issuesID), "a path with a line break was sent") && passed;
        std::string auditFailure;
        passed = check(jsti::accessibility::audit(window, auditFailure) > 0, "the accessibility audit failed") &&
            passed;
        if (!auditFailure.empty() && step == "the accessibility audit failed") step = auditFailure;
        click(validateID);
        DestroyWindow(window);
        passed = check(jsti_window_set_raw_configuration(nullptr, "Late.", "", "", 0) == 0, "a late answer failed") &&
            passed;
        {
            std::lock_guard<std::mutex> lock(outcomeMutex);
            passed = check(unanswered == 0 && discard == 0 && pending.empty() && !active,
                "the window lost count of its requests") && passed;
        }
    } catch (const std::exception &) { step = "the fixture could not allocate"; passed = false; }
    {
        std::lock_guard<std::mutex> lock(outcomeMutex);
        unanswered = discard = 0;
        pending.clear();
        active = nullptr;
    }
    requested = nullptr;
    chosenPath.clear();
    if (!passed) error = "Raw configuration fixture failed: " + step + ".";
    return passed;
}
