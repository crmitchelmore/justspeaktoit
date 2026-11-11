/* The dashboard: its state, owned by LinuxWindowPages.c. GTK main thread only.
 * Only translation units that include this header can reach it. */
#ifndef JSTI_LINUX_WINDOW_DASHBOARD_PAGE_H
#define JSTI_LINUX_WINDOW_DASHBOARD_PAGE_H

#include "LinuxWindowInternal.h"

typedef struct DashboardPage {
    GtkButton *record;
    GtkButton *cancel;
    GtkLabel *status;
    GtkTextView *transcript;
    GtkButton *copy;
    GtkDropDown *version;
    GtkButton *hero_record;
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
