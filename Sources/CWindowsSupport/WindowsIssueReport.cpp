#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <commdlg.h>
#include <shellapi.h>
#include <objbase.h>
#include <mutex>
#include <unordered_map>
#include <vector>
#include <cwchar>
#include <exception>
#include <cstdio>

namespace {
constexpr UINT retirementMessage = WM_APP + 2;
constexpr UINT deliveryMessage = WM_APP + 1; // Private message-only window.
enum class CommandKind { present, choose, open, copy };
enum Control { draftLabel = 1001, draftText, jsonLabel, jsonText, includeBox, copyButton,
               saveButton, openButton, closeButton, statusText, privacyText };
static_assert(draftLabel > IDCONTINUE && privacyText < IDTIMEOUT,
              "Issue report controls must not overlap standard dialog command IDs.");
struct Preview {
    std::string ticket, title, body, json, url, status;
    bool includes = true, exporting = false, opening = false;
};
struct Request {
    std::mutex mutex;
    std::string identifier, value;
    JSTIIssueReportResult callback = nullptr;
    void *context = nullptr;
    bool done = false;
    bool pending() {
        std::lock_guard<std::mutex> lock(mutex);
        return !done;
    }
    void complete(int32_t code, const std::string &value = {}) {
        JSTIIssueReportResult deliver = nullptr; void *target = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (done) return;
            done = true; deliver = callback; target = context;
            callback = nullptr; context = nullptr;
        }
        if (deliver) deliver(code, value.c_str(), target);
    }
};
struct State {
    std::mutex mutex;
    Preview preview;
    bool retired = false;
    std::shared_ptr<Request> chooserRequest, openRequest, copyRequest;
    // UI-thread-only fields. A running chooser retains State on its stack.
    HWND window = nullptr, chooser = nullptr;
    bool choosing = false;
    std::shared_ptr<Request> uiChooser;
    void retire() {
        std::shared_ptr<Request> choose, open, copy;
        {
            std::lock_guard<std::mutex> lock(mutex);
            retired = true;
            choose = std::move(chooserRequest); open = std::move(openRequest); copy = std::move(copyRequest);
        }
        if (choose) choose->complete(1);
        if (open) open->complete(1);
        if (copy) copy->complete(1);
    }
    bool admit(const std::shared_ptr<Request> &request) {
        std::lock_guard<std::mutex> lock(mutex);
        return !retired && (chooserRequest == request || openRequest == request || copyRequest == request) && request->pending();
    }
    bool isRetired() { std::lock_guard<std::mutex> lock(mutex); return retired; }
    bool snapshot(Preview &value) {
        std::lock_guard<std::mutex> lock(mutex);
        if (retired) return false;
        value = preview;
        return true;
    }
};
struct FinishRequest {
    std::shared_ptr<State> state;
    std::shared_ptr<Request> request;
    ~FinishRequest() {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->chooserRequest == request) state->chooserRequest.reset();
        if (state->openRequest == request) state->openRequest.reset();
        if (state->copyRequest == request) state->copyRequest.reset();
    }
};
struct Command {
    CommandKind kind;
    std::shared_ptr<State> state;
    std::shared_ptr<Request> request;
    std::shared_ptr<const Preview> preview;
};
std::mutex deliveryMutex;
HWND hostWindow = nullptr, ownerWindow = nullptr;
JSTIWindowCallback actionCallback = nullptr;
void *actionContext = nullptr;
std::unordered_map<UINT_PTR, Command> commands;
UINT_PTR sequence = 0;
bool retirementPosted = false;
std::vector<std::weak_ptr<State>> forms; // Only extant UI forms, not a history ledger.

