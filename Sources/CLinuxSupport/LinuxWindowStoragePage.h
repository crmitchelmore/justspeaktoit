/* General's recordings folder, backup and restore controls, as the rest of
 * the window sees them: functions only. Their state is private to
 * LinuxWindowBackup.c (LinuxWindowStorageState.h). GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_STORAGE_PAGE_H
#define JSTI_LINUX_WINDOW_STORAGE_PAGE_H

#include "LinuxWindowInternal.h"

#pragma GCC visibility push(hidden)
void storage_groups_add(GtkWidget *column);
/* Folder and backup choices wait for an idle window and one open picker or restore. */
void storage_refresh_actions(gboolean idle);
/* Window close: cancels any open folder or backup picker. */
void storage_page_close(void);
#pragma GCC visibility pop

#endif
