#include "LinuxWindowInternal.h"

#include <string.h>

/*
 * Settings panels below History: Read aloud, the Azure Speech resource, iCloud
 * sync and startup. Like the rest of the window they hold no application
 * state: every control reports an event and Swift pushes the saved state back.
 */

typedef struct Panels {
    /* Read aloud */
    GtkStringList *voices;
    AdwComboRow *voice_row;
    /* Azure Speech */
    AdwEntryRow *azure_row;
    /* iCloud sync */
    GtkLabel *sync_status;
    GtkButton *sync_sign_in;
    GtkButton *sync_sign_out;
    GtkButton *sync_now;
    AdwSwitchRow *sync_history;
    AdwSwitchRow *sync_keys;
    AdwPasswordEntryRow *sync_passphrase;
    GtkButton *sync_apply;
    gboolean sync_available;
    gboolean sync_signed_in;
    /* Startup */
    AdwSwitchRow *autostart_row;
    AdwActionRow *tray_row;
    gboolean autostart_available;
    gboolean idle;
} Panels;

static Panels panels = { .idle = TRUE };

/* ------------------------------------------------------------ callbacks */

static void on_voice(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint selected = adw_combo_row_get_selected(panels.voice_row);
    if (selected != GTK_INVALID_LIST_POSITION) jsti_window_emit(JSTI_EVENT_VOICE, "", (gint32)selected);
}

static void on_azure_apply(AdwEntryRow *row, gpointer data) {
    (void)data;
    jsti_window_emit(JSTI_EVENT_AZURE_RESOURCE, gtk_editable_get_text(GTK_EDITABLE(row)), 0);
}

static gint32 sync_flags(void) {
    gint32 flags = 0;
    if (adw_switch_row_get_active(panels.sync_history)) flags |= JSTI_CLOUD_SYNC_HISTORY;
    if (adw_switch_row_get_active(panels.sync_keys)) flags |= JSTI_CLOUD_SYNC_KEYS;
    return flags;
}

static void emit_sync(gint32 action) {
    const char *typed = gtk_editable_get_text(GTK_EDITABLE(panels.sync_passphrase));
    gchar *passphrase = g_strdup(action == 1 ? typed : "");
    /* The passphrase leaves the field as soon as it is read. */
    if (action == 1) gtk_editable_set_text(GTK_EDITABLE(panels.sync_passphrase), "");
    jsti_window_emit(JSTI_EVENT_CLOUD_SYNC, passphrase, action | sync_flags());
    memset(passphrase, 0, strlen(passphrase));
    g_free(passphrase);
}

static void on_sync_apply(GtkButton *button, gpointer data) { (void)button; (void)data; emit_sync(1); }
static void on_sync_sign_in(GtkButton *button, gpointer data) { (void)button; (void)data; emit_sync(2); }
static void on_sync_sign_out(GtkButton *button, gpointer data) { (void)button; (void)data; emit_sync(3); }
static void on_sync_now(GtkButton *button, gpointer data) { (void)button; (void)data; emit_sync(4); }

static void on_sync_keys(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    gtk_widget_set_visible(GTK_WIDGET(panels.sync_passphrase), adw_switch_row_get_active(panels.sync_keys));
}

static void on_autostart(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    jsti_window_emit(JSTI_EVENT_AUTOSTART, "", adw_switch_row_get_active(panels.autostart_row) ? 1 : 0);
}

/* --------------------------------------------------------------- layout */

static GtkWidget *button_row(GtkWidget *first, ...) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_halign(box, GTK_ALIGN_END);
    gtk_widget_set_margin_top(box, 6);
    va_list others;
    va_start(others, first);
    for (GtkWidget *widget = first; widget != NULL; widget = va_arg(others, GtkWidget *)) {
        gtk_box_append(GTK_BOX(box), widget);
    }
    va_end(others);
    return box;
}

static void build_read_aloud(AdwPreferencesPage *page) {
    GtkWidget *group = jsti_window_group("Read aloud");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(group),
        "Read aloud in History speaks the displayed transcript with Deepgram text-to-speech, using your "
        "Deepgram API key. The text is sent to Deepgram.");
    panels.voices = gtk_string_list_new(NULL);
    panels.voice_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(panels.voice_row), "Voice");
    adw_combo_row_set_model(panels.voice_row, G_LIST_MODEL(panels.voices));
    adw_combo_row_set_enable_search(panels.voice_row, TRUE);
    g_signal_connect(panels.voice_row, "notify::selected", G_CALLBACK(on_voice), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(panels.voice_row));
    adw_preferences_page_add(page, ADW_PREFERENCES_GROUP(group));
}