bool bounded(const char *text, size_t maximum) {
    return text && strnlen(text, maximum + 1) <= maximum;
}
bool identifier(const char *text) {
    if (!bounded(text, 36) || std::strlen(text) != 36) return false;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (text[i] != '-') return false; }
        else if (!((text[i] >= '0' && text[i] <= '9') || (text[i] >= 'a' && text[i] <= 'f') ||
                   (text[i] >= 'A' && text[i] <= 'F'))) return false;
    }
    return true;
}
bool issueURL(const char *text) {
    if (!bounded(text, 7500)) return false;
    const std::string value(text);
    const std::string prefix = "https://github.com/crmitchelmore/justspeaktoit/issues/new?";
    return value.compare(0, prefix.size(), prefix) == 0 &&
        value.find_first_of("\r\n\\#") == std::string::npos;
}
bool post(Command value) {
    std::lock_guard<std::mutex> lock(deliveryMutex);
    if (!hostWindow || commands.size() >= 64 ||
        sequence == std::numeric_limits<UINT_PTR>::max()) return false;
    const UINT_PTR token = ++sequence;
    commands.emplace(token, std::move(value));
    if (PostMessageW(hostWindow, deliveryMessage, token, 0)) return true;
    commands.erase(token);
    return false;
}
void wakeRetirement() {
    std::lock_guard<std::mutex> lock(deliveryMutex);
    if (!hostWindow || retirementPosted) return;
    // No heap payload or growing close queue. Pending callbacks have already
    // settled; the one wake only closes exact retired/cancelled native owners.
    retirementPosted = PostMessageW(hostWindow, retirementMessage, 0, 0) != 0;
}
void retireUI(const std::shared_ptr<State> &state) {
    if (state->chooser) PostMessageW(state->chooser, WM_COMMAND, IDCANCEL, 0);
    // Never free a hook/context or its owner while GetSaveFileNameW is on-stack.
    if (!state->choosing && state->window) DestroyWindow(state->window);
}
int scaled(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
struct Form {
    std::shared_ptr<State> state;
    HFONT font = nullptr;
    int expectedIncludes = -1;
    std::string displayedBody;
    bool waitingOpen = false, waitingExport = false, waitingCopy = false;
    ~Form() { if (font) DeleteObject(font); }
};
void refreshFont(HWND window, Form &form) {
    HFONT replacement = CreateFontW(-scaled(window, 14), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (!replacement) return;
    HFONT previous = form.font; form.font = replacement;
    for (int id = draftLabel; id <= privacyText; ++id)
        SendDlgItemMessageW(window, id, WM_SETFONT, reinterpret_cast<WPARAM>(form.font), TRUE);
    if (previous) DeleteObject(previous);
}
void setText(HWND window, int id, const std::string &value) {
    std::wstring wide;
    if (jsti::wide(value.c_str(), wide)) SetDlgItemTextW(window, id, wide.c_str());
}
void layout(HWND window) {
    RECT rect{}; GetClientRect(window, &rect);
    const int margin = scaled(window, 16), gap = scaled(window, 8), row = scaled(window, 36);
    const int width = std::max(1, static_cast<int>(rect.right) - 2 * margin);
    auto place = [&](int id, int x, int y, int w, int h) {
        MoveWindow(GetDlgItem(window, id), x, y, std::max(1, w), std::max(1, h), TRUE);
    };
    place(privacyText, margin, margin, width, scaled(window, 56));
    int top = margin + scaled(window, 64);
    const int reserved = scaled(window, 160);
    const int available = std::max(scaled(window, 160), static_cast<int>(rect.bottom) - top - reserved);
    const int half = (available - 2 * scaled(window, 24) - gap) / 2;
    place(draftLabel, margin, top, width, scaled(window, 24)); top += scaled(window, 24);
    place(draftText, margin, top, width, half); top += half + gap;
    place(jsonLabel, margin, top, width, scaled(window, 24)); top += scaled(window, 24);
    place(jsonText, margin, top, width, half); top += half + gap;
    place(includeBox, margin, top, width, row); top += row + gap;
    const int buttonWidth = (width - 3 * gap) / 4;
    for (int i = 0; i < 4; ++i)
        place(copyButton + i, margin + i * (buttonWidth + gap), top, buttonWidth, row);
    top += row + gap;
    place(statusText, margin, top, width, scaled(window, 44));
}
void refresh(HWND window, const Preview &preview) {
    auto *form = reinterpret_cast<Form *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    // A toggle is a request, not a local mutation of the immutable artifacts.
    // An older queued status cannot re-enable sharing before its matching
    // full/removed projection arrives from the shared owner.
    if (form && form->waitingCopy) {
        if (!preview.opening) return; // ABI flag includes shared isCopying.
        form->waitingCopy = false;
    }
    if (form && form->waitingOpen) {
        if (!preview.opening) return;
        form->waitingOpen = false;
    }
    if (form && form->waitingExport) {
        if (!preview.exporting) return;
        form->waitingExport = false;
    }
    if (form && form->expectedIncludes >= 0) {
        if ((preview.includes ? 1 : 0) != form->expectedIncludes) return;
        form->expectedIncludes = -1;
    }
    std::wstring title;
    if (jsti::wide(preview.title.c_str(), title)) SetWindowTextW(window, title.c_str());
    if (form) form->displayedBody = preview.body;
    setText(window, draftText, preview.body);
    setText(window, jsonText, preview.json);
    EnableWindow(GetDlgItem(window, draftText), TRUE);
    EnableWindow(GetDlgItem(window, jsonText), TRUE);
    setText(window, statusText, preview.status);
    SendDlgItemMessageW(window, includeBox, BM_SETCHECK, preview.includes ? BST_CHECKED : BST_UNCHECKED, 0);
    EnableWindow(GetDlgItem(window, includeBox), !preview.exporting && !preview.opening);
    EnableWindow(GetDlgItem(window, copyButton), !preview.opening && !preview.exporting);
    EnableWindow(GetDlgItem(window, saveButton), !preview.exporting && !preview.opening);
    EnableWindow(GetDlgItem(window, openButton), !preview.exporting && !preview.opening && !preview.url.empty());
}
void emitAction(const std::shared_ptr<State> &state, int action) {
    Preview preview;
    if (!state->snapshot(preview)) return;
    // Callback/context live only until the UI-thread shutdown clears them.
    int event = 0;
    switch (action) {
    case JSTI_ISSUE_INCLUDE: case JSTI_ISSUE_REMOVE: event = JSTI_EVENT_ISSUE_REPORT_INCLUDE; break;
    case JSTI_ISSUE_COPY: event = JSTI_EVENT_ISSUE_REPORT_COPY; break;
    case JSTI_ISSUE_SAVE: event = JSTI_EVENT_ISSUE_REPORT_SAVE; break;
    case JSTI_ISSUE_OPEN: event = JSTI_EVENT_ISSUE_REPORT_OPEN; break;
    case JSTI_ISSUE_CLOSE: event = JSTI_EVENT_ISSUE_REPORT_CLOSE; break;
    default: return;
    }
    if (actionCallback) actionCallback(event, preview.ticket.c_str(), action == JSTI_ISSUE_INCLUDE ? 1 : 0, actionContext);
}
LRESULT formMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto *form = reinterpret_cast<Form *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        auto *pending = static_cast<std::unique_ptr<Form> *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        form = pending->release();
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(form));
        form->state->window = window;
    }
    if (!form) return DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
    case WM_CREATE: {
        const auto add = [&](const wchar_t *type, const wchar_t *text, DWORD style, int id) {
            return CreateWindowExW(std::wcscmp(type, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0, type, text,
                WS_CHILD | WS_VISIBLE | style, 0, 0, 1, 1, window,
                reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), GetModuleHandleW(nullptr), nullptr) != nullptr;
        };
        const DWORD editor = ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL | WS_TABSTOP;
        if (!add(L"STATIC", L"Review these allowlisted details before sharing. No audio, transcript or raw logs. "
                 L"Add reproduction steps in GitHub. Attach the saved JSON yourself; nothing is submitted automatically.",
                 0, privacyText) ||
            !add(L"STATIC", L"Issue &draft", 0, draftLabel) || !add(L"EDIT", L"", editor, draftText) ||
            !add(L"STATIC", L"&JSON attachment", 0, jsonLabel) || !add(L"EDIT", L"", editor, jsonText) ||
            !add(L"BUTTON", L"&Include diagnostics", BS_AUTOCHECKBOX | WS_TABSTOP, includeBox) ||
            !add(L"BUTTON", L"&Copy draft", BS_PUSHBUTTON | WS_TABSTOP, copyButton) ||
            !add(L"BUTTON", L"&Save JSON...", BS_PUSHBUTTON | WS_TABSTOP, saveButton) ||
            !add(L"BUTTON", L"&Open GitHub", BS_PUSHBUTTON | WS_TABSTOP, openButton) ||
            !add(L"BUTTON", L"Close", BS_PUSHBUTTON | WS_TABSTOP, closeButton) ||
            !add(L"STATIC", L"", 0, statusText)) return -1;
        refreshFont(window, *form);
        return 0;
    }
    case WM_SIZE: layout(window); return 0;
    case WM_GETMINMAXINFO:
        reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {scaled(window, 620), scaled(window, 620)};
        return 0;
    case WM_DPICHANGED: {
        refreshFont(window, *form);
        const auto *rect = reinterpret_cast<RECT *>(lparam);
        SetWindowPos(window, nullptr, rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top,
            SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_COMMAND:
        if (LOWORD(wparam) == IDCANCEL || LOWORD(wparam) == closeButton) {
            SendMessageW(window, WM_CLOSE, 0, 0); return 0;
        }
        if (HIWORD(wparam) != BN_CLICKED || !IsWindowEnabled(GetDlgItem(window, LOWORD(wparam)))) break;
        switch (LOWORD(wparam)) {
        case includeBox: {
            const bool included = SendDlgItemMessageW(window, includeBox, BM_GETCHECK, 0, 0) == BST_CHECKED;
            form->expectedIncludes = included ? 1 : 0;
            // Native removal has not happened yet. Make the old draft
            // unselectable until the exact shared replacement is acknowledged.
            form->displayedBody.clear();
            SetDlgItemTextW(window, draftText, L"");
            SetDlgItemTextW(window, jsonText, L"");
            SetDlgItemTextW(window, statusText, L"Updating preview...");
            for (int id : {draftText, jsonText, includeBox, copyButton, saveButton, openButton})
                EnableWindow(GetDlgItem(window, id), FALSE);
            emitAction(form->state, included ? JSTI_ISSUE_INCLUDE : JSTI_ISSUE_REMOVE);
            break;
        }
        case copyButton:
            form->waitingCopy = true;
            for (int id : {includeBox, copyButton, saveButton, openButton}) EnableWindow(GetDlgItem(window, id), FALSE);
            emitAction(form->state, JSTI_ISSUE_COPY); break;
        case saveButton:
            form->waitingExport = true;
            for (int id : {includeBox, copyButton, saveButton, openButton}) EnableWindow(GetDlgItem(window, id), FALSE);
            emitAction(form->state, JSTI_ISSUE_SAVE); break;
        case openButton:
            form->waitingOpen = true;
            for (int id : {includeBox, copyButton, saveButton, openButton}) EnableWindow(GetDlgItem(window, id), FALSE);
            emitAction(form->state, JSTI_ISSUE_OPEN); break;
        }
        return 0;
    case WM_CLOSE:
        emitAction(form->state, JSTI_ISSUE_CLOSE);
        form->state->retire();
        retireUI(form->state);
        return 0;
    case WM_NCDESTROY:
        form->state->window = nullptr;
        SetWindowLongPtrW(window, GWLP_USERDATA, 0);
        delete form;
        break;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
LRESULT CALLBACK formProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    try { return formMessage(window, message, wparam, lparam); }
    catch (const std::exception &) {
        auto *form = reinterpret_cast<Form *>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (form) form->state->retire();
        if (message != WM_NCDESTROY) PostMessageW(window, WM_CLOSE, 0, 0);
        return message == WM_CREATE ? -1 : 0;
    }
}
bool presentUI(const std::shared_ptr<State> &state, const Preview *delivered = nullptr) {
    Preview preview;
    if (!state->snapshot(preview)) return true;
    if (delivered) preview = *delivered;
    if (!state->window) {
        WNDCLASSW type{}; type.lpfnWndProc = formProcedure; type.hInstance = GetModuleHandleW(nullptr);
        type.lpszClassName = L"JustSpeakToItIssueReport"; type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
        if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
        auto form = std::make_unique<Form>(); form->state = state;
        // WM_NCDESTROY owns Form after WM_NCCREATE, including WM_CREATE failure.
        HWND window = CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName, L"Issue details",
            WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 760, 760,
            ownerWindow, nullptr, type.hInstance, &form);
        if (!window) return false;
        Preview stillOwned;
        if (!state->snapshot(stillOwned)) { DestroyWindow(window); return true; }
        forms.erase(std::remove_if(forms.begin(), forms.end(), [](auto &value) { return value.expired(); }), forms.end());
        forms.push_back(state);
        refresh(window, preview); layout(window);
        ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, draftText));
    } else refresh(state->window, preview);
    return true;
}
UINT_PTR CALLBACK chooserHook(HWND window, UINT message, WPARAM, LPARAM lparam) {
    if (message == WM_INITDIALOG) {
        auto *state = reinterpret_cast<State *>(reinterpret_cast<OPENFILENAMEW *>(lparam)->lCustData);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
        state->chooser = GetParent(window);
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->retired || !state->chooserRequest || !state->chooserRequest->pending())
            PostMessageW(state->chooser, WM_COMMAND, IDCANCEL, 0);
    }
    return 0;
}
void chooseUI(const std::shared_ptr<State> &state, const std::shared_ptr<Request> &request) {
    FinishRequest finish{state, request};
    Preview preview;
    if (!request->pending() || !state->snapshot(preview)) { request->complete(1); return; }
    if (!state->window || state->choosing) { request->complete(2); return; }
    std::wstring filename;
    if (!jsti::wide(request->value.c_str(), filename)) { request->complete(2); return; }
    std::vector<wchar_t> destination(32768);
    std::copy(filename.begin(), filename.end(), destination.begin());
    OPENFILENAMEW chooser{}; chooser.lStructSize = sizeof(chooser); chooser.hwndOwner = state->window;
    chooser.lpstrFilter = L"JSON diagnostics (*.json)\0*.json\0All files (*.*)\0*.*\0\0";
    chooser.lpstrFile = destination.data(); chooser.nMaxFile = static_cast<DWORD>(destination.size());
    // The fixed suggestion already ends in .json. lpstrDefExt appends only
    // three characters, so never supply "json" and silently generate ".jso".
    chooser.lpstrTitle = L"Save diagnostics JSON";
    chooser.Flags = OFN_PATHMUSTEXIST | OFN_OVERWRITEPROMPT | OFN_NOCHANGEDIR |
        OFN_EXPLORER | OFN_DONTADDTORECENT | OFN_ENABLEHOOK;
    chooser.lpfnHook = chooserHook; chooser.lCustData = reinterpret_cast<LPARAM>(state.get());
    if (!state->admit(request)) { request->complete(1); return; }
    state->choosing = true; state->uiChooser = request;
    const BOOL selected = GetSaveFileNameW(&chooser);
    const DWORD error = selected ? 0 : CommDlgExtendedError();
    state->chooser = nullptr; state->choosing = false; state->uiChooser.reset();
    Preview current;
    if (!state->snapshot(current) || !request->pending()) request->complete(1);
    else if (selected) {
        const std::string path = jsti::utf8(destination.data());
        request->complete(path.empty() ? 2 : 0, path);
    } else request->complete(error ? 2 : 1);
    if (!state->snapshot(current)) retireUI(state);
}
void openUI(const std::shared_ptr<State> &state, const std::shared_ptr<Request> &request) {
    FinishRequest finish{state, request};
    Preview preview;
    if (!request->pending() || !state->snapshot(preview)) { request->complete(1); return; }
    std::wstring url;
    if (!issueURL(request->value.c_str()) || !jsti::wide(request->value.c_str(), url)) {
        request->complete(2); return;
    }
    // The OS call is admitted now, not at PostMessage. Retirement cannot recall
    // an already accepted browser request; shared post-await guards suppress UI.
    const HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(apartment)) { request->complete(2); return; }
    if (!state->admit(request)) { CoUninitialize(); request->complete(1); return; }
    const auto result = reinterpret_cast<INT_PTR>(ShellExecuteW(state->window, L"open", url.c_str(),
        nullptr, nullptr, SW_SHOWNORMAL));
    CoUninitialize();
    request->complete(result > 32 ? 0 : 2);
}
void copyUI(const std::shared_ptr<State> &state, const std::shared_ptr<Request> &request) {
    FinishRequest finish{state, request};
    Preview preview;
    if (!request->pending() || !state->snapshot(preview)) { request->complete(1); return; }
    auto *form = state->window
        ? reinterpret_cast<Form *>(GetWindowLongPtrW(state->window, GWLP_USERDATA)) : nullptr;
    if (!form || form->expectedIncludes >= 0 || form->displayedBody != request->value) {
        request->complete(2); return;
    }
    if (!state->admit(request)) { request->complete(1); return; }
    // This exact handle/visible-body admission happens on the UI thread.
    // Retirement before this guard refuses the command. OS clipboard placement
    // already admitted here cannot be recalled, just like a browser launch.
    char ignored[1]{};
    request->complete(jsti_clipboard_write(request->value.c_str(), ignored, sizeof(ignored)) == 0 ? 0 : 2);
}
LRESULT CALLBACK hostProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == retirementMessage) {
        { std::lock_guard<std::mutex> lock(deliveryMutex); retirementPosted = false; }
        for (auto &weak : forms) if (auto state = weak.lock()) {
            if (state->isRetired()) retireUI(state);
            else if (state->chooser && state->uiChooser && !state->uiChooser->pending())
                PostMessageW(state->chooser, WM_COMMAND, IDCANCEL, 0);
        }
        return 0;
    }
    if (message != deliveryMessage) return DefWindowProcW(window, message, wparam, lparam);
    Command value;
    {
        std::lock_guard<std::mutex> lock(deliveryMutex);
        const auto found = commands.find(wparam);
        if (found == commands.end()) return 0;
        value = std::move(found->second); commands.erase(found);
    }
    try {
        switch (value.kind) {
        case CommandKind::present:
            if (!presentUI(value.state, value.preview.get())) {
                emitAction(value.state, JSTI_ISSUE_CLOSE);
                value.state->retire(); retireUI(value.state);
                jsti_window_update("Issue report preview is unavailable on this host.", nullptr, -1);
            }
            break;
        case CommandKind::choose: chooseUI(value.state, value.request); break;
        case CommandKind::open: openUI(value.state, value.request); break;
        case CommandKind::copy: copyUI(value.state, value.request); break;
        }
    } catch (const std::exception &) {
        if (value.request) value.request->complete(2);
        value.state->retire(); retireUI(value.state);
        jsti_window_update("Issue report preview could not complete this action.", nullptr, -1);
    }
    return 0;
}
int32_t start(const std::shared_ptr<State> &state, const char *requestID, const char *value,
              CommandKind kind, JSTIIssueReportResult callback, void *context) {
    const bool choose = kind == CommandKind::choose, copy = kind == CommandKind::copy;
    if (!identifier(requestID) || !callback || !context ||
        !(choose ? bounded(value, 255) : copy ? bounded(value, 65536) : issueURL(value))) return -1;
    std::wstring wide;
    if (!jsti::wide(value, wide) || wide.empty() ||
        (choose && (wide.find_first_of(L"\\/:*?\"<>|") != std::wstring::npos ||
            std::any_of(wide.begin(), wide.end(), [](wchar_t c) { return c < 32; })))) return -1;
    auto request = std::make_shared<Request>();
    request->identifier = requestID; request->value = value;
    request->callback = callback; request->context = context;
    std::unique_lock<std::mutex> lock(state->mutex);
    auto &slot = choose ? state->chooserRequest : copy ? state->copyRequest : state->openRequest;
    if (state->retired || state->preview.ticket.empty() || slot || (!choose && (copy ? state->preview.body != value : state->preview.url != value))) return -1;
    slot = request;
    // Queue-only: no callback invocation inline, including failure. This closes
    // Swift's registration/cancel race without retaining its lock over the UI.
    try {
        if (!post({kind, state, request})) {
            slot.reset(); return -1;
        }
        return 0;
    } catch (const std::exception &) { slot.reset(); return -1; }
}
} // namespace

