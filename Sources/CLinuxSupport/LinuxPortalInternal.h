/*
 * XDG desktop portals over the session bus: GlobalShortcuts for the dictation
 * shortcut, and one RemoteDesktop session (keyboard only, persist mode 2)
 * with the Clipboard portal attached for Wayland insertion. Everything runs on
 * one dedicated thread with its own GMainContext, so the portals work without
 * the GTK loop and never block it. Public calls marshal onto that thread and
 * wait. Portal requests that may show a consent dialog wait up to five
 * minutes; the user can always dismiss them. Inside Flatpak, the Background
 * portal writes and removes the app's login item (see jsti_background_request).
 *
 * Shared by the portal units: LinuxPortal.c (the thread, requests,
 * availability and Background), LinuxPortalShortcuts.c (GlobalShortcuts) and
 * LinuxPortalRemoteDesktop.c (RemoteDesktop with Clipboard). Each unit owns
 * its session's state, which only the portal thread touches.
 */
#ifndef JSTI_LINUX_PORTAL_INTERNAL_H
#define JSTI_LINUX_PORTAL_INTERNAL_H

#include "LinuxSupportInternal.h"

#include <gio/gio.h>

#define PORTAL_BUS_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define REQUEST_INTERFACE "org.freedesktop.portal.Request"
#define SESSION_INTERFACE "org.freedesktop.portal.Session"
#define SHORTCUTS_INTERFACE "org.freedesktop.portal.GlobalShortcuts"
#define REMOTE_INTERFACE "org.freedesktop.portal.RemoteDesktop"
#define CLIPBOARD_INTERFACE "org.freedesktop.portal.Clipboard"
#define BACKGROUND_INTERFACE "org.freedesktop.portal.Background"
#define DIALOG_TIMEOUT_MS (5 * 60 * 1000)
#define CALL_TIMEOUT_MS 10000

typedef struct Portal {
    GThread *thread;
    GMainContext *context;
    GMainLoop *loop;
    GDBusConnection *bus;
    gchar *sender;
    guint token;
} Portal;

typedef int32_t (*PortalWork)(Portal *state, gpointer data, char *error, size_t capacity);

#pragma GCC visibility push(hidden)
/* Runs `work` on the portal thread, starting it once; the caller waits for it
 * to finish. Work is bounded by its own D-Bus and dialog timeouts. */
int32_t portal_run(PortalWork work, gpointer data, char *error, size_t capacity);
/* Whether the portal thread was ever started; stopping need not start it. */
gboolean portal_started(void);
/* Portal-thread helpers for the work functions. */
GVariant *portal_request(
    Portal *state, const char *interface, const char *method, GVariantBuilder *arguments,
    GVariantBuilder *options, guint timeout_ms, char *error, size_t capacity);
GVariant *portal_call(
    Portal *state, const char *interface, const char *method, GVariant *parameters, char *error, size_t capacity);
gchar *portal_create_session(Portal *state, const char *interface, char *error, size_t capacity);
void portal_close_session(Portal *state, const gchar *session);
#pragma GCC visibility pop

#endif
