/* The dashboard, as the rest of the window sees it: functions only. Its state
 * is private to LinuxWindowPages.c (LinuxWindowDashboardState.h). GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_DASHBOARD_PAGE_H
#define JSTI_LINUX_WINDOW_DASHBOARD_PAGE_H

#include "LinuxWindowInternal.h"

#pragma GCC visibility push(hidden)
GtkWidget *build_dashboard(GtkTextBuffer *buffer);
/* A narrow window stacks the two dashboard columns. */
void dashboard_add_compact_setters(AdwBreakpoint *breakpoint);
/* Record, Cancel, Copy and the live preview for the window state. */
void dashboard_refresh_actions(gint32 state, gboolean copyable);
void dashboard_set_copy_enabled(gboolean enabled);
/* Whether the hero's Record button accepts a press now. */
gboolean dashboard_can_record(void);
#pragma GCC visibility pop

#endif