static void build_azure(AdwPreferencesPage *page) {
    GtkWidget *group = jsti_window_group("Azure Speech resource");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(group),
        "Azure live transcription connects to your resource's endpoint (Keys and Endpoint page, for example "
        "https://name.cognitiveservices.azure.com). Recorded audio uses it when set, and the region in your "
        "key:region credential otherwise. Leave it empty and apply to clear it.");
    panels.azure_row = ADW_ENTRY_ROW(adw_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(panels.azure_row), "Resource endpoint");
    adw_entry_row_set_show_apply_button(panels.azure_row, TRUE);
    g_signal_connect(panels.azure_row, "apply", G_CALLBACK(on_azure_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(panels.azure_row));
    adw_preferences_page_add(page, ADW_PREFERENCES_GROUP(group));
}

static void build_sync(AdwPreferencesPage *page) {
    GtkWidget *group = jsti_window_group("iCloud sync");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(group),
        "Sign in with your Apple ID in your browser to share History with your Mac. Nothing syncs until you "
        "choose it here. Importing your Mac's API keys is optional and needs the passphrase you set on the Mac.");
    panels.sync_status = GTK_LABEL(gtk_label_new("Checking iCloud sync…"));
    gtk_label_set_wrap(panels.sync_status, TRUE);
    gtk_label_set_xalign(panels.sync_status, 0);
    gtk_label_set_selectable(panels.sync_status, TRUE);
    gtk_widget_set_margin_bottom(GTK_WIDGET(panels.sync_status), 6);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(panels.sync_status));
    panels.sync_history = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(panels.sync_history), "Sync History with iCloud");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(panels.sync_history));
    panels.sync_keys = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(panels.sync_keys), "Import API keys from my Mac");
    adw_action_row_set_subtitle(
        ADW_ACTION_ROW(panels.sync_keys), "Keys stay encrypted in iCloud and are saved in this computer's keyring.");
    g_signal_connect(panels.sync_keys, "notify::active", G_CALLBACK(on_sync_keys), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(panels.sync_keys));
    panels.sync_passphrase = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(panels.sync_passphrase), "API-key sync passphrase from your Mac");
    gtk_widget_set_visible(GTK_WIDGET(panels.sync_passphrase), FALSE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(panels.sync_passphrase));
    panels.sync_sign_in = GTK_BUTTON(gtk_button_new_with_label("Sign in…"));
    panels.sync_sign_out = GTK_BUTTON(gtk_button_new_with_label("Sign out"));
    panels.sync_now = GTK_BUTTON(gtk_button_new_with_label("Sync now"));
    panels.sync_apply = GTK_BUTTON(gtk_button_new_with_label("Apply"));
    gtk_widget_add_css_class(GTK_WIDGET(panels.sync_apply), "suggested-action");
    g_signal_connect(panels.sync_sign_in, "clicked", G_CALLBACK(on_sync_sign_in), NULL);
    g_signal_connect(panels.sync_sign_out, "clicked", G_CALLBACK(on_sync_sign_out), NULL);
    g_signal_connect(panels.sync_now, "clicked", G_CALLBACK(on_sync_now), NULL);
    g_signal_connect(panels.sync_apply, "clicked", G_CALLBACK(on_sync_apply), NULL);
    adw_preferences_group_add(
        ADW_PREFERENCES_GROUP(group),
        button_row(GTK_WIDGET(panels.sync_sign_in), GTK_WIDGET(panels.sync_sign_out), GTK_WIDGET(panels.sync_now),
                   GTK_WIDGET(panels.sync_apply), NULL));
    adw_preferences_page_add(page, ADW_PREFERENCES_GROUP(group));
}

