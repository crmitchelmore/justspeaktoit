#include "include/CWindowsSupport.h"
#include "WindowsLoginItem.hpp"
#include "WindowsSupportInternal.hpp"
#include <exception>
#include <mutex>
#include <utility>
#include <vector>

// Native "CLI and MCP setup" dialog: whether automation is on, the same-user
// pipe `speak` connects to, and copyable `speak` commands, MCP client
// configuration and Claude Code registration built by the host from the
// installed speak.exe. Turning automation on or off goes through the window's
// AUTOMATION_TOGGLED event, so consent and the pipe's security are unchanged.
// No credential passes through this dialog or the copied text.

namespace {
enum Control {
    statusID = 1000, toggleID, securityID, cliLabelID, cliID, copyCliID, copyPipeID, mcpLabelID, mcpID,
    claudeID, copyMcpID, copyClaudeID, problemID
};
constexpr DWORD windowStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
constexpr DWORD windowExStyle = WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT;
constexpr int minimumClientWidth = 600, minimumClientHeight = 560;
constexpr size_t maximumDetailLength = 16384;
constexpr UINT_PTR refreshTimer = 1;

struct Configuration {
    std::string pipeName, cliPath, usage, mcp, claude;
};
std::mutex configurationMutex;
Configuration configuration;

using CopyText = int (*)(const char *text, char *error, size_t capacity);

struct Dialog {
    Configuration config;
    bool (*enabled)() = nullptr;
    void (*toggle)(HWND owner) = nullptr;
    CopyText copy = jsti_clipboard_write;
    HWND owner = nullptr;
    HFONT font = nullptr, code = nullptr;
    HWND focus = nullptr;
    std::vector<HWND> controls;
    int shown = -1;
};

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

std::wstring wideText(const std::string &text) {
    std::wstring result;
    if (!jsti::wide(text.c_str(), result)) return {};
    return result;
}

// Edit controls show line breaks only as CR LF.
std::wstring editText(const std::string &text) {
    const std::wstring value = wideText(text);
    std::wstring result;
    result.reserve(value.size() + value.size() / 16);
    for (wchar_t character : value) {
        if (character == L'\n' && (result.empty() || result.back() != L'\r')) result.push_back(L'\r');
        result.push_back(character);
    }
    return result;
}

void layout(HWND window) {
    RECT bounds{};
    GetClientRect(window, &bounds);
    auto at = [&](int value) { return scale(window, value); };
    const int margin = at(20), button = at(30), gap = at(8), label = at(22), line = at(26), wide = at(210);
    const int right = static_cast<int>(bounds.right) - margin, bottom = static_cast<int>(bounds.bottom) - margin;
    const int width = right - margin;
    auto move = [&](int id, int x, int y, int w, int h) { MoveWindow(GetDlgItem(window, id), x, y, w, h, TRUE); };
    int y = at(16);
    move(statusID, margin, y, width - wide - gap, at(48));
    move(toggleID, right - wide, y, wide, button);
    y += at(52);
    move(securityID, margin, y, width, at(64));
    y += at(68);
    const int fixed = 2 * (label + gap) + 2 * (button + gap) + line + gap + label + gap + button;
    const int edits = std::max(at(120), bottom - y - fixed);
    const int cliHeight = edits * 2 / 5, mcpHeight = edits - cliHeight;
    move(cliLabelID, margin, y, width, label);
    y += label + gap;
    move(cliID, margin, y, width, cliHeight);
    y += cliHeight + gap;
    move(copyCliID, margin, y, wide, button);
    move(copyPipeID, margin + wide + gap, y, wide, button);
    y += button + gap;
    move(mcpLabelID, margin, y, width, label);
    y += label + gap;
    move(mcpID, margin, y, width, mcpHeight);
    y += mcpHeight + gap;
    move(claudeID, margin, y, width, line);
    y += line + gap;
    move(copyMcpID, margin, y, wide, button);
    move(copyClaudeID, margin + wide + gap, y, wide, button);
    const int closeWidth = at(100);
    move(problemID, margin, bottom - button, width - closeWidth - gap, button);
    move(IDCANCEL, right - closeWidth, bottom - button, closeWidth, button);
}

HFONT createFont(HWND window, const wchar_t *face, int points) {
    return CreateFontW(-MulDiv(points, static_cast<int>(GetDpiForWindow(window)), 72), 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, face);
}

void refreshFont(HWND window, Dialog &dialog) {
    HFONT font = createFont(window, L"Segoe UI", 10);
    HFONT code = createFont(window, L"Consolas", 10);
    if (!font || !code) {
        if (font) DeleteObject(font);
        if (code) DeleteObject(code);
        return;
    }
    for (HWND control : dialog.controls) {
        const int id = GetDlgCtrlID(control);
        const bool literal = id == cliID || id == mcpID || id == claudeID;
        SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(literal ? code : font), TRUE);
    }
    if (dialog.font) DeleteObject(dialog.font);
    if (dialog.code) DeleteObject(dialog.code);
    dialog.font = font;
    dialog.code = code;
}

