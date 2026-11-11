/* Main-thread posting: setters queue updates that are applied in call order on the GTK thread. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowDashboardPage.h"
#include "LinuxWindowHistoryPage.h"

/* The streaming cleanup preview. `lock` guards every field but `visible`. */
typedef struct CleanupPreview {
    GMutex lock;
    guint64 ticket;
    gboolean active, posted;
    gchar *text;
    /* UI-thread only; preview text is never a Copy/export/read-aloud source. */
    gboolean visible;
} CleanupPreview;

static CleanupPreview cleanup_preview;

void retire_cleanup_preview(void) {
    g_mutex_lock(&cleanup_preview.lock);
    ++cleanup_preview.ticket;
    cleanup_preview.active = FALSE;
    g_clear_pointer(&cleanup_preview.text, g_free);
    g_mutex_unlock(&cleanup_preview.lock);
}

gboolean cleanup_preview_visible(void) { return cleanup_preview.visible; }
void cleanup_preview_set_visible(gboolean visible) { cleanup_preview.visible = visible; }

/* The post queue: updates staged before the loop runs wait in `early_posts`;
 * `window_closed` refuses new ones. Guarded by `post_lock`. */
static gint loop_running;
static GMutex post_lock;
static gboolean window_closed;
static GQueue early_posts = G_QUEUE_INIT;

gboolean jsti_window_loop_running(void) { return g_atomic_int_get(&loop_running) != 0; }

typedef struct Pending {
    apply_fn apply;
    GDestroyNotify destroy;
    gpointer data;
} Pending;

static gboolean pending_run(gpointer pointer) {
    Pending *pending = pointer;
    if (ui.window != NULL && jsti_window_loop_running()) pending->apply(pending->data);
    return G_SOURCE_REMOVE;
}

static void pending_free(gpointer pointer) {
    Pending *pending = pointer;
    if (pending->destroy != NULL) pending->destroy(pending->data);
    g_free(pending);
}

static void attach(Pending *pending) {
    /* One FIFO at default priority keeps updates in call order. */
    GSource *source = g_idle_source_new();
    g_source_set_priority(source, G_PRIORITY_DEFAULT);
    g_source_set_callback(source, pending_run, pending, pending_free);
    g_source_attach(source, g_main_context_default());
    g_source_unref(source);
}

/* Updates made before the window exists (initial microphones, text output)
 * wait here and are applied first, in order; after it closes they are dropped. */
static int32_t post_with_recording(apply_fn apply, gpointer data, GDestroyNotify destroy, gint32 recording) {
    Pending *pending = g_new0(Pending, 1);
    pending->apply = apply;
    pending->destroy = destroy;
    pending->data = data;
    g_mutex_lock(&post_lock);
    if (window_closed) {
        g_mutex_unlock(&post_lock);
        pending_free(pending);
        return 0;
    }
    if (recording >= 0) window_escape_publish(recording, -1, FALSE);
    if (!jsti_window_loop_running()) {
        g_queue_push_tail(&early_posts, pending);
        g_mutex_unlock(&post_lock);
        return 0;
    }
    attach(pending);
    g_mutex_unlock(&post_lock);
    return 0;
}

int32_t post(apply_fn apply, gpointer data, GDestroyNotify destroy) {
    return post_with_recording(apply, data, destroy, -1);
}

int32_t jsti_window_post(jsti_window_apply_fn apply, gpointer data, GDestroyNotify destroy) {
    return post(apply, data, destroy);
}

void jsti_window_emit(gint32 event, const char *text, gint32 index) { emit(event, text, index); }

void open_posts(void) {
    g_mutex_lock(&post_lock);
    g_atomic_int_set(&loop_running, 1);
    Pending *pending;
    while ((pending = g_queue_pop_head(&early_posts)) != NULL) attach(pending);
    g_mutex_unlock(&post_lock);
}

void close_posts(void) {
    g_mutex_lock(&post_lock);
    window_closed = TRUE;
    window_escape_publish(-1, -1, TRUE);
    g_atomic_int_set(&loop_running, 0);
    Pending *pending;
    while ((pending = g_queue_pop_head(&early_posts)) != NULL) pending_free(pending);
    g_mutex_unlock(&post_lock);
}

static void update_free(gpointer pointer) {
    Update *update = pointer;
    g_free(update->status);
    g_free(update->transcript);
    g_free(update);
}

