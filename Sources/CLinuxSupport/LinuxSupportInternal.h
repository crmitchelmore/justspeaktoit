#ifndef JSTI_LINUX_SUPPORT_INTERNAL_H
#define JSTI_LINUX_SUPPORT_INTERNAL_H

#include "include/CLinuxSupport.h"
#include <glib.h>

/* Writes a formatted, always-terminated message into a caller buffer. */
void jsti_set_error(char *error, size_t capacity, const char *format, ...) G_GNUC_PRINTF(3, 4);

/* Runs `work(data)` on the default (GTK) main context and waits for it, at
 * most `timeout_ms`. Runs inline on the owning thread. Returns FALSE on
 * timeout or when no main loop is running; the work is then abandoned and
 * must not touch caller memory, so callers pass heap state it owns. */
typedef struct JSTIMainCall JSTIMainCall;
typedef void (*jsti_main_work_fn)(JSTIMainCall *call, gpointer data);
gboolean jsti_main_invoke_sync(jsti_main_work_fn work, gpointer data, GDestroyNotify destroy, guint timeout_ms);
/* Called by asynchronous main-thread work to release the waiting caller. */
void jsti_main_call_complete(JSTIMainCall *call);

/* TRUE while the GTK window's main loop is running. */
gboolean jsti_window_loop_running(void);

/* For window sections kept in their own files: the window's ordered,
 * thread-safe setter queue (apply runs on the GTK main thread while the window
 * exists; destroy always runs) and its event callback (main thread only). */
typedef void (*jsti_window_apply_fn)(gpointer data);
int32_t jsti_window_post(jsti_window_apply_fn apply, gpointer data, GDestroyNotify destroy);
void jsti_window_emit(gint32 event, const char *text, gint32 index);

/* LinuxLocalModels.c: the Local models group, built once with the window,
 * and its part of the window self-test. */
struct _GtkWidget *jsti_local_models_group_new(void);
int32_t jsti_local_models_self_test(char *error, size_t capacity);

/* The iCloud sync group (LinuxCloudSync.c): built once for the window's
 * iCloud sync page, and exercised by the window self-test. */
struct _GtkWidget *jsti_cloud_sync_group_new(void);
int32_t jsti_cloud_sync_self_test(char *error, size_t capacity);

struct _GtkWidget;
struct _GtkLabel;

/* LinuxWindowStyle.c: the app's look, shared by every page. Colours follow
 * the Mac app's brand tokens and switch with the desktop's light or dark
 * style. Each builder returns a new floating widget. */
void jsti_style_install(void);
/* The app icon, drawn rather than loaded so it needs no image loader. */
struct _GtkWidget *jsti_brand_icon_new(int size);
/* Paints the app icon into a size x size square at the origin. */
struct _cairo;
void jsti_brand_icon_paint(struct _cairo *cr, double size);
/* A scrolling page with centred content; `*content` receives its column. */
struct _GtkWidget *jsti_page_new(struct _GtkWidget **content);
/* A gradient header. `variant` is NULL (brand), "voice" or "settings".
 * `*chips` receives the row for jsti_chip_new; `*trailing` the top-right slot. */
struct _GtkWidget *jsti_hero_new(const char *variant, const char *title, const char *subtitle,
                                 struct _GtkWidget **chips, struct _GtkWidget **trailing);
/* An uppercase caption over a bold value, for a hero. */
struct _GtkWidget *jsti_chip_new(const char *label, struct _GtkLabel **value);
/* A rounded card with an icon tile and title; `*body` receives its content. */
struct _GtkWidget *jsti_card_new(const char *icon, const char *title, struct _GtkWidget **body);
/* A tinted statistic tile inside a card. */
struct _GtkWidget *jsti_stat_new(const char *label, struct _GtkLabel **value);
/* A History badge: `kind` is "created", "audio", "cost", "error" or "context". */
struct _GtkWidget *jsti_badge_new(const char *kind, const char *icon, const char *title, const char *value);

/* LinuxCapture.c: the latest microphone frame's loudness for the recording
 * HUD's meter, 0 at or below -50 dBFS to 1 at full scale. The pulse thread
 * publishes it with one atomic store per frame. */
void jsti_capture_publish_level(const int16_t *samples, size_t count);
double jsti_capture_level(void);

/* LinuxHUD.c: the recording HUD, on the main thread. `phase` is the shared
 * DesktopHUDState.Phase; `live` shows while recording. */
void jsti_hud_show(int phase, const char *headline, const char *subheadline, const char *live);
/* Redraws after a light or dark change; destroys the HUD with the window. */
void jsti_hud_destroy(void);
/* The HUD's card and shadow, when on screen, for snapshots; NULL otherwise. */
struct _GtkWidget *jsti_hud_card(void);
/* Checks the HUD never takes focus, sits at the bottom centre of the work
 * area on X11 and hides again. On Wayland it only checks nothing is shown. */
int32_t jsti_hud_self_test(char *error, size_t capacity);

/* LinuxTray.c: the StatusNotifierItem, like the Mac's menu bar extra, where
 * the desktop has a StatusNotifierWatcher (KDE, Ubuntu's GNOME, most others).
 * Main thread. `state` is JSTI_STATE_*; `summary` the Sessions, Recording
 * Time and Spend line. */
void jsti_tray_start(void);
/* LinuxWindow.c: 1 Start or Stop Recording (Cancel while working), 2 Open,
 * 3 Settings, 4 Quit. */
void jsti_window_tray_command(int command);
void jsti_tray_set_state(int32_t state, const char *summary);
void jsti_tray_stop(void);
int32_t jsti_tray_self_test(char *error, size_t capacity);

/* LinuxModelStream.c: a model file read on a thread of its own, so the speech
 * runtime, which holds its lock while whisper.cpp loads, never waits on the
 * file itself. `cancelled(data)` ends every wait early. */
typedef struct JSTIModelStream JSTIModelStream;
typedef gboolean (*jsti_stream_cancelled_fn)(gpointer data);
enum { JSTI_MODEL_STREAM_CHUNK = 1 << 20, JSTI_MODEL_STREAM_PREFIX = 2 << 20 };
/* Starts reading `path`; NULL (with `error`) when no reader could start. */
JSTIModelStream *jsti_model_stream_open(const char *path, char *error, size_t capacity);
/* Waits until `bytes` are buffered or the file ended or failed; FALSE when
 * cancelled first. */
gboolean jsti_model_stream_wait(JSTIModelStream *stream, size_t bytes, jsti_stream_cancelled_fn cancelled,
                                gpointer data);
/* Copies up to `size` bytes in order, waiting for the reader. Stops short at
 * the end of the file, on a read error, or, setting `*was_cancelled`, when it
 * would wait after cancellation. */
size_t jsti_model_stream_take(JSTIModelStream *stream, void *output, size_t size, jsti_stream_cancelled_fn cancelled,
                              gpointer data, gboolean *was_cancelled);
/* Why the stream failed, if it has: it could not open the path, the path was
 * a device or anything else that is neither a regular file nor a FIFO, or a
 * read failed. */
typedef enum {
    JSTI_MODEL_STREAM_OK,
    JSTI_MODEL_STREAM_UNOPENED,
    JSTI_MODEL_STREAM_NOT_A_FILE,
    JSTI_MODEL_STREAM_READ_ERROR
} JSTIModelStreamFailure;
JSTIModelStreamFailure jsti_model_stream_failure(JSTIModelStream *stream);
/* Stops the reader at its next step and drops the caller's reference. */
void jsti_model_stream_close(JSTIModelStream *stream);

#endif
