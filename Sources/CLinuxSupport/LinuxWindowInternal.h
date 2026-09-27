#ifndef JSTI_LINUX_WINDOW_INTERNAL_H
#define JSTI_LINUX_WINDOW_INTERNAL_H

#include "LinuxSupportInternal.h"

#include <adwaita.h>

/*
 * Shared between the window's source files. Everything here runs on the GTK
 * main thread except jsti_window_post, which is safe from any thread and
 * applies its work in call order, before the window exists (queued) or not at
 * all after it closes.
 */

typedef void (*jsti_apply_fn)(gpointer data);
int32_t jsti_window_post(jsti_apply_fn apply, gpointer data, GDestroyNotify destroy);

/* Reports an event to Swift unless the window is applying Swift's own state. */
void jsti_window_emit(gint32 event, const char *text, gint32 index);
/* While set, widget changes are Swift's own updates and emit nothing. */
void jsti_window_set_suppressed(gboolean suppressed);
GtkWidget *jsti_window_group(const char *title);
GtkWindow *jsti_window_main(void);

/* The settings panels below History (LinuxWindowPanels.c). */
void jsti_window_panels_build(AdwPreferencesPage *page);
/* Recording or transcription disables settings that must not change mid-run. */
void jsti_window_panels_refresh(gboolean idle);
int32_t jsti_window_panels_self_test(char *error, size_t capacity);

/* The App profiles group (LinuxProfiles.c) and on-device models group
 * (LinuxLocalModelsPanel.c). */
void jsti_window_profiles_build(AdwPreferencesPage *page);
void jsti_window_profiles_refresh(gboolean idle);
int32_t jsti_window_profiles_self_test(char *error, size_t capacity);
void jsti_window_local_models_build(AdwPreferencesPage *page);
void jsti_window_local_models_refresh(gboolean idle);

/* The tray icon (LinuxTray.c), on the GTK main loop. */
enum { JSTI_TRAY_SHOW = 1, JSTI_TRAY_TOGGLE = 2, JSTI_TRAY_QUIT = 3, JSTI_TRAY_AVAILABLE = 4, JSTI_TRAY_UNAVAILABLE = 5 };
typedef void (*jsti_tray_action_fn)(gint action);
int32_t jsti_tray_start(const char *app_id, jsti_tray_action_fn action, char *error, size_t capacity);
void jsti_tray_set_recording(gboolean recording);
gboolean jsti_tray_registered(void);
void jsti_tray_stop(void);
/* The Startup group's tray line. */
void jsti_window_panels_tray(gboolean available);

#endif
