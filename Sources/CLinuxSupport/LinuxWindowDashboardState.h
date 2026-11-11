/* The dashboard's state. Private to LinuxWindowPages.c, which builds and
 * refreshes it; the window self-tests also include it to inspect it. Every
 * other unit uses the functions in LinuxWindowDashboardPage.h. GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_DASHBOARD_STATE_H
#define JSTI_LINUX_WINDOW_DASHBOARD_STATE_H

#include "LinuxWindowDashboardPage.h"

typedef struct DashboardPage {
    GtkButton *record;
    GtkButton *cancel;
    GtkLabel *live_preview;
    GtkButton *dashboard_copy;
    /* Totals: dashboard hero chips and the Insights card. */
    GtkLabel *hero_sessions, *hero_time, *hero_spend;
    GtkLabel *insight_sessions, *insight_time, *insight_average, *insight_spend;
    /* Setup card on the dashboard. */
    GtkLabel *setup_microphone, *setup_model, *setup_shortcut, *setup_output;
    /* The two dashboard columns; a narrow window stacks them. */
    GtkWidget *columns;
} DashboardPage;

#pragma GCC visibility push(hidden)
DashboardPage *dashboard_page(void);
#pragma GCC visibility pop

#endif
