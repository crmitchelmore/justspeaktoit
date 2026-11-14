/* The recordings folder, backup and restore controls: their state. Private to
 * LinuxWindowBackup.c; the window self-tests also include it to inspect it.
 * Every other unit uses the functions in LinuxWindowStoragePage.h. GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_STORAGE_STATE_H
#define JSTI_LINUX_WINDOW_STORAGE_STATE_H

#include "LinuxWindowStoragePage.h"

typedef struct StoragePage {
    GtkButton *recordings_folder;
    GtkButton *recordings_choose;
    GtkButton *recordings_default;
    GCancellable *location_chooser;
    AdwSwitchRow *backup_audio;
    AdwSwitchRow *backup_profiles;
    AdwSwitchRow *backup_api_keys;
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