/// Shows the state the host last reported; the window's switch and this
/// dialog read the same value, so they never disagree.
void refresh(HWND window, Dialog &dialog) {
    const int enabled = dialog.enabled && dialog.enabled() ? 1 : 0;
    if (enabled == dialog.shown) return;
    dialog.shown = enabled;
    std::wstring status;
    if (enabled) {
        const std::wstring pipe = dialog.config.pipeName.empty()
            ? std::wstring(L"this user's automation pipe") : wideText(dialog.config.pipeName);
        status = L"Automation is on. The speak command and MCP clients reach this app over " + pipe + L".";
    } else {
        status = L"Automation is off. Nothing can control this app until you turn it on here or in General.";
    }
    SetDlgItemTextW(window, statusID, status.c_str());
    SetDlgItemTextW(window, toggleID, enabled ? L"Turn automation &off" : L"Turn automation &on");
}

bool createControls(HWND window, Dialog &dialog) {
    auto add = [&](const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
        HWND control = CreateWindowExW(wcscmp(kind, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, kind, text,
            WS_CHILD | WS_VISIBLE | style, 0, 0, 10, 10, window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
            GetModuleHandleW(nullptr), nullptr);
        if (control) dialog.controls.push_back(control);
        return control != nullptr;
    };
    const bool installed = !dialog.config.cliPath.empty();
    const std::wstring cliLabel = installed
        ? L"speak commands (PowerShell), using " + wideText(dialog.config.cliPath)
        : std::wstring(L"The speak command was not found for this installation.");
    const std::wstring usage = editText(dialog.config.usage), mcp = editText(dialog.config.mcp);
    const std::wstring claude = wideText(dialog.config.claude);
    constexpr DWORD literal = ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | ES_AUTOHSCROLL | WS_VSCROLL |
        WS_HSCROLL | WS_TABSTOP;
    const bool okay =
        add(L"STATIC", L"", SS_LEFT, statusID) &&
        add(L"BUTTON", L"Turn automation &on", BS_PUSHBUTTON | WS_TABSTOP, toggleID) &&
        add(L"STATIC", L"While automation is on, any program running as you on this PC can start the microphone "
            L"and read your transcription history. The pipe admits your Windows account alone and refuses network "
            L"and lower-integrity clients. Requests carry no API keys. Automation stays off until you turn it on.",
            SS_LEFT, securityID) &&
        add(L"STATIC", cliLabel.c_str(), SS_LEFTNOWORDWRAP | SS_PATHELLIPSIS, cliLabelID) &&
        add(L"EDIT", usage.c_str(), literal, cliID) &&
        add(L"BUTTON", L"Copy &commands", BS_PUSHBUTTON | WS_TABSTOP, copyCliID) &&
        add(L"BUTTON", L"Copy &pipe name", BS_PUSHBUTTON | WS_TABSTOP, copyPipeID) &&
        add(L"STATIC", L"MCP client configuration (Claude Desktop, VS Code, GitHub Copilot and other MCP clients)",
            SS_LEFT, mcpLabelID) &&
        add(L"EDIT", mcp.c_str(), literal, mcpID) &&
        add(L"EDIT", claude.c_str(), ES_READONLY | ES_AUTOHSCROLL | WS_TABSTOP, claudeID) &&
        add(L"BUTTON", L"Copy &MCP configuration", BS_PUSHBUTTON | WS_TABSTOP, copyMcpID) &&
        add(L"BUTTON", L"Copy C&laude Code command", BS_PUSHBUTTON | WS_TABSTOP, copyClaudeID) &&
        add(L"STATIC", L"", SS_LEFT, problemID) &&
        add(L"BUTTON", L"Close", BS_DEFPUSHBUTTON | WS_GROUP | WS_TABSTOP, IDCANCEL);
    if (!okay) return false;
    for (int id : {cliID, copyCliID, mcpID, claudeID, copyMcpID, copyClaudeID}) {
        EnableWindow(GetDlgItem(window, id), installed);
    }
    EnableWindow(GetDlgItem(window, copyPipeID), !dialog.config.pipeName.empty());
    if (!installed) {
        SetDlgItemTextW(window, problemID, L"Expected speak.exe beside the app, or the package's CLI alias.");
    }
    refreshFont(window, dialog);
    layout(window);
    refresh(window, dialog);
    return true;
}

void copy(HWND window, Dialog &dialog, const std::string &text, const wchar_t *what) {
    if (text.empty() || !dialog.copy) return;
    char problem[512] = {};
    std::wstring result;
    if (dialog.copy(text.c_str(), problem, sizeof(problem)) == 0) {
        result = std::wstring(L"Copied the ") + what + L".";
    } else if (!problem[0] || !jsti::wide(problem, result) || result.empty()) {
        result = L"The clipboard is unavailable. Select the text and copy it instead.";
    }
    SetDlgItemTextW(window, problemID, result.c_str());
}

void close(HWND window) {
    const HWND owner = GetWindow(window, GW_OWNER);
    if (owner) EnableWindow(owner, TRUE);
    DestroyWindow(window);
}

void command(HWND window, Dialog &dialog, int id) {
    switch (id) {
    case toggleID:
        // The host reports the state reached; the refresh timer shows it.
        if (dialog.toggle) dialog.toggle(dialog.owner);
        return;
    case copyCliID: copy(window, dialog, dialog.config.usage, L"speak commands"); return;
    case copyPipeID: copy(window, dialog, dialog.config.pipeName, L"pipe name"); return;
    case copyMcpID: copy(window, dialog, dialog.config.mcp, L"MCP configuration"); return;
    case copyClaudeID: copy(window, dialog, dialog.config.claude, L"Claude Code command"); return;
    case IDCANCEL: close(window); return;
    }
}

LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto dialog = reinterpret_cast<Dialog *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        dialog = static_cast<Dialog *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(dialog));
    }
    if (!dialog) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE:
        if (!createControls(window, *dialog)) return -1;
        SetTimer(window, refreshTimer, 250, nullptr);
        return 0;
    case WM_TIMER:
        if (wparam == refreshTimer) refresh(window, *dialog);
        return 0;
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
        SetFocus(dialog->focus && IsChild(window, dialog->focus) ? dialog->focus : GetDlgItem(window, toggleID));
        return 0;
    case DM_GETDEFID: return MAKELRESULT(IDCANCEL, DC_HASDEFID);
    case WM_COMMAND:
        if (HIWORD(wparam) == BN_CLICKED) command(window, *dialog, LOWORD(wparam));
        return 0;
    case WM_CLOSE: close(window); return 0;
    case WM_DESTROY:
        KillTimer(window, refreshTimer);
        if (dialog->font) { DeleteObject(dialog->font); dialog->font = nullptr; }
        if (dialog->code) { DeleteObject(dialog->code); dialog->code = nullptr; }
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

