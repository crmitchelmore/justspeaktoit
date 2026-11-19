#include "WindowsIssueReportInternal.hpp"
#include <unordered_map>
#include <vector>
#include <exception>

namespace jsti::issueReport {
namespace {
constexpr UINT retirementMessage = WM_APP + 2;
constexpr UINT deliveryMessage = WM_APP + 1; // Private message-only window.
// The UI thread's delivery host: its message-only window, the commands host
// threads queue for it and the forms still open. `mutex` guards the window,
// the queue and the retirement wake; the owner, the borrowed callback and the
// forms are touched only on the UI thread once attached.
struct DeliveryHost {
    std::mutex mutex;
    HWND window = nullptr, owner = nullptr;
    ActionObserver observer;
    std::unordered_map<UINT_PTR, Command> commands;
    UINT_PTR sequence = 0;
    bool retirementPosted = false;
    std::vector<std::weak_ptr<State>> forms; // Only extant UI forms, not a history ledger.
};
DeliveryHost &host() {
    static DeliveryHost value;
    return value;
}
void wakeRetirement() {
    auto &delivery = host();
    std::lock_guard<std::mutex> lock(delivery.mutex);
    if (!delivery.window || delivery.retirementPosted) return;
    // No heap payload or growing close queue. Pending callbacks have already
    // settled; the one wake only closes exact retired/cancelled native owners.
    delivery.retirementPosted = PostMessageW(delivery.window, retirementMessage, 0, 0) != 0;
}
LRESULT CALLBACK hostProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == retirementMessage) {
        auto &delivery = host();
        { std::lock_guard<std::mutex> lock(delivery.mutex); delivery.retirementPosted = false; }
        for (auto &weak : delivery.forms) if (auto state = weak.lock()) {
            if (state->isRetired()) retireUI(state);
            else if (state->chooser && state->uiChooser && !state->uiChooser->pending())
                PostMessageW(state->chooser, WM_COMMAND, IDCANCEL, 0);
        }
        return 0;
    }
    if (message != deliveryMessage) return DefWindowProcW(window, message, wparam, lparam);
    Command value;
    {
        auto &delivery = host();
        std::lock_guard<std::mutex> lock(delivery.mutex);
        const auto found = delivery.commands.find(wparam);
        if (found == delivery.commands.end()) return 0;
        value = std::move(found->second); delivery.commands.erase(found);
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
    auto &delivery = host();
    std::lock_guard<std::mutex> lock(delivery.mutex);
    if (!delivery.window || delivery.commands.size() >= 64 ||
        delivery.sequence == std::numeric_limits<UINT_PTR>::max()) return false;
    const UINT_PTR token = ++delivery.sequence;
    delivery.commands.emplace(token, std::move(value));
    if (PostMessageW(delivery.window, deliveryMessage, token, 0)) return true;
    delivery.commands.erase(token);
    return false;
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
    const ActionObserver observer = host().observer;
    if (observer.callback)
        observer.callback(event, preview.ticket.c_str(), action == JSTI_ISSUE_INCLUDE ? 1 : 0, observer.context);
}
HWND reportOwner() { return host().owner; }
void trackForm(const std::shared_ptr<State> &state) {
    auto &forms = host().forms;
    forms.erase(std::remove_if(forms.begin(), forms.end(), [](auto &value) { return value.expired(); }), forms.end());
    forms.push_back(state);
}
ActionObserver actionObserver() { return host().observer; }
ActionObserver exchangeActionObserver(ActionObserver next) {
    const ActionObserver previous = host().observer;
    host().observer = next;
    return previous;
}

} // namespace jsti::issueReport

using namespace jsti::issueReport;

bool jsti_issue_report_attach(HWND owner, JSTIWindowCallback callback, void *context) {
    if (!owner || !callback || GetWindowThreadProcessId(owner, nullptr) != GetCurrentThreadId()) return false;
    WNDCLASSW type{}; type.lpfnWndProc = hostProcedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"JustSpeakToItIssueDelivery";
    if (!RegisterClassW(&type) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
    const HWND window = CreateWindowExW(0, type.lpszClassName, L"", 0, 0, 0, 0, 0,
        HWND_MESSAGE, nullptr, type.hInstance, nullptr);
    if (!window) return false;
    auto &delivery = host();
    std::lock_guard<std::mutex> lock(delivery.mutex);
    delivery.owner = owner; delivery.observer = {callback, context}; delivery.window = window;
    return true;
}
void jsti_issue_report_shutdown() {
    std::unordered_map<UINT_PTR, Command> pending;
    HWND window = nullptr;
    auto &delivery = host();
    {
        std::lock_guard<std::mutex> lock(delivery.mutex);
        window = delivery.window; delivery.window = nullptr; delivery.retirementPosted = false;
        pending.swap(delivery.commands);
    }
    // Called on the main UI thread before its borrowed callback holder clears.
    for (auto &value : pending) {
        emitAction(value.second.state, JSTI_ISSUE_CLOSE);
        value.second.state->retire(); retireUI(value.second.state);
    }
    for (auto &weak : delivery.forms) if (auto state = weak.lock()) {
        emitAction(state, JSTI_ISSUE_CLOSE);
        state->retire(); retireUI(state);
    }
    delivery.observer = {};
    auto &forms = delivery.forms;
    forms.erase(std::remove_if(forms.begin(), forms.end(), [](auto &value) { return value.expired(); }), forms.end());
    if (window) DestroyWindow(window);
    delivery.owner = nullptr;
}
bool jsti_issue_report_message(MSG *message) {
    for (auto &weak : host().forms) if (auto state = weak.lock())
        if (state->window && (message->hwnd == state->window || IsChild(state->window, message->hwnd)) &&
            IsDialogMessageW(state->window, message)) return true;
    return false;
}
extern "C" {
JSTIIssueReport *jsti_issue_report_create(void) {
    try {
        auto &delivery = host();
        std::lock_guard<std::mutex> lock(delivery.mutex);
        if (!delivery.window) return nullptr;
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
