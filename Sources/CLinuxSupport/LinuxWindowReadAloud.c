/* Read aloud's voice picker: the Voice and Favorites rows, the host's voice
 * list and the favorite toggle. Owns ReadAloud (LinuxWindowReadAloudState.h). */
#include "LinuxWindowReadAloudState.h"

static ReadAloud read_aloud;
ReadAloud *read_aloud_state(void) { return &read_aloud; }

static void on_voice(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    read_aloud.favorite_pending = TRUE;
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button), FALSE);
    if (!ui.suppress) jsti_voice_credentials_selection_pending();
    guint position = adw_combo_row_get_selected(read_aloud.voice_row);
    if (read_aloud.picker_callback != NULL) {
        if (read_aloud.identifiers != NULL && position < read_aloud.identifiers->len) {
            const char *identifier = g_ptr_array_index(read_aloud.identifiers, position);
            if (*identifier != '\0') read_aloud.picker_callback(0, identifier,
                read_aloud.picker_context != NULL ? read_aloud.picker_context : ui.context);
        }
        return;
    }
    if (position != GTK_INVALID_LIST_POSITION) emit(JSTI_EVENT_VOICE_OUTPUT, "", (gint32)position);
}

static void on_favorite_voice(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress || read_aloud.favorite_indices == NULL) return;
    guint position = adw_combo_row_get_selected(read_aloud.favorite_row);
    if (position < read_aloud.favorite_indices->len) {
        guint index = g_array_index(read_aloud.favorite_indices, guint, position);
        if (adw_combo_row_get_selected(read_aloud.voice_row) != index) {
            adw_combo_row_set_selected(read_aloud.voice_row, index);
        }
    }
}

static void on_favorite_toggle(GtkButton *button, gpointer data) {
    (void)data;
    guint position = adw_combo_row_get_selected(read_aloud.voice_row);
    if (ui.suppress || read_aloud.picker_callback == NULL || read_aloud.identifiers == NULL ||
        position >= read_aloud.identifiers->len) return;
    const char *identifier = g_ptr_array_index(read_aloud.identifiers, position);
    if (*identifier == '\0') return;
    gint32 rank = g_array_index(read_aloud.favorite_ranks, gint32, position);
    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
    read_aloud.favorite_pending = TRUE;
    read_aloud.picker_callback(rank >= 0 ? 2 : 1, identifier,
        read_aloud.picker_context != NULL ? read_aloud.picker_context : ui.context);
}

/* The voice Read aloud uses; the list comes from jsti_window_set_voices. */
GtkWidget *read_aloud_group(void) {
    GtkWidget *widget = group("Voice");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(widget),
        "Read aloud sends the displayed History transcript to the selected voice provider using its saved key. "
        "Play, Pause and Stop control playback.");
    read_aloud.voices = gtk_string_list_new(NULL);
    read_aloud.voice_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(read_aloud.voice_row), "Voice");
    adw_combo_row_set_model(read_aloud.voice_row, G_LIST_MODEL(read_aloud.voices));
    adw_combo_row_set_enable_search(read_aloud.voice_row, TRUE);
    g_signal_connect(read_aloud.voice_row, "notify::selected", G_CALLBACK(on_voice), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(widget), GTK_WIDGET(read_aloud.voice_row));
    read_aloud.favorite_names = gtk_string_list_new(NULL);
    read_aloud.favorite_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(read_aloud.favorite_row), "Favorites");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(read_aloud.favorite_row),
        "Choose a saved voice. Unavailable saved IDs are retained, not substituted.");
    adw_combo_row_set_model(read_aloud.favorite_row, G_LIST_MODEL(read_aloud.favorite_names));
    adw_combo_row_set_enable_search(read_aloud.favorite_row, TRUE);
    g_signal_connect(read_aloud.favorite_row, "notify::selected", G_CALLBACK(on_favorite_voice), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(widget), GTK_WIDGET(read_aloud.favorite_row));
    GtkWidget *favorite_action = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(favorite_action), "Favorite selected voice");
    read_aloud.favorite_button = GTK_BUTTON(gtk_button_new_with_label("Add to favorites"));
    gtk_widget_set_valign(GTK_WIDGET(read_aloud.favorite_button), GTK_ALIGN_CENTER);
    gtk_widget_set_size_request(GTK_WIDGET(read_aloud.favorite_button), -1, 36);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button), FALSE);
    g_signal_connect(read_aloud.favorite_button, "clicked", G_CALLBACK(on_favorite_toggle), NULL);
    adw_action_row_add_suffix(ADW_ACTION_ROW(favorite_action), GTK_WIDGET(read_aloud.favorite_button));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(widget), favorite_action);
    return widget;
}