HWND createDialog(HWND owner, Dialog &dialog) {
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItAutomationSettings";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    dialog.owner = owner;
    RECT frame{0, 0, scale(owner, 680), scale(owner, 600)};
    AdjustWindowRectExForDpi(&frame, windowStyle, FALSE, windowExStyle, GetDpiForWindow(owner));
    RECT bounds{};
    GetWindowRect(owner, &bounds);
    return CreateWindowExW(windowExStyle, type.lpszClassName, L"CLI and MCP setup — Just Speak to It",
        windowStyle, bounds.left + scale(owner, 40), bounds.top + scale(owner, 40), frame.right - frame.left,
        frame.bottom - frame.top, owner, nullptr, instance, &dialog);
}

Configuration snapshot() {
    std::lock_guard<std::mutex> lock(configurationMutex);
    return configuration;
}

std::wstring controlText(HWND window, int id) {
    const HWND control = GetDlgItem(window, id);
    const int length = GetWindowTextLengthW(control);
    std::wstring text(static_cast<size_t>(length) + 1, 0);
    const int copied = GetWindowTextW(control, &text[0], length + 1);
    text.resize(static_cast<size_t>(std::max(copied, 0)));
    return text;
}
} // namespace

void jsti_show_automation_settings(HWND owner, bool (*enabled)(), void (*toggle)(HWND owner)) {
    Dialog dialog;
    dialog.config = snapshot();
    dialog.enabled = enabled;
    dialog.toggle = toggle;
    HWND window = createDialog(owner, dialog);
    if (!window) {
        jsti_window_update(jsti::systemError("Opening CLI and MCP setup").c_str(), nullptr, -1);
        return;
    }
    EnableWindow(owner, FALSE);
    ShowWindow(window, SW_SHOW);
    SetFocus(GetDlgItem(window, toggleID));
    MSG message{};
    BOOL result = 1;
    while (IsWindow(window) && (result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
        if (!IsDialogMessageW(window, &message)) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (IsWindow(window)) close(window);
    if (IsWindow(owner)) { EnableWindow(owner, TRUE); SetActiveWindow(owner); }
    if (result == 0) PostQuitMessage(static_cast<int>(message.wParam));
    else if (result < 0) jsti_window_update(jsti::systemError("Reading CLI and MCP setup messages").c_str(), nullptr, -1);
}

int jsti_window_set_automation_details(const char *pipe_name, const char *cli_path, const char *usage,
                                       const char *mcp_configuration, const char *claude_command) {
    const char *fields[] = {pipe_name, cli_path, usage, mcp_configuration, claude_command};
    for (const char *field : fields) {
        std::wstring checked;
        if (!field || std::strlen(field) > maximumDetailLength || !jsti::wide(field, checked)) return -1;
    }
    try {
        Configuration updated{pipe_name, cli_path, usage, mcp_configuration, claude_command};
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = std::move(updated);
    } catch (const std::exception &) { return -1; }
    return 0;
}

namespace {
bool moduleDirectory(std::wstring &directory) {
    std::wstring path(MAX_PATH, L'\0');
    for (;;) {
        const DWORD length = GetModuleFileNameW(nullptr, &path[0], static_cast<DWORD>(path.size()));
        if (length == 0) return false;
        if (length < path.size()) { path.resize(length); break; }
        if (path.size() >= 32768) return false;
        path.resize(path.size() * 2);
    }
    const size_t separator = path.find_last_of(L"\\/");
    if (separator == std::wstring::npos) return false;
    directory = path.substr(0, separator);
    return true;
}

// The packaged CLI's execution alias, as scripts/windows-package/
// package-identity.json declares it (cli.executionAlias).
bool packagedAlias(std::wstring &path) {
    DWORD size = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
    if (size == 0 || size > 32768) return false;
    std::wstring root(size, L'\0');
    size = GetEnvironmentVariableW(L"LOCALAPPDATA", &root[0], size);
    if (size == 0 || size >= root.size()) return false;
    root.resize(size);
    path = root + L"\\Microsoft\\WindowsApps\\JustSpeakToItDeveloperCLI.exe";
    return true;
}

bool regularFile(const std::wstring &path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}
} // namespace

int jsti_automation_cli_path(char *buffer, size_t capacity) {
    if (!buffer || capacity == 0) return -1;
    buffer[0] = 0;
    try {
        std::wstring candidate;
        bool found = false;
        if (jsti::login::packaged()) {
            found = packagedAlias(candidate) && regularFile(candidate);
        } else {
            std::wstring directory;
            if (moduleDirectory(directory)) {
                candidate = directory + L"\\speak.exe";
                found = regularFile(candidate);
            }
        }
        if (!found) return 0;
        const std::string path = jsti::utf8(candidate);
        if (path.empty() || path.size() >= capacity) return -1;
        std::memcpy(buffer, path.data(), path.size());
        buffer[path.size()] = 0;
        return 1;
    } catch (const std::exception &) { return -1; }
}

// ---- self-test -------------------------------------------------------------

namespace {
struct Probe {
    bool enabled = false;
    int toggles = 0;
    std::string copied;
};
Probe *probe = nullptr;
bool probeEnabled() { return probe && probe->enabled; }
void probeToggle(HWND) { if (probe) { ++probe->toggles; probe->enabled = !probe->enabled; } }
int probeCopy(const char *text, char *, size_t) {
    if (!probe) return -1;
    probe->copied = text ? text : "";
    return 0;
}

// Null and empty buffers fail; a found path is NUL-terminated, names an
// existing file and is refused rather than truncated by a short buffer.
bool cliPathBehaves() {
    char none[1] = {'x'};
    if (jsti_automation_cli_path(nullptr, 16) != -1 || jsti_automation_cli_path(none, 0) != -1) return false;
    std::vector<char> buffer(32768, 'x');
    const int found = jsti_automation_cli_path(buffer.data(), buffer.size());
    if (found == 0) return buffer[0] == 0;
    if (found != 1) return false;
    std::wstring path;
    if (!jsti::wide(buffer.data(), path) || !regularFile(path)) return false;
    char tiny[2] = {'x', 'x'};
    return jsti_automation_cli_path(tiny, sizeof tiny) == -1 && tiny[0] == 0;
}
} // namespace

// Configuration validation, the status shown for each reported state, the
// toggle request, each Copy action's exact text (never the real clipboard),
// and the CLI actions disabled when speak.exe is missing.
bool jsti_automation_settings_self_test(HWND owner, std::string &error) {
    const Configuration original = snapshot();
    Probe local;
    probe = &local;
    bool passed = false;
    try {
        const std::string tooLong(maximumDetailLength + 1, 'a');
        const char *pipe = "\\\\.\\pipe\\JustSpeakToIt-SpeakApp-automation-S-1-5-21-0";
        const char *path = "C:\\Apps\\Just Speak to It\\speak.exe";
        const char *usage = "& 'C:\\Apps\\Just Speak to It\\speak.exe' status\n& 'C:\\Apps\\speak.exe' --help";
        const char *mcp = "{\n  \"mcpServers\": {}\n}";
        const char *claude = "claude mcp add justspeaktoit -- 'C:\\Apps\\Just Speak to It\\speak.exe' mcp";
        if (jsti_window_set_automation_details(nullptr, path, usage, mcp, claude) != -1 ||
            jsti_window_set_automation_details(pipe, tooLong.c_str(), usage, mcp, claude) != -1 ||
            jsti_window_set_automation_details(pipe, "\xff", usage, mcp, claude) != -1 ||
            jsti_window_set_automation_details(pipe, path, usage, mcp, claude) != 0) {
            error = "Automation details accepted an invalid entry or rejected a valid one.";
        } else if (!cliPathBehaves()) {
            error = "Locating the speak command did not honour its buffer contract.";
        } else {
            Dialog dialog;
            dialog.config = snapshot();
            dialog.enabled = probeEnabled;
            dialog.toggle = probeToggle;
            dialog.copy = probeCopy;
            HWND window = createDialog(owner, dialog);
            if (!window) {
                error = jsti::systemError("Creating the CLI and MCP setup fixture");
            } else {
                const bool offShown = controlText(window, statusID).find(L"Automation is off") == 0 &&
                    controlText(window, toggleID) == L"Turn automation &on";
                SendMessageW(window, WM_COMMAND, MAKEWPARAM(toggleID, BN_CLICKED), 0);
                SendMessageW(window, WM_TIMER, refreshTimer, 0);
                const std::wstring status = controlText(window, statusID);
                const bool onShown = local.toggles == 1 && status.find(L"Automation is on") == 0 &&
                    status.find(wideText(pipe)) != std::wstring::npos &&
                    controlText(window, toggleID) == L"Turn automation &off";
                const bool literal = controlText(window, mcpID) == editText(mcp) &&
                    controlText(window, cliID) == editText(usage) && controlText(window, claudeID) == wideText(claude);
                bool copies = true;
                const std::pair<int, const char *> expected[] = {
                    {copyCliID, usage}, {copyPipeID, pipe}, {copyMcpID, mcp}, {copyClaudeID, claude}
                };
                for (const auto &entry : expected) {
                    local.copied.clear();
                    SendMessageW(window, WM_COMMAND, MAKEWPARAM(entry.first, BN_CLICKED), 0);
                    copies = copies && local.copied == entry.second &&
                        controlText(window, problemID).find(L"Copied the ") == 0;
                }
                SendMessageW(window, WM_COMMAND, MAKEWPARAM(IDCANCEL, BN_CLICKED), 0);
                const bool closed = !IsWindow(window);
                if (IsWindow(window)) DestroyWindow(window);
                bool missing = false;
                if (jsti_window_set_automation_details(pipe, "", "", "", "") == 0) {
                    Dialog absent;
                    absent.config = snapshot();
                    absent.copy = probeCopy;
                    HWND second = createDialog(owner, absent);
                    missing = second && !IsWindowEnabled(GetDlgItem(second, copyMcpID)) &&
                        !IsWindowEnabled(GetDlgItem(second, copyCliID)) &&
                        IsWindowEnabled(GetDlgItem(second, copyPipeID)) &&
                        controlText(second, cliLabelID).find(L"The speak command was not found") == 0;
                    if (second) DestroyWindow(second);
                }
                passed = offShown && onShown && literal && copies && closed && missing;
                if (!passed) {
                    error = "The CLI and MCP setup dialog did not show, toggle, copy or close as expected.";
                }
            }
        }
    } catch (const std::exception &) { error = "The CLI and MCP setup self-test could not allocate its fixtures."; }
    probe = nullptr;
    {
        std::lock_guard<std::mutex> lock(configurationMutex);
        configuration = original;
    }
    return passed;
}
