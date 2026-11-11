/* Text output and the keyboard shortcut rows, as the rest of the window sees
 * them: functions only. Their state is private to LinuxWindowOutput.c
 * (LinuxWindowOutputState.h). GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_OUTPUT_PAGE_H
#define JSTI_LINUX_WINDOW_OUTPUT_PAGE_H

#include "LinuxWindowInternal.h"

#pragma GCC visibility push(hidden)
/* General > Output, and Keyboard > Shortcut. */
GtkWidget *output_group(void);
GtkWidget *shortcut_group(void);
/* The Setup card's text output line, e.g. "Paste into the focused app · clipboard restored". */
gchar *output_summary(void);
/* The shortcut row's hint, or NULL. */
const char *output_shortcut_hint(void);
/* The method and clipboard restoration the rows show now. */
TextOutput output_current(void);
#pragma GCC visibility pop

#endif