struct JSTIIssueReport { std::shared_ptr<State> state; };

bool jsti_issue_report_attach(HWND owner, JSTIWindowCallback callback, void *context) {
    if (!owner || !callback || GetWindowThreadProcessId(owner, nullptr) != GetCurrentThreadId()) return false;
    WNDCLASSW type{}; type.lpfnWndProc = hostProcedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItIssueDelivery";
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    const HWND host = CreateWindowExW(0, type.lpszClassName, L"", 0, 0, 0, 0, 0,
        HWND_MESSAGE, nullptr, type.hInstance, nullptr);
    if (!host) return false;
    std::lock_guard<std::mutex> lock(deliveryMutex);
    ownerWindow = owner; actionCallback = callback; actionContext = context; hostWindow = host;
    return true;
}
void jsti_issue_report_shutdown() {
    std::unordered_map<UINT_PTR, Command> pending;
    HWND host = nullptr;
    {
        std::lock_guard<std::mutex> lock(deliveryMutex);
        host = hostWindow; hostWindow = nullptr; retirementPosted = false;
        pending.swap(commands);
    }
    // Called on the main UI thread before its borrowed callback holder clears.
    for (auto &value : pending) {
        emitAction(value.second.state, JSTI_ISSUE_CLOSE);
        value.second.state->retire(); retireUI(value.second.state);
    }
    for (auto &weak : forms) if (auto state = weak.lock()) {
        emitAction(state, JSTI_ISSUE_CLOSE);
        state->retire(); retireUI(state);
    }
    actionCallback = nullptr; actionContext = nullptr;
    forms.erase(std::remove_if(forms.begin(), forms.end(), [](auto &value) { return value.expired(); }), forms.end());
    if (host) DestroyWindow(host);
    ownerWindow = nullptr;
}
bool jsti_issue_report_message(MSG *message) {
    for (auto &weak : forms) if (auto state = weak.lock())
        if (state->window && (message->hwnd == state->window || IsChild(state->window, message->hwnd)) &&
            IsDialogMessageW(state->window, message)) return true;
    return false;
}
extern "C" {
JSTIIssueReport *jsti_issue_report_create(void) {
    try {
        std::lock_guard<std::mutex> lock(deliveryMutex);
        if (!hostWindow) return nullptr;
        return new JSTIIssueReport{std::make_shared<State>()};
    } catch (const std::exception &) { return nullptr; }
}
void jsti_issue_report_retire(JSTIIssueReport *report) {
    if (!report) return;
    report->state->retire();
    wakeRetirement();
}
void jsti_issue_report_release(JSTIIssueReport *report) {
    if (!report) return;
    jsti_issue_report_retire(report);
    delete report;
}
int32_t jsti_issue_report_present(JSTIIssueReport *report, const char *ticket, const char *title,
    const char *body, const char *json, const char *url, const char *status, int32_t includes, int32_t exporting, int32_t opening) {
    try {
        if (!report || !identifier(ticket) || !bounded(title, 512) || !bounded(body, 65536) ||
            !bounded(json, 16384) || !bounded(url, 7500) || !bounded(status, 1024) ||
            (includes != 0 && includes != 1) || (exporting != 0 && exporting != 1) || (opening != 0 && opening != 1) || (url[0] && !issueURL(url))) return -1;
        for (const char *value : {title, body, json, url, status}) {
            std::wstring wide; if (!jsti::wide(value, wide)) return -1;
        }
        auto state = report->state;
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->retired || (!state->preview.ticket.empty() && state->preview.ticket != ticket)) return -1;
        state->preview = {ticket, title, body, json, url, status, includes != 0, exporting != 0, opening != 0};
        return post({CommandKind::present, state, {}, std::make_shared<Preview>(state->preview)}) ? 0 : -1;
    } catch (const std::exception &) { return -1; }
}
int32_t jsti_issue_report_copy(JSTIIssueReport *report, const char *request, const char *body,
    JSTIIssueReportResult callback, void *context) {
    try { return report ? start(report->state, request, body, CommandKind::copy, callback, context) : -1; }
    catch (const std::exception &) { return -1; }
}
int32_t jsti_issue_report_choose(JSTIIssueReport *report, const char *request, const char *filename,
    JSTIIssueReportResult callback, void *context) {
    try { return report ? start(report->state, request, filename, CommandKind::choose, callback, context) : -1; }
    catch (const std::exception &) { return -1; }
}
int32_t jsti_issue_report_open(JSTIIssueReport *report, const char *request, const char *url,
    JSTIIssueReportResult callback, void *context) {
    try { return report ? start(report->state, request, url, CommandKind::open, callback, context) : -1; }
    catch (const std::exception &) { return -1; }
}
void jsti_issue_report_cancel(JSTIIssueReport *report, const char *requestID) {
    if (!report || !identifier(requestID)) return;
    auto state = report->state;
    std::shared_ptr<Request> request;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        for (auto *slot : {&state->chooserRequest, &state->openRequest, &state->copyRequest}) {
            if (*slot && (*slot)->identifier == requestID) { request = std::move(*slot); break; }
        }
    }
    if (request) {
        request->complete(1);
        wakeRetirement();
    }
}
} // extern C

