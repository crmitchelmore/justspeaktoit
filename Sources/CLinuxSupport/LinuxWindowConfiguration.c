/* Dictation preferences: the configuration form, its updates and settings-search reveal. */
#include "LinuxWindowInternal.h"

typedef struct ConfigurationUpdate {
    GPtrArray *titles, *values, *groups, *recovered, *choices;
    GArray *booleans;
    GArray *overlay_settings;
    GArray *hands_free_settings;
    GArray *enabled_by_fields;
    JSTIConfigurationCallback callback;
    void *context;
    gchar *revision;
} ConfigurationUpdate;

static void configuration_problem(const char *message) {
    gtk_label_set_text(ui.status, message);
}

static void configuration_submit(gint32 action, const char *const *values, gsize count) {
    char error[1024] = {0};
    if (configuration.callback == NULL) {
        configuration_problem("Configuration controls are unavailable.");
    } else if (configuration.callback(action, values, count, configuration.context, error, sizeof(error)) != 0) {
        configuration_problem(error[0] ? error : "Configuration could not be applied.");
    }
}

void on_configuration_apply(GtkButton *button, gpointer data) {
    (void)button;
    if (ui.state != JSTI_STATE_IDLE) {
        configuration_problem("Finish dictation before changing configuration.");
        return;
    }
    GPtrArray *values = g_ptr_array_new_with_free_func(g_free);
    gint32 action = GPOINTER_TO_INT(data);
    for (guint i = 0; i < configuration.rows->len; ++i) {
        GtkWidget *row = g_ptr_array_index(configuration.rows, i);
        gboolean boolean = g_array_index(configuration.booleans, gboolean, i);
        const char *choices = g_ptr_array_index(configuration.choices, i);
        if (choices[0] != '\0') {
            gchar **lines = g_strsplit(choices, "\n", -1);
            guint selected = adw_combo_row_get_selected(ADW_COMBO_ROW(row));
            if (selected >= g_strv_length(lines)) {
                g_strfreev(lines);
                g_ptr_array_unref(values);
                configuration_problem("Choose a value for each preference first.");
                return;
            }
            g_ptr_array_add(values, g_strndup(lines[selected], strchr(lines[selected], '\t') - lines[selected]));
            g_strfreev(lines);
            continue;
        }
        g_ptr_array_add(values, g_strdup(boolean
            ? (adw_switch_row_get_active(ADW_SWITCH_ROW(row)) ? "1" : "0")
            : gtk_editable_get_text(GTK_EDITABLE(row))));
    }
    if (action == 3) {
        guint selected = adw_combo_row_get_selected(configuration.recovery_row);
        if (selected >= configuration.recovery_count) {
            configuration_problem("Choose a recovered keyword edit first.");
            g_ptr_array_unref(values);
            return;
        }
        GtkStringList *model = GTK_STRING_LIST(adw_combo_row_get_model(configuration.recovery_row));
        g_ptr_array_add(values, g_strdup(gtk_string_list_get_string(model, selected)));
    }
    if (configuration.revision != NULL)
        g_ptr_array_add(values, g_strdup(configuration.revision));
    configuration_submit(action, (const char *const *)values->pdata, values->len);
    g_ptr_array_unref(values);
}

static void configuration_file_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    gint32 action = GPOINTER_TO_INT(data);
    GError *error = NULL;
    GFile *file = action == 1 ? gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error)
                             : gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    if (file != NULL) {
        gchar *path = g_file_get_path(file);
        if (path != NULL) {
            const char *values[] = {path};
            configuration_submit(action, values, 1);
        } else configuration_problem("Choose a local configuration file.");
        g_free(path);
        g_object_unref(file);
    } else if (error != NULL && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)) {
        configuration_problem(error->message);
    }
    g_clear_error(&error);
}

static void on_configuration_file(GtkButton *button, gpointer data) {
    (void)button;
    gint32 action = GPOINTER_TO_INT(data);
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, action == 1 ? "Import portable preferences" : "Export portable preferences");
    if (action == 2) gtk_file_dialog_set_initial_name(dialog, "Dictation-preferences.json");
    if (action == 1) gtk_file_dialog_open(dialog, ui.window, NULL, configuration_file_chosen, data);
    else gtk_file_dialog_save(dialog, ui.window, NULL, configuration_file_chosen, data);
    g_object_unref(dialog);
}

