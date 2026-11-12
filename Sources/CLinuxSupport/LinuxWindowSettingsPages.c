/* Settings pages: Voice output, General, Transcription, Keyboard, iCloud and
 * About, composed from each section's owner. Owns the Voice, General and About
 * page state (LinuxWindow{Voice,General,About}State.h). */
#include "LinuxWindowAboutState.h"
#include "LinuxWindowDashboardPage.h"
#include "LinuxWindowGeneralState.h"
#include "LinuxWindowHistoryPage.h"
#include "LinuxWindowModelsPage.h"
#include "LinuxWindowOutputPage.h"
#include "LinuxWindowStoragePage.h"
#include "LinuxWindowVoiceState.h"

static VoicePage voice_state;
VoicePage *voice_page(void) { return &voice_state; }

static GeneralPage general_state;
GeneralPage *general_page(void) { return &general_state; }

static AboutPage about_state;
AboutPage *about_page(void) { return &about_state; }

static void on_voice_sources(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    gboolean presented = history_selection_presented();
    gchar *snapshot = presented ? displayed_transcript() : g_strdup("");
    jsti_show_voice_sources(ui.window, presented ? history_selected_id() : "", snapshot);
    g_free(snapshot);
}

GtkWidget *build_voice_output(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), jsti_hero_new(
        "voice", "Voice Output",
        "Read History, typed text, clipboard snapshots or imported text with your selected voice. "
        "Export lossless WAV audio.", NULL,
        NULL));
    GtkWidget *body;
    GtkWidget *card = jsti_card_new("audio-speakers-symbolic", "Read aloud", &body);
    gtk_box_append(GTK_BOX(body), read_aloud_group());
    gtk_box_append(GTK_BOX(body), jsti_voice_credentials_group_new());
    GtkWidget *note = gtk_label_new(
        "Choose a recording in History, or open Text and export for typed/pasted text and an explicit clipboard "
        "snapshot. For external selected text, allow session access below and use a desktop shortcut after "
        "refocusing the external field. Recording, another playback or Stop ends voice output.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_widget_add_css_class(note, "dim-label");
    gtk_box_append(GTK_BOX(body), note);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    voice_page()->voice_stop = GTK_BUTTON(gtk_button_new_with_label("Stop"));
    g_signal_connect(voice_page()->voice_stop, "clicked", G_CALLBACK(on_stop_play), NULL);
    voice_page()->voice_read = GTK_BUTTON(gtk_button_new_with_label("Read Selected Recording"));
    voice_page()->voice_sources = GTK_BUTTON(gtk_button_new_with_label("Text and export..."));
    g_signal_connect(voice_page()->voice_sources, "clicked", G_CALLBACK(on_voice_sources), NULL);
    gtk_widget_add_css_class(GTK_WIDGET(voice_page()->voice_read), "suggested-action");
    g_signal_connect(voice_page()->voice_read, "clicked", G_CALLBACK(on_read_aloud), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(voice_page()->voice_stop));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(voice_page()->voice_sources));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(voice_page()->voice_read));
    gtk_box_append(GTK_BOX(body), actions);
    gtk_box_append(GTK_BOX(column), card);
    gtk_box_append(GTK_BOX(column), jsti_selection_access_group_new());
    return page;
}

void voice_page_refresh_actions(gboolean idle, gboolean readable, gboolean voices) {
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_read), readable);
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_stop), !ui.closing);
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_sources), idle && voices);
}

static void apply_appearance(guint appearance) {
    static const AdwColorScheme schemes[] = { ADW_COLOR_SCHEME_DEFAULT, ADW_COLOR_SCHEME_FORCE_LIGHT,
                                              ADW_COLOR_SCHEME_FORCE_DARK };
    if (appearance < G_N_ELEMENTS(schemes)) {
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), schemes[appearance]);
    }
}

static void on_appearance(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint appearance = adw_combo_row_get_selected(general_page()->appearance_row);
    apply_appearance(appearance);
    emit(JSTI_EVENT_APPEARANCE, "", (gint32)appearance);
}

/* Launch at login. The switch waits, insensitive, for the state the desktop
 * reached, which jsti_window_set_login_item reports. */
