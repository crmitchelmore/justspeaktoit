/* jsti_window_* setters for insights, About, login item, automation, HUD, sidebar, voices and notices. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowAboutPage.h"
#include "LinuxWindowDashboardPage.h"
#include "LinuxWindowGeneralPage.h"
#include "LinuxWindowHistoryPage.h"
#include "LinuxWindowOutputPage.h"
#include "LinuxWindowPolishPage.h"

void insights_free(gpointer pointer) {
    Insights *insights = pointer;
    for (int index = 0; index < 5; index++) {
        g_free(insights->all[index]);
        g_free(insights->visible[index]);
    }
    g_free(insights);
}

void insights_apply(gpointer pointer) {
    Insights *insights = pointer;
    /* Order: sessions, errors, recording time, average length, spend. */
    gtk_label_set_text(dashboard_page()->hero_sessions, insights->all[0]);
    gtk_label_set_text(dashboard_page()->hero_time, insights->all[2]);
    gtk_label_set_text(dashboard_page()->hero_spend, insights->all[4]);
    gtk_label_set_text(dashboard_page()->insight_sessions, insights->all[0]);
    gtk_label_set_text(dashboard_page()->insight_time, insights->all[2]);
    gtk_label_set_text(dashboard_page()->insight_average, insights->all[3]);
    gtk_label_set_text(dashboard_page()->insight_spend, insights->all[4]);
    history_show_insights(insights->visible[0], insights->visible[1], insights->visible[3], insights->visible[4]);
    /* The status notifier's menu shows the dashboard's totals, as the Mac's menu bar extra does. */
    g_free(ui.tray_summary);
    ui.tray_summary = g_strcmp0(insights->all[0], "0") == 0
        ? g_strdup("No sessions yet")
        : g_strdup_printf("%s %s · %s · %s", insights->all[0],
                          g_strcmp0(insights->all[0], "1") == 0 ? "session" : "sessions", insights->all[2],
                          insights->all[4]);
    jsti_tray_set_state(ui.state, ui.tray_summary);
}

void insights_copy(gchar **target, const JSTIInsights *source) {
    const char *values[5] = { "0", "0", "—", "—", "—" };
    if (source != NULL) {
        values[0] = source->sessions;
        values[1] = source->errors;
        values[2] = source->recording_time;
        values[3] = source->average_length;
        values[4] = source->spend;
    }
    for (int index = 0; index < 5; index++) target[index] = g_strdup(values[index] != NULL ? values[index] : "—");
}

int32_t jsti_window_set_insights(const JSTIInsights *all, const JSTIInsights *visible) {
    Insights *insights = g_new0(Insights, 1);
    insights_copy(insights->all, all);
    insights_copy(insights->visible, visible);
    return post(insights_apply, insights, insights_free);
}

static void appearance_apply(gpointer data) {
    ui.suppress = TRUE;
    adw_combo_row_set_selected(general_page()->appearance_row, (guint)GPOINTER_TO_INT(data));
    apply_appearance((guint)GPOINTER_TO_INT(data));
    ui.suppress = FALSE;
}

typedef struct AboutInformation {
    gchar *details;
    gchar **titles;
    gchar **urls;
} AboutInformation;

static void about_information_free(gpointer pointer) {
    AboutInformation *information = pointer;
    g_free(information->details);
    g_strfreev(information->titles);
    g_strfreev(information->urls);
    g_free(information);
}

static void about_information_apply(gpointer pointer) {
    AboutInformation *information = pointer;
    gtk_label_set_text(about_page()->about_details, information->details);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(about_page()->about_links))) != NULL)
        gtk_flow_box_remove(about_page()->about_links, child);
    for (guint i = 0; information->titles[i] != NULL; ++i)
        gtk_flow_box_insert(about_page()->about_links, link_button(information->titles[i], information->urls[i]), -1);
}

int32_t jsti_window_configure_about(const char *details, const JSTIAboutLink *links, size_t count) {
    if (details == NULL || links == NULL || count == 0 || count > 8 || strlen(details) > 4096 ||
        !g_utf8_validate(details, -1, NULL) || details[0] == '\0') return -1;
    for (size_t i = 0; i < count; ++i) {
        if (links[i].title == NULL || links[i].url == NULL || strlen(links[i].title) > 128 ||
            strlen(links[i].url) > 2048 || !g_utf8_validate(links[i].title, -1, NULL) ||
            !g_utf8_validate(links[i].url, -1, NULL) || links[i].title[0] == '\0' ||
            strpbrk(links[i].title, "\r\n\t") != NULL || !g_str_has_prefix(links[i].url, "https://") ||
            strlen(links[i].url) <= 8 || strpbrk(links[i].url, " \r\n\t") != NULL) return -1;
    }
    AboutInformation *information = g_new0(AboutInformation, 1);
    information->details = g_strdup(details);
    information->titles = g_new0(gchar *, count + 1);
    information->urls = g_new0(gchar *, count + 1);
    for (size_t i = 0; i < count; ++i) {
        information->titles[i] = g_strdup(links[i].title);
        information->urls[i] = g_strdup(links[i].url);
    }
    return post(about_information_apply, information, about_information_free);
}

void post_processing_enabled_apply(gpointer pointer) {
    gboolean suppress = ui.suppress;
    ui.suppress = TRUE;
    adw_switch_row_set_active(polish_page()->polish_row, *(gint32 *)pointer != 0);
    ui.suppress = suppress;
}

