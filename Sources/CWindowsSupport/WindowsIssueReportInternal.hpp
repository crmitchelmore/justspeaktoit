// The issue report preview: the host's delivery owner and C API
// (WindowsIssueReport.cpp), the preview form and its UI-thread commands
// (WindowsIssueReportForm.cpp), and the pieces the self-test
// (CWindowsSelfTest/WindowsIssueReportSelfTest.cpp) drives. Not public ABI.
#pragma once

#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mutex>
#include <string>

namespace jsti::issueReport {

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
struct Form {
    std::shared_ptr<State> state;
    HFONT font = nullptr;
    int expectedIncludes = -1;
    std::string displayedBody;
    bool waitingOpen = false, waitingExport = false, waitingCopy = false;
    ~Form() { if (font) DeleteObject(font); }
};

// Validation shared by the C API and the commands (WindowsIssueReport.cpp).
bool bounded(const char *text, size_t maximum);
bool identifier(const char *text);
bool issueURL(const char *text);

// The delivery host (WindowsIssueReport.cpp). Host threads post; the rest is UI thread only.
bool post(Command value);
// Reports a form action to the borrowed host callback, if the state is still live.
void emitAction(const std::shared_ptr<State> &state, int action);
HWND reportOwner();
// Keeps `state` among the extant forms that shutdown and retirement sweep.
void trackForm(const std::shared_ptr<State> &state);
struct ActionObserver {
    JSTIWindowCallback callback = nullptr;
    void *context = nullptr;
};
// The self-test swaps a recording observer in and restores the host's afterwards.
ActionObserver actionObserver();
ActionObserver exchangeActionObserver(ActionObserver next);

// The form and its commands (WindowsIssueReportForm.cpp). UI thread only.
void retireUI(const std::shared_ptr<State> &state);
bool presentUI(const std::shared_ptr<State> &state, const Preview *delivered = nullptr);
void chooseUI(const std::shared_ptr<State> &state, const std::shared_ptr<Request> &request);
void openUI(const std::shared_ptr<State> &state, const std::shared_ptr<Request> &request);
void copyUI(const std::shared_ptr<State> &state, const std::shared_ptr<Request> &request);

} // namespace jsti::issueReport

struct JSTIIssueReport { std::shared_ptr<jsti::issueReport::State> state; };
