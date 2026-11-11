#ifndef JSTI_WINDOWS_ISSUE_REPORT_H
#define JSTI_WINDOWS_ISSUE_REPORT_H
/* Report an issue: one frozen, ephemeral report and its copy/save/open actions. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One ephemeral, frozen safe report, never a History record or configuration.
 * Strings are borrowed only during calls and copied before return; bounds are
 * UTF-8 bytes: ticket/request 36, title 512, body 65536, JSON 16384,
 * generated URL 7500, fixed status 1024, suggested filename 255.
 * Result callback: 0 accepted/selected, 1 cancelled, 2 failed. value is a
 * borrowed selected path only for a successful chooser and is never logged.
 * Successful enqueue transfers callback/context completion ownership: exactly
 * one callback, including retirement/shutdown. A -1 return transfers nothing.
 * Copy reports real UI-thread clipboard completion. Open reports ShellExecute acceptance
 * asynchronously, never browser load/submission. No file writes happen here. */
typedef struct JSTIIssueReport JSTIIssueReport;
typedef void (*JSTIIssueReportResult)(int32_t result, const char *value, void *context);
enum JSTIIssueReportAction {
    JSTI_ISSUE_INCLUDE = 1, JSTI_ISSUE_REMOVE = 2, JSTI_ISSUE_COPY = 3,
    JSTI_ISSUE_SAVE = 4, JSTI_ISSUE_OPEN = 5, JSTI_ISSUE_CLOSE = 6
};
JSTIIssueReport *jsti_issue_report_create(void);
void jsti_issue_report_release(JSTIIssueReport *report);
int32_t jsti_issue_report_present(JSTIIssueReport *report, const char *ticket, const char *title,
    const char *body, const char *json, const char *url, const char *status,
    int32_t includes_diagnostics, int32_t is_exporting, int32_t is_opening);
void jsti_issue_report_retire(JSTIIssueReport *report);
int32_t jsti_issue_report_copy(JSTIIssueReport *report, const char *request, const char *body,
    JSTIIssueReportResult callback, void *context);
int32_t jsti_issue_report_choose(JSTIIssueReport *report, const char *request, const char *filename,
    JSTIIssueReportResult callback, void *context);
int32_t jsti_issue_report_open(JSTIIssueReport *report, const char *request, const char *url,
    JSTIIssueReportResult callback, void *context);
void jsti_issue_report_cancel(JSTIIssueReport *report, const char *request);

#ifdef __cplusplus
}
#endif
#endif