static void configuration_update_free(gpointer data) {
    ConfigurationUpdate *update = data;
    g_ptr_array_unref(update->titles);
    g_ptr_array_unref(update->values);
    g_ptr_array_unref(update->groups);
    g_ptr_array_unref(update->recovered);
    g_ptr_array_unref(update->choices);
    g_array_unref(update->booleans);
    g_array_unref(update->overlay_settings);
    g_array_unref(update->hands_free_settings);
    g_array_unref(update->enabled_by_fields);
    g_free(update->revision);
    g_free(update);
}

void configuration_hands_free_availability(GtkWidget *row, gboolean enabled) {
    gboolean ready = jsti_window_hands_free_guard_ready() != 0;
    gtk_widget_set_sensitive(row, ready || enabled);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(row), ready ? NULL : enabled ?
        "Monitoring unavailable. Turn off saved hands-free mode to restore manual shortcuts." :
        "Unavailable: native session lock/sleep monitoring is required. Manual recording still works.");
}

static void configuration_dependencies(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        gint32 enabling = g_array_index(configuration.enabled_by_fields, gint32, i);
        if (enabling == -1) {
            GtkWidget *row = g_ptr_array_index(configuration.rows, i);
            gtk_widget_set_sensitive(row, FALSE);
            adw_action_row_set_subtitle(ADW_ACTION_ROW(row),
                "Unavailable on this host: no confirmed editable field/span readback. Retained for transfer.");
            continue;
        }
        if (!enabling) continue;
        AdwSwitchRow *control = ADW_SWITCH_ROW(g_ptr_array_index(configuration.rows, enabling - 1));
        gtk_widget_set_sensitive(g_ptr_array_index(configuration.rows, i), adw_switch_row_get_active(control));
    }
}