static void on_login_item(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    gtk_widget_set_sensitive(GTK_WIDGET(general_page()->login_row), FALSE);
    emit(JSTI_EVENT_LOGIN_ITEM, "", adw_switch_row_get_active(general_page()->login_row) ? 1 : 0);
}

static void on_automation(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (ui.suppress) return;
    gtk_widget_set_sensitive(GTK_WIDGET(general_page()->automation_row), FALSE);
    emit(JSTI_EVENT_AUTOMATION, "", adw_switch_row_get_active(general_page()->automation_row) ? 1 : 0);
}

static void appearance_apply(gpointer data) {
    ui.suppress = TRUE;
    adw_combo_row_set_selected(general_page()->appearance_row, (guint)GPOINTER_TO_INT(data));
    apply_appearance((guint)GPOINTER_TO_INT(data));
    ui.suppress = FALSE;
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

GtkWidget *build_general(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[0] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "General", "Choose the microphone, where finished text goes, whether the app starts at login, and how "
        "it looks."));
    gtk_box_append(GTK_BOX(column), microphone_group());

    gtk_box_append(GTK_BOX(column), output_group());
    gtk_box_append(GTK_BOX(column), jsti_api_keys_group_new(ui.window));

    GtkWidget *startup = group("Startup");
    general_page()->login_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(general_page()->login_row), "Launch at login");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(general_page()->login_row), "Checking the desktop's startup settings…");
    gtk_widget_set_sensitive(GTK_WIDGET(general_page()->login_row), FALSE);
    g_signal_connect(general_page()->login_row, "notify::active", G_CALLBACK(on_login_item), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(startup), GTK_WIDGET(general_page()->login_row));
    gtk_box_append(GTK_BOX(column), startup);

    GtkWidget *automation = group("Automation");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(automation),
        "The speak command uses a private, same-user local socket. Off by default. "
        "Imported preferences cannot grant access on this computer.");
    general_page()->automation_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(general_page()->automation_row), "Allow local automation");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(general_page()->automation_row), "Automation is off.");
    g_signal_connect(general_page()->automation_row, "notify::active", G_CALLBACK(on_automation), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(automation), GTK_WIDGET(general_page()->automation_row));
    gtk_box_append(GTK_BOX(column), automation);
    gtk_box_append(GTK_BOX(column), jsti_system_resources_group_new());

    GtkWidget *appearance = group("Appearance");
    const char *schemes[] = { "Follow the system", "Light", "Dark", NULL };
    general_page()->appearance_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(general_page()->appearance_row), "Theme");
    adw_combo_row_set_model(general_page()->appearance_row, G_LIST_MODEL(gtk_string_list_new(schemes)));
    g_signal_connect(general_page()->appearance_row, "notify::selected", G_CALLBACK(on_appearance), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(appearance), GTK_WIDGET(general_page()->appearance_row));
    gtk_box_append(GTK_BOX(column), appearance);
    storage_groups_add(column);
    return page;
}

static void open_comparison(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (ui.state == JSTI_STATE_IDLE) jsti_comparison_open(ui.window);
}

GtkWidget *build_transcription(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[1] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Transcription", "Pick the speech model for new recordings, on this computer or with your own provider key."));
    gtk_box_append(GTK_BOX(column), models_group());
    gtk_box_append(GTK_BOX(column), jsti_local_models_group_new());
    GtkWidget *comparison = group("Compare Models");
    GtkWidget *compare = gtk_button_new_with_label("Compare Models…");
    g_signal_connect(compare, "clicked", G_CALLBACK(open_comparison), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(comparison), compare);
    gtk_box_append(GTK_BOX(column), comparison);
    return page;
}

GtkWidget *build_keyboard(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    ui.configuration_columns[3] = column;
    gtk_box_append(GTK_BOX(column), settings_hero(
        "Keyboard", "Start and stop dictation from anywhere with a global shortcut."));
    gtk_box_append(GTK_BOX(column), shortcut_group());
    gtk_box_append(GTK_BOX(column), jsti_action_shortcuts_group_new(ui.window));
    return page;
}