static void voices_free(gpointer pointer) {
    Voices *voices = pointer;
    g_ptr_array_unref(voices->names);
    if (voices->identifiers != NULL) g_ptr_array_unref(voices->identifiers);
    if (voices->favorite_ranks != NULL) g_array_unref(voices->favorite_ranks);
    g_free(voices);
}

void voices_apply(gpointer pointer) {
    Voices *voices = pointer;
    guint old = adw_combo_row_get_selected(read_aloud.voice_row);
    const char *previous = read_aloud.identifiers != NULL && old < read_aloud.identifiers->len
        ? g_ptr_array_index(read_aloud.identifiers, old) : NULL;
    const char *next = voices->identifiers != NULL && voices->selected >= 0 &&
        (guint)voices->selected < voices->identifiers->len
        ? g_ptr_array_index(voices->identifiers, (guint)voices->selected) : NULL;
    if (previous == NULL || next == NULL || g_strcmp0(previous, next) != 0) {
        jsti_voice_credentials_selection_changed();
    }
    ui.suppress = TRUE;
    if (read_aloud.identifiers != NULL) g_ptr_array_unref(read_aloud.identifiers);
    if (read_aloud.favorite_ranks != NULL) g_array_unref(read_aloud.favorite_ranks);
    if (read_aloud.favorite_indices != NULL) g_array_unref(read_aloud.favorite_indices);
    read_aloud.identifiers = voices->identifiers != NULL ? g_ptr_array_ref(voices->identifiers) : NULL;
    read_aloud.favorite_ranks = voices->favorite_ranks != NULL ? g_array_ref(voices->favorite_ranks) : NULL;
    read_aloud.picker_callback = voices->callback;
    read_aloud.picker_context = voices->context;
    read_aloud.favorite_indices = g_array_new(FALSE, FALSE, sizeof(guint));
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices));
    g_ptr_array_add(voices->names, NULL);
    gtk_string_list_splice(read_aloud.voices, 0, existing, (const char *const *)voices->names->pdata);
    g_ptr_array_set_size(voices->names, voices->names->len - 1);
    if (voices->selected >= 0 && (guint)voices->selected < voices->names->len) {
        adw_combo_row_set_selected(read_aloud.voice_row, (guint)voices->selected);
    }
    gtk_string_list_splice(read_aloud.favorite_names, 0,
        g_list_model_get_n_items(G_LIST_MODEL(read_aloud.favorite_names)), NULL);
    guint favorite_selected = GTK_INVALID_LIST_POSITION;
    for (guint rank = 0; rank < voices->names->len && voices->favorite_ranks != NULL; ++rank) {
        for (guint index = 0; index < voices->names->len; ++index) {
            if (g_array_index(voices->favorite_ranks, gint32, index) != (gint32)rank) continue;
            if ((gint32)index == voices->selected) favorite_selected = read_aloud.favorite_indices->len;
            g_array_append_val(read_aloud.favorite_indices, index);
            gtk_string_list_append(read_aloud.favorite_names, g_ptr_array_index(voices->names, index));
        }
    }
    gboolean has_favorites = read_aloud.favorite_indices->len > 0;
    if (!has_favorites) {
        gtk_string_list_append(read_aloud.favorite_names, "No available favorites - add a voice below");
        favorite_selected = 0;
    } else if (favorite_selected == GTK_INVALID_LIST_POSITION) {
        /* A display-only row has no entry in favorite_indices and emits no voice choice. */
        favorite_selected = read_aloud.favorite_indices->len;
        gtk_string_list_append(read_aloud.favorite_names, "Choose a favorite…");
    }
    adw_combo_row_set_selected(read_aloud.favorite_row, favorite_selected);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_row), has_favorites);
    gboolean executable = next != NULL && *next != '\0';
    read_aloud.favorite_executable = executable && voices->callback != NULL;
    read_aloud.favorite_pending = FALSE;
    gboolean favorite = executable &&
        g_array_index(voices->favorite_ranks, gint32, voices->selected) >= 0;
    gtk_button_set_label(read_aloud.favorite_button, favorite ? "Remove from favorites" : "Add to favorites");
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button), executable && voices->callback != NULL);
    ui.suppress = FALSE;
    refresh_actions();
}