static void configuration_apply(gpointer data) {
    ConfigurationUpdate *update = data;
    configuration.callback = update->callback;
    configuration.context = update->context;
    g_free(configuration.revision);
    configuration.revision = g_strdup(update->revision);
    if (configuration.rows == NULL) {
        configuration.rows = g_ptr_array_new();
        configuration.choices = g_ptr_array_ref(update->choices);
        configuration.booleans = g_array_ref(update->booleans);
        configuration.overlay_settings = g_array_ref(update->overlay_settings);
        configuration.hands_free_settings = g_array_ref(update->hands_free_settings);
        configuration.enabled_by_fields = g_array_ref(update->enabled_by_fields);
        GtkWidget *groups[5];
        for (guint i = 0; i < G_N_ELEMENTS(groups); ++i) {
            groups[i] = group(i == 4 ? "Correction learning" : "Dictation preferences");
            adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(groups[i]),
                i == 4 ? "Apply saves all preference fields. Enabling learning does not grant local session permission."
                : "Apply saves all preference fields. Provider-specific options only affect supported routes.");
            gtk_box_append(GTK_BOX(ui.configuration_columns[i]), groups[i]);
        }
        if (!jsti_hud_overlay_supported())
            adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(groups[0]),
                "Wayland uses desktop notifications, not a positioned recording overlay. "
                "Overlay-only preferences are retained for X11 but hidden here; your desktop controls notification expiry.");
        for (guint i = 0; i < update->titles->len; ++i) {
            const char *section = g_ptr_array_index(update->groups, i);
            guint slot = g_strcmp0(section, "Transcription") == 0 ? 1 :
                g_strcmp0(section, "Post-processing") == 0 ? 2 : g_strcmp0(section, "Keyboard") == 0 ? 3 :
                g_strcmp0(section, "Corrections") == 0 ? 4 : 0;
            gboolean boolean = g_array_index(update->booleans, gboolean, i);
            const char *choices = g_ptr_array_index(update->choices, i);
            GtkWidget *row = boolean ? adw_switch_row_new() :
                choices[0] != '\0' ? adw_combo_row_new() : adw_entry_row_new();
            if (choices[0] != '\0') {
                gchar **lines = g_strsplit(choices, "\n", -1);
                GtkStringList *model = gtk_string_list_new(NULL);
                for (guint choice = 0; lines[choice] != NULL; ++choice)
                    gtk_string_list_append(model, strchr(lines[choice], '\t') + 1);
                adw_combo_row_set_model(ADW_COMBO_ROW(row), G_LIST_MODEL(model));
                g_object_unref(model);
                g_strfreev(lines);
            }
            adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), g_ptr_array_index(update->titles, i));
            adw_preferences_group_add(ADW_PREFERENCES_GROUP(groups[slot]), row);
            if (g_array_index(update->overlay_settings, gboolean, i) && !jsti_hud_overlay_supported())
                gtk_widget_set_visible(row, FALSE);
            g_ptr_array_add(configuration.rows, row);
            if (boolean) g_signal_connect(row, "notify::active", G_CALLBACK(configuration_dependencies), NULL);
        }
        for (guint i = 0; i < G_N_ELEMENTS(groups); ++i) {
            GtkWidget *apply = gtk_button_new_with_label("Apply preferences");
            gtk_widget_set_halign(apply, GTK_ALIGN_END);
            g_signal_connect(apply, "clicked", G_CALLBACK(on_configuration_apply), NULL);
            adw_preferences_group_add(ADW_PREFERENCES_GROUP(groups[i]), apply);
        }
        GtkWidget *sound_previews = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *preview_start = gtk_button_new_with_label("Save & preview start");
        GtkWidget *preview_stop = gtk_button_new_with_label("Save & preview stop");
        g_signal_connect(preview_start, "clicked", G_CALLBACK(on_configuration_apply), GINT_TO_POINTER(4));
        g_signal_connect(preview_stop, "clicked", G_CALLBACK(on_configuration_apply), GINT_TO_POINTER(5));
        gtk_box_append(GTK_BOX(sound_previews), preview_start);
        gtk_box_append(GTK_BOX(sound_previews), preview_stop);
        adw_preferences_group_add(ADW_PREFERENCES_GROUP(groups[0]), sound_previews);
        configuration.recovery_group = group("Recovered keyword edits");
        adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(configuration.recovery_group),
            "A deliberate clear remains active. Restore only the edit you choose; it is added to your current list.");
        configuration.recovery_row = ADW_COMBO_ROW(adw_combo_row_new());
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(configuration.recovery_row), "Recovered keyword edit");
        adw_preferences_group_add(ADW_PREFERENCES_GROUP(configuration.recovery_group),
            GTK_WIDGET(configuration.recovery_row));
        GtkWidget *restore = gtk_button_new_with_label("Restore selected keywords");
        gtk_widget_set_halign(restore, GTK_ALIGN_END);
        g_signal_connect(restore, "clicked", G_CALLBACK(on_configuration_apply), GINT_TO_POINTER(3));
        adw_preferences_group_add(ADW_PREFERENCES_GROUP(configuration.recovery_group), restore);
        gtk_box_append(GTK_BOX(ui.configuration_columns[1]), configuration.recovery_group);
        GtkWidget *transfer = group("Portable configuration");
        adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(transfer),
            "Transfers portable preferences, not keys, models, device paths or service permissions. "
            "This JSON format is not a macOS backup archive. Unsupported entries are preserved, not applied.");
        GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *import = gtk_button_new_with_label("Import preferences...");
        GtkWidget *export = gtk_button_new_with_label("Export preferences...");
        g_signal_connect(import, "clicked", G_CALLBACK(on_configuration_file), GINT_TO_POINTER(1));
        g_signal_connect(export, "clicked", G_CALLBACK(on_configuration_file), GINT_TO_POINTER(2));
        gtk_box_append(GTK_BOX(buttons), import);
        gtk_box_append(GTK_BOX(buttons), export);
        adw_preferences_group_add(ADW_PREFERENCES_GROUP(transfer), buttons);
        gtk_box_append(GTK_BOX(ui.configuration_columns[0]), transfer);
    }
    for (guint i = 0; i < update->values->len && i < configuration.rows->len; ++i) {
        GtkWidget *row = g_ptr_array_index(configuration.rows, i);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), g_ptr_array_index(update->titles, i));
        const char *value = g_ptr_array_index(update->values, i);
        if (g_array_index(configuration.booleans, gboolean, i))
            adw_switch_row_set_active(ADW_SWITCH_ROW(row), g_strcmp0(value, "1") == 0);
        else if (ADW_IS_COMBO_ROW(row)) {
            gchar **lines = g_strsplit(g_ptr_array_index(configuration.choices, i), "\n", -1);
            for (guint choice = 0; lines[choice] != NULL; ++choice) {
                const char *tab = strchr(lines[choice], '\t');
                if (strlen(value) == (size_t)(tab - lines[choice]) && strncmp(value, lines[choice], tab - lines[choice]) == 0)
                    adw_combo_row_set_selected(ADW_COMBO_ROW(row), choice);
            }
            g_strfreev(lines);
        } else gtk_editable_set_text(GTK_EDITABLE(row), value);
        if (g_array_index(configuration.hands_free_settings, gboolean, i))
            configuration_hands_free_availability(row, g_strcmp0(value, "1") == 0);
    }
    configuration_dependencies(NULL, NULL, NULL);
    GtkStringList *recovered = gtk_string_list_new(NULL);
    for (guint i = 0; i < update->recovered->len; ++i)
        gtk_string_list_append(recovered, g_ptr_array_index(update->recovered, i));
    adw_combo_row_set_model(configuration.recovery_row, G_LIST_MODEL(recovered));
    g_object_unref(recovered);
    configuration.recovery_count = update->recovered->len;
    gtk_widget_set_visible(configuration.recovery_group, configuration.recovery_count > 0);
    if (configuration.revision != NULL) {
        const char *values[] = {configuration.revision};
        configuration_submit(6, values, 1);
    }
}