GtkWidget *build_cloud_sync(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    gtk_box_append(GTK_BOX(column), settings_hero(
        "iCloud Sync", "Keep History in step with your Mac, through your own iCloud account."));
    gtk_box_append(GTK_BOX(column), jsti_cloud_sync_group_new());
    return page;
}

static void open_link_finished(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(source), result, &error)) {
        g_warning("Could not open the browser: %s", error->message);
        if (ui.window != NULL && !ui.closing) {
            gtk_label_set_text(ui.status, "Could not open your browser. Check your default browser settings.");
        }
        g_error_free(error);
    }
}

static void open_link(GtkButton *button, gpointer data) {
    (void)button;
    GtkUriLauncher *launcher = gtk_uri_launcher_new(data);
    gtk_uri_launcher_launch(launcher, ui.window, NULL, open_link_finished, NULL);
    g_object_unref(launcher);
}

GtkWidget *link_button(const char *label, const char *uri) {
    GtkWidget *button = gtk_button_new_with_label(label);
    g_object_set_data_full(G_OBJECT(button), "about-uri", g_strdup(uri), g_free);
    gtk_widget_set_tooltip_text(button, uri);
    g_signal_connect(button, "clicked", G_CALLBACK(open_link), g_object_get_data(G_OBJECT(button), "about-uri"));
    return button;
}

static void on_troubleshooting(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    jsti_troubleshooting_open(ui.window);
}

static void on_permissions(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    jsti_permissions_open(ui.window);
}

static void on_setup(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (!ui.closing) jsti_setup_open(ui.window);
}

static void request_setup(gpointer data) { (void)data; on_setup(NULL, NULL); }
int32_t jsti_window_request_setup(void) { return jsti_window_post(request_setup, NULL, NULL); }

static void request_permissions(gpointer data) {
    (void)data;
    if (!ui.closing) jsti_permissions_open(ui.window);
}

int32_t jsti_window_request_permissions(void) { return jsti_window_post(request_permissions, NULL, NULL); }

static void request_api_keys(gpointer data) {
    (void)data;
    if (!ui.closing && ui.state == JSTI_STATE_IDLE) jsti_api_keys_open(ui.window);
    else (void)jsti_window_update("Finish the current operation before opening API Keys.", NULL, -1);
}

int32_t jsti_window_request_api_keys(void) { return jsti_window_post(request_api_keys, NULL, NULL); }

gboolean action_shortcut_run(gint run, const char *page, gint slot) {
    if (ui.closing || !gtk_widget_is_sensitive(GTK_WIDGET(ui.window))) return FALSE;
    switch (run) {
    case 1:
        if (!dashboard_can_record()) return FALSE;
        on_record(NULL, NULL);
        return TRUE;
    case 2:
        for (gint index = 0; page != NULL && index < JSTI_PAGE_COUNT; ++index) {
            GtkWidget *row = GTK_WIDGET(gtk_list_box_get_row_at_index(ui.sidebar, index));
            if (g_strcmp0(page_name(index), page) != 0) continue;
            if (!gtk_widget_is_sensitive(row) || !gtk_widget_get_visible(row)) return FALSE;
            show_page(index);
            return TRUE;
        }
        return FALSE;
    case 3:
        if (!gtk_widget_is_sensitive(GTK_WIDGET(voice_page()->voice_stop))) return FALSE;
        on_stop_play(NULL, NULL);
        return TRUE;
    case 4: on_troubleshooting(NULL, NULL); return TRUE;
    case 5:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        open_comparison(NULL, NULL);
        return TRUE;
    case 6:
        if (ui.state != JSTI_STATE_IDLE || slot < 1 || slot > 3) return FALSE;
        emit(JSTI_EVENT_QUICK_VOICE, "", slot);
        return TRUE;
    case 7:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_SPEAK_CLIPBOARD, "", 0);
        return TRUE;
    case 8:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_SPEECH_PAUSE, "", 0);
        return TRUE;
    case 9:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_API_KEYS, "", 0);
        return TRUE;
    case 10:
        emit(JSTI_EVENT_PERMISSIONS, "", 0);
        return TRUE;
    case 11:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_PASTE_LAST_HISTORY, "", 0);
        return TRUE;
    case 12:
        if (ui.state != JSTI_STATE_IDLE) return FALSE;
        emit(JSTI_EVENT_SPEAK_SELECTED_TEXT, "", 0);
        return TRUE;
    default: return FALSE;
    }
}