/* Runs after queued HUD updates, so it speaks only when the HUD is not announcing the same change. */
static gboolean announce_state(gpointer unused) {
    (void)unused;
    ui.state_announcement = 0;
    const char *text = gtk_label_get_text(ui.status);
    if (jsti_hud_card() == NULL && text != NULL && text[0] != '\0')
        gtk_accessible_announce(GTK_ACCESSIBLE(ui.window), text, GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
    return G_SOURCE_REMOVE;
}

void update_apply(gpointer pointer) {
    Update *update = pointer;
    if (update->state >= 0 && update->state != ui.state && ui.state_announcement == 0)
        ui.state_announcement = g_idle_add_full(G_PRIORITY_LOW, announce_state, NULL, NULL);
    if (update->status != NULL) gtk_label_set_text(ui.status, update->status);
    if (update->has_transcript) {
        cleanup_preview.visible = FALSE;
        set_transcript(update->transcript);
        /* Global text is not bound to a record. */
        history_forget_presentation();
    }
    if (update->state >= 0) ui.state = update->state;
    refresh_actions();
    jsti_tray_set_state(ui.state, ui.tray_summary);
}

void cleanup_preview_apply(gpointer pointer) {
    (void)pointer;
    g_mutex_lock(&cleanup_preview.lock);
    cleanup_preview.posted = FALSE;
    if (cleanup_preview.active && cleanup_preview.text != NULL && !ui.closing && ui.state == JSTI_STATE_WORKING &&
        (ui.page == JSTI_PAGE_DASHBOARD || ui.page == JSTI_PAGE_HISTORY)) {
        set_transcript(cleanup_preview.text);
        cleanup_preview.visible = TRUE;
        gtk_label_set_text(ui.status, "Streaming cleanup preview. The original is saved in History.");
        history_forget_presentation();
        history_set_copy_enabled(FALSE);
        dashboard_set_copy_enabled(FALSE);
    }
    g_clear_pointer(&cleanup_preview.text, g_free);
    g_mutex_unlock(&cleanup_preview.lock);
}

uint64_t jsti_window_begin_cleanup_preview(void) {
    g_mutex_lock(&cleanup_preview.lock);
    if (++cleanup_preview.ticket == 0) ++cleanup_preview.ticket;
    cleanup_preview.active = TRUE;
    g_clear_pointer(&cleanup_preview.text, g_free);
    guint64 ticket = cleanup_preview.ticket;
    g_mutex_unlock(&cleanup_preview.lock);
    return ticket;
}

void jsti_window_end_cleanup_preview(uint64_t ticket) {
    g_mutex_lock(&cleanup_preview.lock);
    if (ticket == cleanup_preview.ticket) {
        ++cleanup_preview.ticket;
        cleanup_preview.active = FALSE;
        g_clear_pointer(&cleanup_preview.text, g_free);
    }
    g_mutex_unlock(&cleanup_preview.lock);
}

int32_t jsti_window_cleanup_preview(const char *text, uint64_t ticket) {
    if (text == NULL || strlen(text) > 65536 || !g_utf8_validate(text, -1, NULL)) return -1;
    g_mutex_lock(&post_lock);
    gboolean closed = window_closed;
    g_mutex_unlock(&post_lock);
    if (closed) return 1;
    g_mutex_lock(&cleanup_preview.lock);
    if (!cleanup_preview.active || ticket != cleanup_preview.ticket) {
        g_mutex_unlock(&cleanup_preview.lock);
        return 1;
    }
    g_free(cleanup_preview.text);
    cleanup_preview.text = g_strdup(text);
    gboolean submit = !cleanup_preview.posted;
    cleanup_preview.posted = TRUE;
    g_mutex_unlock(&cleanup_preview.lock);
    if (!submit) return 0;
    int32_t result = post(cleanup_preview_apply, NULL, NULL);
    if (result != 0) {
        g_mutex_lock(&cleanup_preview.lock);
        cleanup_preview.posted = FALSE;
        g_clear_pointer(&cleanup_preview.text, g_free);
        g_mutex_unlock(&cleanup_preview.lock);
    }
    return result;
}

int32_t jsti_window_update(const char *status, const char *transcript, int32_t state) {
    Update *update = g_new0(Update, 1);
    update->status = g_strdup(status);
    update->transcript = g_strdup(transcript);
    update->has_transcript = transcript != NULL;
    update->state = state;
    return post_with_recording(update_apply, update, update_free, state);
}
