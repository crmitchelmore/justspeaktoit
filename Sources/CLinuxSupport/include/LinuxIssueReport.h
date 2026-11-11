#ifndef JSTI_LINUX_ISSUE_REPORT_H
#define JSTI_LINUX_ISSUE_REPORT_H
/* Report an issue: one opaque preview per handle and its copy/save/open actions. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Each opaque handle owns exactly one preview. All inputs are copied and bounded.
 * Completion is once-only, may run on any thread, and receives a borrowed path.
 * Retirement completes pending requests independently of GTK source destruction.
 * Late GIO callbacks retain only their request; never the window event context. */
typedef struct JSTIIssueReport JSTIIssueReport;
typedef void (*JSTIIssueReportCompletion)(int32_t result, const char *path, void *context);
JSTIIssueReport *jsti_issue_report_create(void);
void jsti_issue_report_destroy(JSTIIssueReport *report);
int32_t jsti_issue_report_present(JSTIIssueReport *report, const char *ticket,
    const char *title, const char *body, const char *json, int32_t included,
    int32_t exporting, int32_t opening, int32_t can_open, const char *status);
void jsti_issue_report_dismiss(JSTIIssueReport *report);
void jsti_issue_report_cancel_operations(JSTIIssueReport *report);
void jsti_issue_report_cancel_request(JSTIIssueReport *report, const char *request);
/* result: selected/accepted=1, cancelled=0, failed=-1. No file is written here. */
void jsti_issue_report_choose(JSTIIssueReport *report, const char *request,
    JSTIIssueReportCompletion completion, void *context);
void jsti_issue_report_copy(JSTIIssueReport *report, const char *request, const char *text,
    JSTIIssueReportCompletion completion, void *context);
void jsti_issue_report_open(JSTIIssueReport *report, const char *request, const char *url,
    JSTIIssueReportCompletion completion, void *context);
/* GTK-thread lifecycle hooks; parent is an opaque GtkWindow, never exported to Swift. */
void jsti_issue_reports_bind(void *parent);
void jsti_issue_reports_close(void);
int32_t jsti_issue_report_self_test(char *error, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