int32_t jsti_window_set_post_processing_enabled(int32_t enabled) {
    if (enabled != 0 && enabled != 1) return -1;
    gint32 *value = g_new(gint32, 1);
    *value = enabled;
    return post(post_processing_enabled_apply, value, g_free);
}

int32_t jsti_window_set_appearance(int32_t appearance) {
    if (appearance < 0 || appearance > 2) return -1;
    return post(appearance_apply, GINT_TO_POINTER(appearance), NULL);
}

static void login_item_free(gpointer pointer) {
    LoginItem *item = pointer;
    g_free(item->detail);
    g_free(item);
}

/* The shared DesktopLoginItemState: 0 off, 1 on, 2 off by the system,
 * 3 on by policy, 4 unavailable. Only 0 and 1 can be changed here. */
void login_item_apply(gpointer pointer) {
    LoginItem *item = pointer;
    ui.suppress = TRUE;
    adw_switch_row_set_active(general_page()->login_row, item->state == 1 || item->state == 3);
    ui.suppress = FALSE;
    gtk_widget_set_sensitive(GTK_WIDGET(general_page()->login_row), item->state == 0 || item->state == 1);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(general_page()->login_row), item->detail);
}

int32_t jsti_window_set_login_item(int32_t state, const char *detail) {
    if (state < 0 || state > 4 || detail == NULL || !g_utf8_validate(detail, -1, NULL)) return -1;
    LoginItem *item = g_new0(LoginItem, 1);
    item->state = state;
    item->detail = g_strdup(detail);
    return post(login_item_apply, item, login_item_free);
}

void automation_apply(gpointer pointer) {
    LoginItem *item = pointer;
    gboolean suppressed = ui.suppress;
    ui.suppress = TRUE;
    adw_switch_row_set_active(general_page()->automation_row, item->state != 0);
    ui.suppress = suppressed;
    gtk_widget_set_sensitive(GTK_WIDGET(general_page()->automation_row), TRUE);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(general_page()->automation_row), item->detail);
}

int32_t jsti_window_set_automation(int32_t enabled, const char *detail) {
    if ((enabled != 0 && enabled != 1) || detail == NULL || !g_utf8_validate(detail, -1, NULL)) return -1;
    LoginItem *item = g_new0(LoginItem, 1);
    item->state = enabled;
    item->detail = g_strdup(detail);
    return post(automation_apply, item, login_item_free);
}

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

static void sidebar_update_free(gpointer pointer) {
    SidebarUpdate *update = pointer;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) g_free(update->hints[page]);
    g_free(update);
}

void sidebar_update_apply(gpointer pointer) {
    SidebarUpdate *update = pointer;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
        sidebar_shortcuts.digits[page] = update->digits[page];
        GtkWidget *hint = sidebar_shortcuts.hints[page];
        const gchar *text = update->hints[page] != NULL ? update->hints[page] : "";
        gtk_label_set_text(GTK_LABEL(hint), text);
        gtk_widget_set_visible(hint, update->show_hints && text[0] != '\0');
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.sidebar, page);
        gchar *description = update->show_hints && text[0] != '\0' ? g_strdup_printf("Shortcut: %s.", text) : g_strdup("");
        gtk_accessible_update_property(GTK_ACCESSIBLE(row),
            GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
        g_free(description);
    }
    sidebar_shortcuts.configured = TRUE;
}

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

int32_t jsti_window_set_sidebar_shortcuts(const JSTISidebarShortcut *bindings, size_t count, int32_t show_hints) {
    if (bindings == NULL || count > 10 || (show_hints != 0 && show_hints != 1)) return -1;
    SidebarUpdate *update = g_new0(SidebarUpdate, 1);
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) update->digits[page] = -1;
    gboolean used[10] = { FALSE };
    for (size_t index = 0; index < count; ++index) {
        const JSTISidebarShortcut *binding = &bindings[index];
        gchar expected[8];
        g_snprintf(expected, sizeof(expected), "Ctrl+%d", binding->digit);
        if (binding->destination == NULL || binding->digit < 0 || binding->digit > 9 ||
            used[binding->digit] || g_strcmp0(binding->hint, expected) != 0) {
            sidebar_update_free(update);
            return -1;
        }
        used[binding->digit] = TRUE;
        for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
            if (g_strcmp0(page_info[page].name, binding->destination) != 0) continue;
            if (update->digits[page] != -1) { sidebar_update_free(update); return -1; }
            update->digits[page] = binding->digit;
            update->hints[page] = g_strdup(binding->hint);
        }
    }
    update->show_hints = show_hints != 0;
    return post(sidebar_update_apply, update, sidebar_update_free);
}

int32_t jsti_window_show_page(int32_t page) {
    if (page < 0 || page >= JSTI_PAGE_COUNT) return -1;
    return post(page_apply, GINT_TO_POINTER(page), NULL);
}

static void style_apply(gpointer data) {
    ui.suppress = TRUE;
    adw_combo_row_set_selected(output_page()->style_row, (guint)GPOINTER_TO_INT(data));
    ui.suppress = FALSE;
}

int32_t jsti_window_set_shortcut_style(int32_t index) {
    if (index < 0 || index > 3) return -1;
    return post(style_apply, GINT_TO_POINTER(index), NULL);
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