gboolean configuration_choices_valid(const char *choices, const char *value) {
    if (choices == NULL || value == NULL || choices[0] == '\0' ||
        !g_utf8_validate(choices, -1, NULL) || strlen(choices) > 65535) return FALSE;
    gchar **lines = g_strsplit(choices, "\n", -1);
    gboolean valid = g_strv_length(lines) <= 32, found = FALSE;
    for (guint choice = 0; valid && lines[choice] != NULL; ++choice) {
        const char *tab = strchr(lines[choice], '\t');
        if (tab == NULL || tab[1] == '\0' || strchr(tab + 1, '\t') != NULL) {
            valid = FALSE;
            break;
        }
        const size_t length = (size_t)(tab - lines[choice]);
        for (guint previous = 0; previous < choice; ++previous) {
            const char *previous_tab = strchr(lines[previous], '\t');
            if ((size_t)(previous_tab - lines[previous]) == length &&
                strncmp(lines[previous], lines[choice], length) == 0) {
                valid = FALSE;
                break;
            }
        }
        found |= strlen(value) == length && strncmp(value, lines[choice], length) == 0;
    }
    g_strfreev(lines);
    return valid && found;
}

static int32_t set_configuration(const JSTIConfigurationField *fields, size_t count,
                                      const char *const *recovered_keywords, size_t recovered_count,
                                      JSTIConfigurationCallback callback, void *context, const char *revision) {
    if (fields == NULL || count == 0 || count > JSTI_MAXIMUM_CONFIGURATION_FIELDS ||
        callback == NULL || recovered_count > 1000 ||
        (recovered_count > 0 && recovered_keywords == NULL) ||
        (revision != NULL && (revision[0] == '\0' || strlen(revision) > 64))) return -1;
    ConfigurationUpdate *update = g_new0(ConfigurationUpdate, 1);
    update->titles = g_ptr_array_new_with_free_func(g_free);
    update->values = g_ptr_array_new_with_free_func(g_free);
    update->groups = g_ptr_array_new_with_free_func(g_free);
    update->recovered = g_ptr_array_new_with_free_func(g_free);
    update->choices = g_ptr_array_new_with_free_func(g_free);
    update->booleans = g_array_new(FALSE, FALSE, sizeof(gboolean));
    update->overlay_settings = g_array_new(FALSE, FALSE, sizeof(gboolean));
    update->hands_free_settings = g_array_new(FALSE, FALSE, sizeof(gboolean));
    update->enabled_by_fields = g_array_new(FALSE, FALSE, sizeof(gint32));
    update->callback = callback;
    update->context = context;
    update->revision = g_strdup(revision);
    for (size_t i = 0; i < recovered_count; ++i) {
        if (recovered_keywords[i] == NULL || !g_utf8_validate(recovered_keywords[i], -1, NULL) ||
            strlen(recovered_keywords[i]) > 65535) {
            configuration_update_free(update);
            return -1;
        }
        g_ptr_array_add(update->recovered, g_strdup(recovered_keywords[i]));
    }
    for (size_t i = 0; i < count; ++i) {
        const gint32 enabling = fields[i].enabled_by_field;
        if (enabling < -1 || (enabling > 0 && ((size_t)enabling > count ||
            (size_t)enabling == i + 1 || fields[enabling - 1].is_boolean != 1))) {
            configuration_update_free(update);
            return -1;
        }
        g_array_append_val(update->enabled_by_fields, enabling);
        if (!fields[i].title || !fields[i].value || !fields[i].group ||
            !g_utf8_validate(fields[i].value, -1, NULL) || strlen(fields[i].value) > 65535 ||
            (fields[i].requires_hud_overlay != 0 && fields[i].requires_hud_overlay != 1) ||
            (fields[i].requires_hands_free_guard != 0 && fields[i].requires_hands_free_guard != 1) ||
            (fields[i].requires_hands_free_guard && fields[i].is_boolean != 1)) {
            configuration_update_free(update);
            return -1;
        }
        const char *choices = fields[i].choices != NULL ? fields[i].choices : "";
        if (!g_utf8_validate(choices, -1, NULL) || strlen(choices) > 65535 ||
            (choices[0] != '\0' && fields[i].is_boolean != 0)) {
            configuration_update_free(update);
            return -1;
        }
        if (choices[0] != '\0' && !configuration_choices_valid(choices, fields[i].value)) {
            configuration_update_free(update);
            return -1;
        }
        g_ptr_array_add(update->choices, g_strdup(choices));
        g_ptr_array_add(update->titles, g_strdup(fields[i].title));
        g_ptr_array_add(update->values, g_strdup(fields[i].value));
        g_ptr_array_add(update->groups, g_strdup(fields[i].group));
        gboolean boolean = fields[i].is_boolean != 0;
        g_array_append_val(update->booleans, boolean);
        gboolean overlay_setting = fields[i].requires_hud_overlay != 0;
        g_array_append_val(update->overlay_settings, overlay_setting);
        gboolean hands_free_setting = fields[i].requires_hands_free_guard != 0;
        g_array_append_val(update->hands_free_settings, hands_free_setting);
    }
    g_atomic_int_compare_and_exchange(&configuration_field_count, 0, (gint)count);
    return post(configuration_apply, update, configuration_update_free);
}