GtkWidget *build_about(void) {
    GtkWidget *column, *page = jsti_page_new(&column);
    GtkWidget *body;
    GtkWidget *card = jsti_card_new("help-about-symbolic", "About", &body);
    GtkWidget *identity = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 18);
    gtk_box_append(GTK_BOX(identity), jsti_brand_icon_new(72));
    GtkWidget *names = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_valign(names, GTK_ALIGN_CENTER);
    GtkWidget *name = gtk_label_new("Just Speak to It");
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_widget_add_css_class(name, "jsti-about-name");
    gtk_box_append(GTK_BOX(names), name);
    GtkWidget *tagline = gtk_label_new("Voice-to-text made simple. Linux developer preview.");
    gtk_label_set_xalign(GTK_LABEL(tagline), 0);
    gtk_widget_add_css_class(tagline, "dim-label");
    gtk_box_append(GTK_BOX(names), tagline);
    gtk_box_append(GTK_BOX(identity), names);
    gtk_box_append(GTK_BOX(body), identity);
    GtkWidget *note = gtk_label_new(
        "Open source under the MIT licence. Your audio goes only to the provider you choose, or stays on this "
        "computer with an on-device model.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_box_append(GTK_BOX(body), note);
    about_page()->about_details = GTK_LABEL(gtk_label_new("Build metadata has not been supplied by this host."));
    gtk_label_set_xalign(about_page()->about_details, 0);
    gtk_label_set_selectable(about_page()->about_details, TRUE);
    gtk_label_set_wrap(about_page()->about_details, TRUE);
    gtk_box_append(GTK_BOX(body), GTK_WIDGET(about_page()->about_details));
    about_page()->about_links = GTK_FLOW_BOX(gtk_flow_box_new());
    gtk_flow_box_set_selection_mode(about_page()->about_links, GTK_SELECTION_NONE);
    gtk_flow_box_set_min_children_per_line(about_page()->about_links, 1);
    gtk_flow_box_set_max_children_per_line(about_page()->about_links, 3);
    gtk_flow_box_set_row_spacing(about_page()->about_links, 8);
    gtk_flow_box_set_column_spacing(about_page()->about_links, 8);
    gtk_box_append(GTK_BOX(body), GTK_WIDGET(about_page()->about_links));
    GtkWidget *troubleshooting = gtk_button_new_with_mnemonic("_Troubleshooting");
    gtk_widget_set_halign(troubleshooting, GTK_ALIGN_START);
    g_signal_connect(troubleshooting, "clicked", G_CALLBACK(on_troubleshooting), NULL);
    gtk_box_append(GTK_BOX(body), troubleshooting);
    GtkWidget *permissions = gtk_button_new_with_mnemonic("_Permissions");
    gtk_widget_set_size_request(permissions, -1, 44);
    gtk_widget_set_halign(permissions, GTK_ALIGN_START);
    g_signal_connect(permissions, "clicked", G_CALLBACK(on_permissions), NULL);
    GtkWidget *setup = gtk_button_new_with_label("Run setup again");
    gtk_widget_set_size_request(setup, -1, 44);
    gtk_widget_set_halign(setup, GTK_ALIGN_START);
    g_signal_connect(setup, "clicked", G_CALLBACK(on_setup), NULL);
    gtk_box_append(GTK_BOX(body), setup);
    gtk_box_append(GTK_BOX(body), permissions);
    gtk_box_append(GTK_BOX(column), card);
    return page;
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
    for (guint i = 0; information->titles[i] != NULL; ++i) {
        GtkWidget *link = link_button(information->titles[i], information->urls[i]);
        gtk_flow_box_insert(about_page()->about_links, link, -1);
        /* One Tab stop per link: an unfocusable flow box child hands focus to its button. */
        gtk_widget_set_focusable(gtk_widget_get_parent(link), FALSE);
    }
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