static void jsti_smoke_stage(const char *stage) {
    std::fputs("jsti-ui-smoke-stage: ", stderr);
    std::fputs(stage, stderr);
    std::fputc('\n', stderr);
    std::fflush(stderr);
}

bool jsti_issue_report_self_test(std::string &error) {
    jsti_smoke_stage("issue.self-test.enter");
    // No clipboard/browser/chooser side effects. These run inside the existing
    // owned synthetic --ui-smoke-test and exercise actual native owner helpers.
    auto state = std::make_shared<State>();
    const char *id = "11111111-1111-4111-8111-111111111111";
    JSTIIssueReport report{state};
    if (jsti_issue_report_present(&report, id, "Safe report", "Safe draft", "{}", "", "", 1, 0, 0) != 0) {
        error = "Issue report native presentation queue admission failed."; return false;
    }
    jsti_smoke_stage("issue.creation.begin");
    if (!presentUI(state)) {
        state->retire(); retireUI(state);
        error = "Issue report native preview creation failed."; return false;
    }
    jsti_smoke_stage("issue.creation.returned");
    if (!state->window || !IsWindow(state->window) || state->isRetired()) {
        state->retire(); retireUI(state);
        error = "Issue report native preview retired during initial presentation."; return false;
    }
    const auto text = [&](int control) {
        HWND child = GetDlgItem(state->window, control);
        const int count = GetWindowTextLengthW(child);
        std::wstring result(static_cast<size_t>(count) + 1, 0);
        GetWindowTextW(child, result.data(), count + 1); result.resize(count); return result;
    };
    if (text(draftText) != L"Safe draft" || text(jsonText) != L"{}" ||
        !(GetWindowLongPtrW(GetDlgItem(state->window, draftText), GWL_STYLE) & ES_READONLY)) {
        state->retire(); retireUI(state); error = "Issue report exact read-only preview failed."; return false;
    }
    struct Observation { int event = 0, included = -1; std::string ticket; } observed;
    const auto originalCallback = actionCallback; void *originalContext = actionContext;
    actionCallback = [](int event, const char *ticket, int included, void *context) {
        auto *observed = static_cast<Observation *>(context);
        observed->event = event; observed->included = included; observed->ticket = ticket;
    };
    actionContext = &observed;
    jsti_smoke_stage("issue.focus.begin");
    const HWND focusedWindow = state->window;
    for (int control : {draftText, jsonText}) {
        const HWND edit = GetDlgItem(focusedWindow, control);
        SetFocus(edit);
        SendMessageW(focusedWindow, WM_COMMAND, MAKEWPARAM(control, EN_SETFOCUS), reinterpret_cast<LPARAM>(edit));
        SendMessageW(focusedWindow, WM_COMMAND, MAKEWPARAM(control, EN_UPDATE), reinterpret_cast<LPARAM>(edit));
    }
    actionCallback = originalCallback; actionContext = originalContext;
    jsti_smoke_stage("issue.focus.returned");
    if (!IsWindow(focusedWindow) || state->window != focusedWindow || state->isRetired() || observed.event != 0) {
        state->retire(); retireUI(state);
        error = "Issue report edit notifications retired the active preview."; return false;
    }
    actionCallback = [](int event, const char *ticket, int included, void *context) {
        auto *observed = static_cast<Observation *>(context);
        observed->event = event; observed->included = included; observed->ticket = ticket;
    };
    actionContext = &observed;
    jsti_smoke_stage("issue.consent.begin");
    SendDlgItemMessageW(state->window, includeBox, BM_CLICK, 0, 0);
    actionCallback = originalCallback; actionContext = originalContext;
    if (observed.event != JSTI_EVENT_ISSUE_REPORT_INCLUDE || observed.included != 0 || observed.ticket != id) {
        state->retire(); retireUI(state); error = "Issue report exact-ticket include event failed."; return false;
    }
    presentUI(state); // Deliberately re-deliver the older full projection.
    if (!text(draftText).empty() || !text(jsonText).empty() ||
        IsWindowEnabled(GetDlgItem(state->window, copyButton)) ||
        IsWindowEnabled(GetDlgItem(state->window, draftText)) ||
        IsWindowEnabled(GetDlgItem(state->window, jsonText))) {
        state->retire(); retireUI(state); error = "Issue report pending removal exposed the old draft."; return false;
    }
    jsti_smoke_stage("issue.consent.returned");
    // A real Save click must fence a fast Copy before any shared busy ack.
    // This callback only records the event; it never opens an OS chooser.
    if (jsti_issue_report_present(&report, id, "Safe report", "Removed draft", "{\"removed\":true}", "", "", 0, 0, 0) != 0 ||
        !presentUI(state)) {
        state->retire(); retireUI(state); error = "Issue report idle Save fixture failed."; return false;
    }
    observed = {};
    actionCallback = [](int event, const char *ticket, int included, void *context) {
        auto *observed = static_cast<Observation *>(context);
        observed->event = event; observed->included = included; observed->ticket = ticket;
    };
    actionContext = &observed;
    SendDlgItemMessageW(state->window, saveButton, BM_CLICK, 0, 0);
    SendDlgItemMessageW(state->window, copyButton, BM_CLICK, 0, 0);
    actionCallback = originalCallback; actionContext = originalContext;
    const auto *form = reinterpret_cast<Form *>(GetWindowLongPtrW(state->window, GWLP_USERDATA));
    if (observed.event != JSTI_EVENT_ISSUE_REPORT_SAVE || observed.ticket != id ||
        IsWindowEnabled(GetDlgItem(state->window, copyButton)) || !form || form->waitingCopy) {
        state->retire(); retireUI(state); error = "Issue report Save did not immediately fence Copy."; return false;
    }
    if (jsti_issue_report_present(&report, id, "Safe report", "Removed draft", "{\"removed\":true}", "", "", 0, 1, 0) != 0 ||
        !presentUI(state) || text(draftText) != L"Removed draft" || text(jsonText) != L"{\"removed\":true}" ||
        !IsWindowEnabled(GetDlgItem(state->window, draftText)) ||
        !(GetWindowLongPtrW(GetDlgItem(state->window, draftText), GWL_STYLE) & ES_READONLY) ||
        IsWindowEnabled(GetDlgItem(state->window, includeBox)) || IsWindowEnabled(GetDlgItem(state->window, saveButton))) {
        state->retire(); retireUI(state); error = "Issue report removal/busy parity failed."; return false;
    }
    jsti_smoke_stage("issue.save-copy.returned");
    const std::string oversized(65537, 'x');
    if (jsti_issue_report_present(&report, id, "Safe report", oversized.c_str(), "{}", "", "", 1, 0, 0) == 0 ||
        jsti_issue_report_present(&report, id, "\xff", "Safe draft", "{}", "", "", 1, 0, 0) == 0) {
        state->retire(); retireUI(state); error = "Issue report invalid or oversized payload was accepted."; return false;
    }
    struct Count { int calls = 0, result = -1; } count;
    auto callback = [](int32_t result, const char *, void *context) {
        auto *count = static_cast<Count *>(context); ++count->calls; count->result = result;
    };
    jsti_smoke_stage("issue.cancel.begin");
    const char *requestID = "22222222-2222-4222-8222-222222222222";
    if (jsti_issue_report_choose(&report, requestID, "justspeaktoit-diagnostics.json", callback, &count) != 0) {
        state->retire(); retireUI(state); error = "Issue report chooser queue admission failed."; return false;
    }
    std::shared_ptr<Request> request;
    { std::lock_guard<std::mutex> lock(state->mutex); request = state->chooserRequest; }
    jsti_issue_report_cancel(&report, requestID);
    // Cancellation does not close a healthy preview or depend on dispatching
    // the queued chooser. A later OS callback cannot complete it again.
    request->complete(0, "not-an-export");
    if (count.calls != 1 || count.result != 1 || request->pending() || !IsWindow(state->window)) {
        state->retire(); retireUI(state); error = "Issue report queued cancellation did not settle once."; return false;
    }
    jsti_smoke_stage("issue.cancel.returned");
    Count copied;
    if (jsti_issue_report_copy(&report, requestID, "Removed draft", callback, &copied) != 0) {
        state->retire(); retireUI(state); error = "Issue report copy queue admission failed."; return false;
    }
    std::shared_ptr<Request> queuedCopy;
    { std::lock_guard<std::mutex> lock(state->mutex); queuedCopy = state->copyRequest; }
    jsti_smoke_stage("issue.retire.begin");
    state->retire();
    copyUI(state, queuedCopy);
    if (copied.calls != 1 || copied.result != 1) {
        retireUI(state); error = "A retired queued issue report Copy was not refused."; return false;
    }
    if (count.calls != 1 ||
        jsti_issue_report_copy(&report, requestID, "Removed draft", callback, &count) == 0 ||
        jsti_issue_report_present(&report, id, "x", "x", "{}", "", "", 1, 0, 0) == 0 ||
        issueURL("https://github.com.evil.example/crmitchelmore/justspeaktoit/issues/new?x=1") ||
        issueURL("https://github.com/crmitchelmore/justspeaktoit/issues/new?x=1#fragment") ||
        identifier("not-a-ticket")) {
        retireUI(state); error = "Issue report retirement/once-only/origin validation failed."; return false;
    }
    retireUI(state);
    jsti_smoke_stage("issue.retire.returned");
    // Standard cancellation and the real Close button still retire only their
    // own preview. Record the callback without touching the host controller.
    const HWND healthyOwner = ownerWindow;
    for (int command : {IDCANCEL, static_cast<int>(closeButton)}) {
        jsti_smoke_stage(command == closeButton ? "issue.close-button.begin" : "issue.idcancel.begin");
        auto closing = std::make_shared<State>();
        JSTIIssueReport closingReport{closing};
        struct CloseObservation { int calls = 0, event = 0; std::string ticket; } closed;
        jsti_smoke_stage("issue.explicit-close.state-ready");
        actionCallback = [](int event, const char *ticket, int, void *context) {
            auto *closed = static_cast<CloseObservation *>(context);
            ++closed->calls; closed->event = event; closed->ticket = ticket;
        };
        actionContext = &closed;
        jsti_smoke_stage("issue.explicit-close.callback-ready");
        jsti_smoke_stage("issue.explicit-close.presentation.begin");
        if (jsti_issue_report_present(&closingReport, id, "Close fixture", "Safe draft", "{}", "", "", 1, 0, 0) != 0 ||
            !presentUI(closing) || !closing->window) {
            actionCallback = originalCallback; actionContext = originalContext;
            closing->retire(); retireUI(closing);
            error = "Issue report explicit-close fixture presentation failed."; return false;
        }
        jsti_smoke_stage("issue.explicit-close.presentation-validated");
        const HWND closingWindow = closing->window;
        jsti_smoke_stage("issue.explicit-close.dispatch.begin");
        if (command == closeButton) SendDlgItemMessageW(closingWindow, closeButton, BM_CLICK, 0, 0);
        else SendMessageW(closingWindow, WM_COMMAND, MAKEWPARAM(IDCANCEL, 0), 0);
        jsti_smoke_stage("issue.explicit-close.dispatch.returned");
        actionCallback = originalCallback; actionContext = originalContext;
        jsti_smoke_stage("issue.explicit-close.callback-restored");
        if (!closing->isRetired() || closing->window || IsWindow(closingWindow) ||
            closed.calls != 1 || closed.event != JSTI_EVENT_ISSUE_REPORT_CLOSE || closed.ticket != id ||
            ownerWindow != healthyOwner || !IsWindow(healthyOwner)) {
            closing->retire(); retireUI(closing);
            error = "Issue report explicit close lost preview or host ownership."; return false;
        }
        jsti_smoke_stage("issue.explicit-close.validated.before-local-destruction");
    }
    jsti_smoke_stage("issue.explicit-closes.returned");
    // A distinct pending session proves loop shutdown settles an accepted
    // callback without dispatching it. Restore the owned smoke host afterwards.
    const HWND owner = ownerWindow;
    const auto savedCallback = actionCallback; void *savedContext = actionContext;
    JSTIIssueReport pending{std::make_shared<State>()};
    Count shutdown;
    if (jsti_issue_report_present(&pending, id, "Pending", "Pending", "{}", "", "", 1, 0, 0) != 0 ||
        jsti_issue_report_choose(&pending, requestID, "justspeaktoit-diagnostics.json", callback, &shutdown) != 0) {
        pending.state->retire(); error = "Issue report pending shutdown fixture failed."; return false;
    }
    jsti_smoke_stage("issue.shutdown.begin");
    jsti_issue_report_shutdown();
    jsti_smoke_stage("issue.shutdown.returned");
    const bool settled = shutdown.calls == 1 && shutdown.result == 1;
    if (!jsti_issue_report_attach(owner, savedCallback, savedContext) || !settled) {
        error = "Issue report loop shutdown did not settle queued ownership."; return false;
    }
    jsti_smoke_stage("issue.self-test.returning");
    return true;
}
