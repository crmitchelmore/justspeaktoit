#include "WindowsIssueReportInternal.hpp"
#include "WindowsWindowChrome.hpp"
#include <commdlg.h>
#include <shellapi.h>
#include <objbase.h>
#include <cwchar>
#include <exception>
#include <vector>

namespace jsti::issueReport {

void retireUI(const std::shared_ptr<State> &state) {
    if (state->chooser) PostMessageW(state->chooser, WM_COMMAND, IDCANCEL, 0);
    // Never free a hook/context or its owner while GetSaveFileNameW is on-stack.
    if (!state->choosing && state->window) DestroyWindow(state->window);
}
namespace {
int scaled(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }
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
LRESULT formMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    auto *form = reinterpret_cast<Form *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        auto *pending = static_cast<std::unique_ptr<Form> *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        form = pending->release();
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(form));
        form->state->window = window;
    }
    if (!form) return DefWindowProcW(window, message, wparam, lparam);
    LRESULT themed = 0;
    if (jsti::chrome::dialogMessage(window, message, wparam, lparam, themed)) return themed;
    switch (message) {
    case WM_CREATE: {
        const auto add = [&](const wchar_t *type, const wchar_t *text, DWORD style, int id) {
            return jsti::chrome::addControl(window, type, text, style, id,
                std::wcscmp(type, L"EDIT") == 0 ? WS_EX_CLIENTEDGE : 0);
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
        if (LOWORD(wparam) == IDCANCEL) { SendMessageW(window, WM_CLOSE, 0, 0); return 0; }
        // The Close button is still inside its click handler; destroying its
        // parent here would free the button underneath it. Close afterwards.
        if (LOWORD(wparam) == closeButton) { PostMessageW(window, WM_CLOSE, 0, 0); return 0; }
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
    case WM_CLOSE: {
        // The callback may synchronously destroy the form. Keep its state alive
        // without reading the form again after invoking external code.
        auto state = form->state;
        emitAction(state, JSTI_ISSUE_CLOSE);
        state->retire();
        retireUI(state);
        return 0;
    }
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
} // namespace

bool presentUI(const std::shared_ptr<State> &state, const Preview *delivered) {
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
            reportOwner(), nullptr, type.hInstance, &form);
        if (!window) return false;
        Preview stillOwned;
        if (!state->snapshot(stillOwned)) { DestroyWindow(window); return true; }
        trackForm(state);
        refresh(window, preview); layout(window);
        ShowWindow(window, SW_SHOW); SetFocus(GetDlgItem(window, draftText));
    } else refresh(state->window, preview);
    return true;
}
namespace {
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
} // namespace
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

} // namespace jsti::issueReport