int32_t jsti_window_set_configuration(const JSTIConfigurationField *fields, size_t count,
    const char *const *recovered, size_t recovered_count, JSTIConfigurationCallback callback, void *context) {
    return set_configuration(fields, count, recovered, recovered_count, callback, context, NULL);
}

int32_t jsti_window_set_configuration_revision(const JSTIConfigurationField *fields, size_t count,
    const char *const *recovered, size_t recovered_count, JSTIConfigurationCallback callback,
    void *context, const char *revision) {
    return revision != NULL ? set_configuration(fields, count, recovered, recovered_count, callback, context, revision) : -1;
}

static void configuration_title_free(gpointer data) {
    ConfigurationTitleUpdate *update = data;
    g_free(update->title);
    g_free(update);
}

void configuration_title_apply(gpointer data) {
    ConfigurationTitleUpdate *update = data;
    if (configuration.rows == NULL) return;
    if (update->index >= configuration.rows->len) {
        configuration_problem("The Voice language field could not be found.");
        return;
    }
    adw_preferences_row_set_title(
        ADW_PREFERENCES_ROW(g_ptr_array_index(configuration.rows, update->index)), update->title);
}

int32_t jsti_window_set_configuration_field_title(size_t index, const char *title) {
    if (index >= JSTI_MAXIMUM_CONFIGURATION_FIELDS || title == NULL || title[0] == '\0' ||
        !g_utf8_validate(title, -1, NULL) || strlen(title) > 256) return -1;
    ConfigurationTitleUpdate *update = g_new0(ConfigurationTitleUpdate, 1);
    update->index = index;
    update->title = g_strdup(title);
    return post(configuration_title_apply, update, configuration_title_free);
}
void configuration_availability_apply(gpointer data) {
    ConfigurationAvailabilityUpdate *update = data;
    if (configuration.rows == NULL) return;
    if (update->index >= configuration.rows->len ||
        g_array_index(configuration.enabled_by_fields, gint32, update->index) != 0) {
        configuration_problem("The Voice quality field availability could not be updated.");
        return;
    }
    gtk_widget_set_sensitive(g_ptr_array_index(configuration.rows, update->index), update->enabled);
}
int32_t jsti_window_set_configuration_field_enabled(size_t index, int32_t enabled) {
    if (index >= JSTI_MAXIMUM_CONFIGURATION_FIELDS || (enabled != 0 && enabled != 1)) return -1;
    ConfigurationAvailabilityUpdate *update = g_new0(ConfigurationAvailabilityUpdate, 1);
    update->index = index; update->enabled = enabled;
    return post(configuration_availability_apply, update, g_free);
}
Reveal reveal;

