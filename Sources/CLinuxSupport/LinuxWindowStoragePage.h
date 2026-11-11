/* Recordings folder, audio cleanup and backup controls:
 * their state, owned by LinuxWindowBackup.c. GTK main thread only.
 * Only translation units that include this header can reach it. */
#ifndef JSTI_LINUX_WINDOW_STORAGE_PAGE_H
#define JSTI_LINUX_WINDOW_STORAGE_PAGE_H

#include "LinuxWindowInternal.h"

typedef struct StoragePage {
    GtkButton *recordings_folder;
    GtkButton *recordings_choose;
    GtkButton *recordings_default;
    GCancellable *location_chooser;
    AdwSwitchRow *backup_audio;
    AdwSwitchRow *backup_profiles;
    GtkButton *backup_export;
    GtkButton *backup_inspect;
    GtkButton *backup_restore;
    GtkWidget *restore_dialog;
    GCancellable *backup_chooser;
} StoragePage;

#pragma GCC visibility push(hidden)
StoragePage *storage_page(void);
#pragma GCC visibility pop

#endif
