/* Window-wide jsti_window_* setters: the HUD, visual density, page, focus, close and notices.
 * Each page's own setters live with the page's state. */
#include "LinuxWindowInternal.h"

typedef struct HUD {
    gint32 phase;
    gint32 display_milliseconds;
    gboolean compact;
    gboolean expanded;
    gchar *headline, *subheadline, *live;
} HUD;

static void hud_free(gpointer pointer) {
    HUD *state = pointer;
    g_free(state->headline);
    g_free(state->subheadline);
    g_free(state->live);
    g_free(state);
}

static void hud_apply(gpointer pointer) {
    HUD *state = pointer;
    jsti_hud_show_layout(state->phase, state->headline, state->subheadline, state->live,
                          state->display_milliseconds, state->compact, state->expanded);
}

int32_t jsti_window_set_hud(int32_t phase, const char *headline, const char *subheadline, const char *live_text,
                            int32_t display_milliseconds, int32_t compact) {
    return jsti_window_set_hud_layout(phase, headline, subheadline, live_text, display_milliseconds, compact, 0);
}

int32_t jsti_window_set_hud_layout(int32_t phase, const char *headline, const char *subheadline, const char *live_text,
                                   int32_t display_milliseconds, int32_t compact, int32_t expanded) {
    if (phase < 0 || phase > 6 || display_milliseconds < 0 || display_milliseconds > 60000 ||
        (compact != 0 && compact != 1) || (expanded != 0 && expanded != 1)) return -1;
    const char *texts[] = { headline, subheadline, live_text };
    for (size_t index = 0; index < G_N_ELEMENTS(texts); ++index) {
        if (texts[index] != NULL && !g_utf8_validate(texts[index], -1, NULL)) return -1;
    }
    HUD *state = g_new0(HUD, 1);
    state->phase = phase;
    state->display_milliseconds = display_milliseconds;
    state->compact = compact != 0;
    state->expanded = expanded != 0 && compact == 0;
    state->headline = g_strdup(headline != NULL ? headline : "");
    state->subheadline = g_strdup(subheadline != NULL ? subheadline : "");
    state->live = g_strdup(live_text != NULL ? live_text : "");
    return post(hud_apply, state, hud_free);
}

static void page_apply(gpointer data) { show_page(GPOINTER_TO_INT(data)); }

static void density_apply(gpointer pointer) {
    jsti_visual_density_apply(GTK_WIDGET(ui.window), pointer);
}

int32_t jsti_window_set_visual_density(JSTIVisualDensity density) {
    if ((density.compact != 0 && density.compact != 1) ||
        density.minimum_row_height < 30 || density.minimum_row_height > 64) return -1;
    const gint spacing[] = { density.page_padding, density.section_spacing, density.card_padding,
        density.content_spacing, density.inline_spacing, density.group_spacing };
    for (guint index = 0; index < G_N_ELEMENTS(spacing); ++index)
        if (spacing[index] < 0 || spacing[index] > 128) return -1;
    JSTIVisualDensity *update = g_new(JSTIVisualDensity, 1);
    *update = density;
    return post(density_apply, update, g_free);
}

int32_t jsti_window_show_page(int32_t page) {
    if (page < 0 || page >= JSTI_PAGE_COUNT) return -1;
    return post(page_apply, GINT_TO_POINTER(page), NULL);
}

static void active_work(JSTIMainCall *call, gpointer data) {
    *(gint *)data = ui.window != NULL && gtk_window_is_active(ui.window) ? 1 : 0;
    jsti_main_call_complete(call);
}

int32_t jsti_window_is_active(void) {
    if (!jsti_window_loop_running()) return 0;
    gint *active = g_new0(gint, 1);
    /* On timeout the pending work still owns `active`; leak it rather than
     * free it under the main thread. Report focused, the safe answer. */
    if (!jsti_main_invoke_sync(active_work, active, NULL, 1000)) return jsti_window_loop_running() ? 1 : 0;
    int32_t result = *active;
    g_free(active);
    return result;
}

static void close_apply(gpointer data) {
    (void)data;
    if (ui.window != NULL) gtk_window_close(ui.window);
}

void jsti_window_request_close(void) { post(close_apply, NULL, NULL); }

typedef struct Notice {
    gchar *title;
    gchar *body;
} Notice;

static void notice_free(gpointer pointer) {
    Notice *notice = pointer;
    g_free(notice->title);
    g_free(notice->body);
    g_free(notice);
}

static void notice_apply(gpointer pointer) {
    Notice *notice = pointer;
    GNotification *notification = g_notification_new(notice->title);
    g_notification_set_body(notification, notice->body);
    g_application_send_notification(G_APPLICATION(ui.application), "dictation", notification);
    g_object_unref(notification);
}

void jsti_notify(const char *title, const char *body) {
    Notice *notice = g_new0(Notice, 1);
    notice->title = g_strdup(title);
    notice->body = g_strdup(body);
    post(notice_apply, notice, notice_free);
}
