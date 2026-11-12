#include "../CWindowsSupport/WindowsIssueReportInternal.hpp"
#include "../CWindowsSupport/WindowsWindowInternal.hpp"
#include <cstdio>

using namespace jsti::issueReport;

static void jsti_smoke_stage(const char *stage) {
    std::fputs("jsti-ui-smoke-stage: ", stderr);
    std::fputs(stage, stderr);
    std::fputc('\n', stderr);
    std::fflush(stderr);
}

// Click Close as a user would, then deliver the deferred WM_CLOSE it posts.
static void clickClose(HWND window) {
    SendDlgItemMessageW(window, closeButton, BM_CLICK, 0, 0);
    MSG message;
    for (int i = 0; i < 64 && IsWindow(window) && PeekMessageW(&message, window, 0, 0, PM_REMOVE); ++i) {
        TranslateMessage(&message); DispatchMessageW(&message);
    }
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
    const ActionObserver original = actionObserver();
    exchangeActionObserver({[](int event, const char *ticket, int included, void *context) {
        auto *observed = static_cast<Observation *>(context);
        observed->event = event; observed->included = included; observed->ticket = ticket;
    }, &observed});
    jsti_smoke_stage("issue.focus.begin");
    const HWND focusedWindow = state->window;
    for (int control : {draftText, jsonText}) {
        const HWND edit = GetDlgItem(focusedWindow, control);
        SetFocus(edit);
        SendMessageW(focusedWindow, WM_COMMAND, MAKEWPARAM(control, EN_SETFOCUS), reinterpret_cast<LPARAM>(edit));
        SendMessageW(focusedWindow, WM_COMMAND, MAKEWPARAM(control, EN_UPDATE), reinterpret_cast<LPARAM>(edit));
    }
    exchangeActionObserver(original);
    jsti_smoke_stage("issue.focus.returned");
    if (!IsWindow(focusedWindow) || state->window != focusedWindow || state->isRetired() || observed.event != 0) {
        state->retire(); retireUI(state);
        error = "Issue report edit notifications retired the active preview."; return false;
    }
    exchangeActionObserver({[](int event, const char *ticket, int included, void *context) {
        auto *observed = static_cast<Observation *>(context);
        observed->event = event; observed->included = included; observed->ticket = ticket;
    }, &observed});
    jsti_smoke_stage("issue.consent.begin");
    SendDlgItemMessageW(state->window, includeBox, BM_CLICK, 0, 0);
    exchangeActionObserver(original);
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
    exchangeActionObserver({[](int event, const char *ticket, int included, void *context) {
        auto *observed = static_cast<Observation *>(context);
        observed->event = event; observed->included = included; observed->ticket = ticket;
    }, &observed});
    SendDlgItemMessageW(state->window, saveButton, BM_CLICK, 0, 0);
    SendDlgItemMessageW(state->window, copyButton, BM_CLICK, 0, 0);
    exchangeActionObserver(original);
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
    const HWND healthyOwner = reportOwner();
    for (int command : {IDCANCEL, static_cast<int>(closeButton)}) {
        jsti_smoke_stage(command == closeButton ? "issue.close-button.begin" : "issue.idcancel.begin");
        auto closing = std::make_shared<State>();
        JSTIIssueReport closingReport{closing};
        struct CloseObservation { int calls = 0, event = 0; std::string ticket; } closed;
        jsti_smoke_stage("issue.explicit-close.state-ready");
        exchangeActionObserver({[](int event, const char *ticket, int, void *context) {
            auto *closed = static_cast<CloseObservation *>(context);
            ++closed->calls; closed->event = event; closed->ticket = ticket;
        }, &closed});
        jsti_smoke_stage("issue.explicit-close.callback-ready");
        jsti_smoke_stage("issue.explicit-close.presentation.begin");
        if (jsti_issue_report_present(&closingReport, id, "Close fixture", "Safe draft", "{}", "", "", 1, 0, 0) != 0 ||
            !presentUI(closing) || !closing->window) {
            exchangeActionObserver(original);
            closing->retire(); retireUI(closing);
            error = "Issue report explicit-close fixture presentation failed."; return false;
        }
        jsti_smoke_stage("issue.explicit-close.presentation-validated");
        const HWND closingWindow = closing->window;
        jsti_smoke_stage("issue.explicit-close.dispatch.begin");
        if (command == closeButton) clickClose(closingWindow);
        else SendMessageW(closingWindow, WM_COMMAND, MAKEWPARAM(IDCANCEL, 0), 0);
        jsti_smoke_stage("issue.explicit-close.dispatch.returned");
        exchangeActionObserver(original);
        jsti_smoke_stage("issue.explicit-close.callback-restored");
        if (!closing->isRetired() || closing->window || IsWindow(closingWindow) ||
            closed.calls != 1 || closed.event != JSTI_EVENT_ISSUE_REPORT_CLOSE || closed.ticket != id ||
            reportOwner() != healthyOwner || !IsWindow(healthyOwner)) {
            closing->retire(); retireUI(closing);
            error = "Issue report explicit close lost preview or host ownership."; return false;
        }
        jsti_smoke_stage("issue.explicit-close.validated.before-local-destruction");
    }
    // A close callback may synchronously destroy this exact preview before
    // WM_CLOSE resumes. Its state must still retire without touching the form.
    auto reentrant = std::make_shared<State>();
    JSTIIssueReport reentrantReport{reentrant};
    if (jsti_issue_report_present(&reentrantReport, id, "Reentrant close", "Safe draft", "{}", "", "", 1, 0, 0) != 0 ||
        !presentUI(reentrant) || !reentrant->window) {
        reentrant->retire(); retireUI(reentrant);
        error = "Issue report reentrant-close fixture presentation failed."; return false;
    }
    struct ReentrantCloseObservation {
        HWND window;
        int calls = 0, event = 0;
        std::string ticket;
        bool destroyed = false, goneBeforeReturn = false;
    } reentrantClosed{reentrant->window};
    exchangeActionObserver({[](int event, const char *ticket, int, void *context) {
        auto *closed = static_cast<ReentrantCloseObservation *>(context);
        ++closed->calls; closed->event = event; closed->ticket = ticket;
        if (event == JSTI_EVENT_ISSUE_REPORT_CLOSE) {
            closed->destroyed = DestroyWindow(closed->window) != FALSE;
            closed->goneBeforeReturn = !IsWindow(closed->window);
        }
    }, &reentrantClosed});
    clickClose(reentrantClosed.window);
    exchangeActionObserver(original);
    if (!reentrantClosed.destroyed || !reentrantClosed.goneBeforeReturn ||
        reentrantClosed.calls != 1 || reentrantClosed.event != JSTI_EVENT_ISSUE_REPORT_CLOSE ||
        reentrantClosed.ticket != id || !reentrant->isRetired() || reentrant->window ||
        IsWindow(reentrantClosed.window) || reportOwner() != healthyOwner || !IsWindow(healthyOwner) ||
        actionObserver().callback != original.callback || actionObserver().context != original.context) {
        reentrant->retire(); retireUI(reentrant);
        error = "Issue report reentrant close lost preview, state, or host ownership."; return false;
    }
    jsti_smoke_stage("issue.explicit-closes.returned");
    // A distinct pending session proves loop shutdown settles an accepted
    // callback without dispatching it. Restore the owned smoke host afterwards.
    const HWND owner = reportOwner();
    const ActionObserver saved = actionObserver();
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
    // A detached host owns no window, owner or borrowed callback, so no new
    // report can be created until the window attaches it again.
    const ActionObserver detached = actionObserver();
    JSTIIssueReport *orphan = jsti_issue_report_create();
    const bool released = !orphan && !reportOwner() && !detached.callback && !detached.context;
    jsti_issue_report_release(orphan);
    if (!jsti_issue_report_attach(owner, saved.callback, saved.context) || !settled) {
        error = "Issue report loop shutdown did not settle queued ownership."; return false;
    }
    JSTIIssueReport *reattached = jsti_issue_report_create();
    const bool restored = reattached && reportOwner() == owner && actionObserver().callback == saved.callback;
    jsti_issue_report_release(reattached);
    if (!released || !restored) {
        error = "Issue report delivery host kept or lost its owner across shutdown."; return false;
    }
    jsti_smoke_stage("issue.self-test.returning");
    return true;
}