static void build_startup(AdwPreferencesPage *page) {
    GtkWidget *group = jsti_window_group("Startup");
    panels.autostart_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(panels.autostart_row), "Start when I log in");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(panels.autostart_row), "Checking the desktop…");
    gtk_widget_set_sensitive(GTK_WIDGET(panels.autostart_row), FALSE);
    g_signal_connect(panels.autostart_row, "notify::active", G_CALLBACK(on_autostart), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(panels.autostart_row));
    panels.tray_row = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(panels.tray_row), "System tray");
    adw_action_row_set_subtitle(panels.tray_row, "Checking the desktop…");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(panels.tray_row));
    adw_preferences_page_add(page, ADW_PREFERENCES_GROUP(group));
}

void jsti_window_panels_tray(gboolean available) {
    if (panels.tray_row == NULL) return;
    adw_action_row_set_subtitle(
        panels.tray_row,
        available ? "Shown in the system tray. Closing the window keeps the app running; choose Quit in the tray menu."
                  : "This desktop shows no tray icons (on GNOME, the AppIndicator extension adds them). Closing the "
                    "window quits; dictate with the shortcut or keep the window open.");
}

static void refresh_sync(void) {
    gboolean usable = panels.sync_available && panels.idle;
    gtk_widget_set_sensitive(GTK_WIDGET(panels.sync_sign_in), usable && !panels.sync_signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(panels.sync_sign_out), usable && panels.sync_signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(panels.sync_now), usable && panels.sync_signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(panels.sync_apply), usable && panels.sync_signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(panels.sync_history), usable && panels.sync_signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(panels.sync_keys), usable && panels.sync_signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(panels.sync_passphrase), usable && panels.sync_signed_in);
}

void jsti_window_panels_build(AdwPreferencesPage *page) {
    build_read_aloud(page);
    build_azure(page);
    build_sync(page);
    jsti_window_profiles_build(page);
    jsti_window_local_models_build(page);
    build_startup(page);
    refresh_sync();
}

void jsti_window_panels_refresh(gboolean idle) {
    if (panels.voice_row == NULL) return;
    panels.idle = idle;
    gtk_widget_set_sensitive(GTK_WIDGET(panels.azure_row), idle);
    refresh_sync();
    jsti_window_profiles_refresh(idle);
    jsti_window_local_models_refresh(idle);
}

/* ------------------------------------------------ thread-safe setters */

typedef struct Voices {
    GPtrArray *names;
    gint32 selected;
} Voices;

static void voices_free(gpointer pointer) {
    Voices *voices = pointer;
    g_ptr_array_unref(voices->names);
    g_free(voices);
}

static void voices_apply(gpointer pointer) {
    Voices *voices = pointer;
    jsti_window_set_suppressed(TRUE);
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(panels.voices));
    g_ptr_array_add(voices->names, NULL);
    gtk_string_list_splice(panels.voices, 0, existing, (const char *const *)voices->names->pdata);
    g_ptr_array_set_size(voices->names, voices->names->len - 1);
    if (voices->selected >= 0 && (guint)voices->selected < voices->names->len) {
        adw_combo_row_set_selected(panels.voice_row, (guint)voices->selected);
    }
    jsti_window_set_suppressed(FALSE);
}

int32_t jsti_window_set_voices(const char *const *names, size_t count, int32_t selected) {
    Voices *voices = g_new0(Voices, 1);
    voices->names = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) g_ptr_array_add(voices->names, g_strdup(names[index]));
    voices->selected = selected;
    return jsti_window_post(voices_apply, voices, voices_free);
}

static void azure_apply(gpointer pointer) {
    jsti_window_set_suppressed(TRUE);
    gtk_editable_set_text(GTK_EDITABLE(panels.azure_row), pointer != NULL ? pointer : "");
    jsti_window_set_suppressed(FALSE);
}

int32_t jsti_window_set_azure_resource(const char *endpoint) {
    return jsti_window_post(azure_apply, g_strdup(endpoint != NULL ? endpoint : ""), g_free);
}

typedef struct SyncView {
    gchar *status;
    gboolean available;
    gboolean signed_in;
    gboolean history;
    gboolean keys;
} SyncView;

static void sync_view_free(gpointer pointer) {
    SyncView *view = pointer;
    g_free(view->status);
    g_free(view);
}