static void reveal_forget_target(void) {
    if (reveal.target == NULL) return;
    if (reveal.tick != 0) gtk_widget_remove_tick_callback(reveal.target, reveal.tick);
    gtk_widget_remove_css_class(reveal.target, "jsti-search-highlight");
    g_object_remove_weak_pointer(G_OBJECT(reveal.target), (gpointer *)&reveal.target);
    reveal.target = NULL;
    reveal.tick = 0;
}

void reveal_cancel(void) {
    if (reveal.highlight != 0) g_source_remove(reveal.highlight);
    reveal.highlight = 0;
    reveal_forget_target();
    reveal.tick = 0;
}

static gboolean reveal_highlight_done(gpointer data) {
    (void)data;
    reveal.highlight = 0;
    reveal_forget_target();
    return G_SOURCE_REMOVE;
}

/* Centres the row in its page's scrolled window. */
static void reveal_scroll(GtkWidget *row) {
    GtkWidget *scroller = gtk_widget_get_ancestor(row, GTK_TYPE_SCROLLED_WINDOW);
    if (scroller == NULL) return;
    GtkWidget *viewport = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(scroller));
    GtkWidget *content = GTK_IS_VIEWPORT(viewport) ? gtk_viewport_get_child(GTK_VIEWPORT(viewport)) : viewport;
    graphene_rect_t bounds;
    if (content == NULL || !gtk_widget_compute_bounds(row, content, &bounds)) return;
    GtkAdjustment *adjustment = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scroller));
    double page = gtk_adjustment_get_page_size(adjustment);
    double height = graphene_rect_get_height(&bounds);
    gtk_adjustment_set_value(adjustment, graphene_rect_get_y(&bounds) - MAX(0.0, (page - height) / 2.0));
}

/* The page was shown by the same queue just before; wait for it to be laid out. */
static gboolean reveal_tick(GtkWidget *row, GdkFrameClock *clock, gpointer data) {
    (void)clock; (void)data;
    if (++reveal.frames < 2 || gtk_widget_get_height(row) <= 0) {
        if (reveal.frames < 120) return G_SOURCE_CONTINUE;
        reveal.tick = 0;
        return G_SOURCE_REMOVE;
    }
    reveal.tick = 0;
    gtk_widget_grab_focus(row);
    reveal_scroll(row);
    return G_SOURCE_REMOVE;
}

void configuration_reveal_apply(gpointer data) {
    gsize index = GPOINTER_TO_SIZE(data);
    reveal_cancel();
    if (configuration.rows == NULL || index >= configuration.rows->len) return;
    GtkWidget *row = g_ptr_array_index(configuration.rows, index);
    if (!gtk_widget_get_visible(row)) return;
    reveal.target = row;
    g_object_add_weak_pointer(G_OBJECT(row), (gpointer *)&reveal.target);
    gtk_widget_add_css_class(row, "jsti-search-highlight");
    reveal.frames = 0;
    reveal.tick = gtk_widget_add_tick_callback(row, reveal_tick, NULL, NULL);
    reveal.highlight = g_timeout_add(2500, reveal_highlight_done, NULL);
}

int32_t jsti_window_reveal_configuration_field(size_t index) {
    if (index >= (size_t)g_atomic_int_get(&configuration_field_count)) return -1;
    return post(configuration_reveal_apply, GSIZE_TO_POINTER(index), NULL);
}
