/* jsti_window_* setters for History presentation, the transcript snapshot and playback. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowHistoryPage.h"

static void presentation_free(gpointer pointer) {
    Presentation *presentation = pointer;
    g_free(presentation->id);
    g_free(presentation->text);
    g_free(presentation->status);
    g_free(presentation);
}

void presentation_apply(gpointer pointer) {
    Presentation *presentation = pointer;
    /* Only the selected record's content may be shown under its actions. */
    if (!history_is_selected(presentation->id)) return;
    ui.suppress = TRUE;
    if (presentation->has_text) {
        set_transcript(presentation->text);
        if (presentation->status != NULL) gtk_label_set_text(ui.status, presentation->status);
    }
    history_mark_presented(presentation->id, presentation->variant, presentation->switchable);
    cleanup_preview_set_visible(FALSE);
    history_show_variant(presentation->variant);
    ui.suppress = FALSE;
    refresh_actions();
}

int32_t jsti_window_set_history_presentation(
    const char *record_id, int32_t variant, int32_t switchable, const char *text, const char *status) {
    Presentation *presentation = g_new0(Presentation, 1);
    presentation->id = g_strdup(record_id);
    presentation->variant = variant;
    presentation->switchable = switchable != 0;
    presentation->text = g_strdup(text != NULL ? text : "");
    presentation->status = g_strdup(status);
    presentation->has_text = TRUE;
    return post(presentation_apply, presentation, presentation_free);
}

int32_t jsti_window_set_transcript_variant(const char *record_id, int32_t variant, int32_t switchable) {
    if (record_id == NULL || record_id[0] == '\0') {
        return post((apply_fn)refresh_actions, NULL, NULL);
    }
    Presentation *presentation = g_new0(Presentation, 1);
    presentation->id = g_strdup(record_id);
    presentation->variant = variant;
    presentation->switchable = switchable != 0;
    presentation->has_text = FALSE;
    return post(presentation_apply, presentation, presentation_free);
}

int32_t jsti_window_transcript_snapshot(char *buffer, size_t capacity, size_t *required) {
    gchar *text = history_export_text() != NULL ? g_strdup(history_export_text()) : displayed_transcript();
    size_t length = strlen(text) + 1;
    if (required != NULL) *required = length;
    if (buffer == NULL || capacity < length) {
        g_free(text);
        return 2;
    }
    memcpy(buffer, text, length);
    g_free(text);
    return 0;
}

int32_t jsti_window_transcript_variant(void) {
    if (!history_selection_presented()) return -1;
    if (!history_presented_switchable()) return history_presented_variant() < 0 ? -1 : 1;
    return (int32_t)history_selected_variant();
}

typedef struct Playback {
    gchar *id;
    gint32 state;
    gchar *text;
} Playback;

static void playback_free(gpointer pointer) {
    Playback *playback = pointer;
    g_free(playback->id);
    g_free(playback->text);
    g_free(playback);
}

static void playback_apply(gpointer pointer) {
    Playback *playback = pointer;
    if (!history_is_selected(playback->id)) return;
    history_show_playback(playback->id, playback->state, playback->text);
    refresh_actions();
}

int32_t jsti_window_set_playback(const char *record_id, int32_t state, const char *text) {
    Playback *playback = g_new0(Playback, 1);
    playback->id = g_strdup(record_id);
    playback->state = state;
    playback->text = g_strdup(text);
    return post(playback_apply, playback, playback_free);
}