static void sync_view_apply(gpointer pointer) {
    SyncView *view = pointer;
    jsti_window_set_suppressed(TRUE);
    gtk_label_set_text(panels.sync_status, view->status != NULL ? view->status : "");
    panels.sync_available = view->available;
    panels.sync_signed_in = view->signed_in;
    adw_switch_row_set_active(panels.sync_history, view->history);
    adw_switch_row_set_active(panels.sync_keys, view->keys);
    gtk_widget_set_visible(GTK_WIDGET(panels.sync_passphrase), view->keys);
    jsti_window_set_suppressed(FALSE);
    refresh_sync();
}

int32_t jsti_window_set_cloud_sync(
    const char *status, int32_t available, int32_t signed_in, int32_t history_enabled, int32_t key_import_enabled) {
    SyncView *view = g_new0(SyncView, 1);
    view->status = g_strdup(status);
    view->available = available != 0;
    view->signed_in = signed_in != 0;
    view->history = history_enabled != 0;
    view->keys = key_import_enabled != 0;
    return jsti_window_post(sync_view_apply, view, sync_view_free);
}

typedef struct Autostart {
    gint32 state;
    gchar *note;
} Autostart;

static void autostart_free(gpointer pointer) {
    Autostart *autostart = pointer;
    g_free(autostart->note);
    g_free(autostart);
}

static void autostart_apply(gpointer pointer) {
    Autostart *autostart = pointer;
    jsti_window_set_suppressed(TRUE);
    panels.autostart_available = autostart->state >= 0;
    adw_switch_row_set_active(panels.autostart_row, autostart->state == 1);
    gtk_widget_set_sensitive(GTK_WIDGET(panels.autostart_row), panels.autostart_available);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(panels.autostart_row), autostart->note != NULL ? autostart->note : "");
    jsti_window_set_suppressed(FALSE);
}

int32_t jsti_window_set_autostart(int32_t state, const char *note) {
    Autostart *autostart = g_new0(Autostart, 1);
    autostart->state = state;
    autostart->note = g_strdup(note);
    return jsti_window_post(autostart_apply, autostart, autostart_free);
}

/* ---------------------------------------------------------- self-test */

static int32_t fail(char *error, size_t capacity, const char *message) {
    jsti_set_error(error, capacity, "Window self-test: %s", message);
    return -1;
}

int32_t jsti_window_panels_self_test(char *error, size_t capacity) {
    const char *names[] = { "Voice A", "Voice B" };
    Voices *voices = g_new0(Voices, 1);
    voices->names = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < G_N_ELEMENTS(names); index++) g_ptr_array_add(voices->names, g_strdup(names[index]));
    voices->selected = 1;
    voices_apply(voices);
    voices_free(voices);
    if (adw_combo_row_get_selected(panels.voice_row) != 1) return fail(error, capacity, "the voice was not selected");

    SyncView signed_out = { .status = (gchar *)"Not signed in.", .available = TRUE };
    sync_view_apply(&signed_out);
    if (!gtk_widget_get_sensitive(GTK_WIDGET(panels.sync_sign_in)) ||
        gtk_widget_get_sensitive(GTK_WIDGET(panels.sync_apply))) {
        return fail(error, capacity, "signed-out iCloud controls were wrong");
    }
    SyncView importing = { .status = (gchar *)"Signed in.", .available = TRUE, .signed_in = TRUE, .keys = TRUE };
    sync_view_apply(&importing);
    if (!gtk_widget_get_visible(GTK_WIDGET(panels.sync_passphrase)) ||
        gtk_widget_get_sensitive(GTK_WIDGET(panels.sync_sign_in))) {
        return fail(error, capacity, "signed-in iCloud controls were wrong");
    }
    SyncView unavailable = { .status = (gchar *)"Unavailable.", .available = FALSE };
    sync_view_apply(&unavailable);
    if (gtk_widget_get_sensitive(GTK_WIDGET(panels.sync_sign_in))) {
        return fail(error, capacity, "iCloud sign-in stayed available without a token");
    }
    Autostart off = { .state = -1, .note = (gchar *)"Unavailable here." };
    autostart_apply(&off);
    if (gtk_widget_get_sensitive(GTK_WIDGET(panels.autostart_row))) {
        return fail(error, capacity, "Start at login stayed available without the Background portal");
    }
    return jsti_window_profiles_self_test(error, capacity);
}