int32_t jsti_window_set_voice_picker(const char *const *names, const char *const *ids,
    const int32_t *favorite_ranks, size_t count, int32_t selected,
    JSTIVoicePickerCallback callback, void *context) {
    if (names == NULL || ids == NULL || favorite_ranks == NULL || callback == NULL ||
        count == 0 || count > 1024 || selected < 0 || (size_t)selected >= count) return -1;
    Voices *voices = g_new0(Voices, 1);
    voices->names = g_ptr_array_new_with_free_func(g_free);
    voices->identifiers = g_ptr_array_new_with_free_func(g_free);
    voices->favorite_ranks = g_array_new(FALSE, FALSE, sizeof(gint32));
    for (size_t index = 0; index < count; ++index) {
        if (names[index] == NULL || ids[index] == NULL || !g_utf8_validate(names[index], -1, NULL) ||
            !g_utf8_validate(ids[index], -1, NULL) || strlen(names[index]) > 1024 || strlen(ids[index]) > 260 ||
            favorite_ranks[index] < -1 || favorite_ranks[index] >= (gint32)count ||
            (*ids[index] == '\0' && favorite_ranks[index] != -1)) {
            voices_free(voices); return -1;
        }
        for (size_t prior = 0; prior < index; ++prior) {
            if (strcmp(ids[prior], ids[index]) == 0 ||
                (favorite_ranks[index] >= 0 && favorite_ranks[prior] == favorite_ranks[index])) {
                voices_free(voices); return -1;
            }
        }
        g_ptr_array_add(voices->names, g_strdup(names[index]));
        g_ptr_array_add(voices->identifiers, g_strdup(ids[index]));
        g_array_append_val(voices->favorite_ranks, favorite_ranks[index]);
    }
    voices->selected = selected;
    voices->callback = callback;
    voices->context = context;
    return post(voices_apply, voices, voices_free);
}

int32_t jsti_window_set_voices(const char *const *names, size_t count, int32_t selected) {
    if (count > 0 && names == NULL) return -1;
    Voices *voices = g_new0(Voices, 1);
    voices->names = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) g_ptr_array_add(voices->names, g_strdup(names[index]));
    voices->selected = selected;
    return post(voices_apply, voices, voices_free);
}

gboolean read_aloud_has_voices(void) {
    return read_aloud.voices != NULL && g_list_model_get_n_items(G_LIST_MODEL(read_aloud.voices)) > 0;
}

void read_aloud_refresh_actions(gboolean idle) {
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.voice_row), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_row),
        idle && read_aloud.favorite_indices != NULL && read_aloud.favorite_indices->len > 0);
    gtk_widget_set_sensitive(GTK_WIDGET(read_aloud.favorite_button),
        idle && read_aloud.favorite_executable && !read_aloud.favorite_pending);
}

/* The run is over: the host's picker callback and voice list go with it. */
void read_aloud_close(void) {
    read_aloud.picker_callback = NULL;
    read_aloud.picker_context = NULL;
    g_clear_pointer(&read_aloud.identifiers, g_ptr_array_unref);
    g_clear_pointer(&read_aloud.favorite_ranks, g_array_unref);
    g_clear_pointer(&read_aloud.favorite_indices, g_array_unref);
    g_clear_object(&read_aloud.voices);
    g_clear_object(&read_aloud.favorite_names);
}
