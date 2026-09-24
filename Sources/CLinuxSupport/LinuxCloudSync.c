#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <string.h>

/*
 * The window's iCloud sync group, and opening Apple's sign-in page. Swift runs
 * the flow itself (DesktopHostCloudSync); the group only reports the user's
 * choices and shows the state Swift hands it through jsti_window_set_cloud_sync,
 * applied in call order with the window's other setters. Until the first state
 * arrives, and while sync is unavailable, nothing in it can be pressed.
 */

typedef struct CloudView {
    gchar *status;
    gboolean available;
    gboolean signed_in;
    gboolean history;
    gboolean keys;
} CloudView;

typedef struct CloudGroup {
    /* The status line, with Sign in and Sign out beside it. */
    AdwActionRow *status;
    AdwSwitchRow *history;
    AdwSwitchRow *keys;
    AdwPasswordEntryRow *passphrase;
    GtkButton *sign_in;
    GtkButton *sign_out;
    GtkButton *sync_now;
    GtkButton *apply;
    /* The last state shown; NULL status until one arrives. */
    CloudView shown;
} CloudGroup;

static CloudGroup cloud;
static const char *const initial_status = "iCloud sync has not started.";
/* The window's event callback; the self-test records events instead. */
static void (*cloud_emit)(int32_t event, const char *text, int32_t index) = jsti_window_emit;

static void refresh_cloud(void) {
    gboolean usable = cloud.shown.status != NULL && cloud.shown.available;
    gboolean signed_in = usable && cloud.shown.signed_in;
    gtk_widget_set_sensitive(GTK_WIDGET(cloud.history), signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(cloud.keys), signed_in);
    /* The passphrase is asked for only to turn key import on. */
    gtk_widget_set_sensitive(
        GTK_WIDGET(cloud.passphrase), signed_in && adw_switch_row_get_active(cloud.keys) && !cloud.shown.keys);
    gtk_widget_set_sensitive(GTK_WIDGET(cloud.sign_in), usable && !cloud.shown.signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(cloud.sign_out), signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(cloud.sync_now), signed_in);
    gtk_widget_set_sensitive(GTK_WIDGET(cloud.apply), signed_in);
}

/* Shows a state. A switch follows it only when sync's own value changed, so a
 * status refresh never undoes a choice the user has not applied yet. */
static void show_cloud(const CloudView *view) {
    gboolean first = cloud.shown.status == NULL;
    gchar *status = g_strdup(view->status != NULL ? view->status : initial_status);
    adw_action_row_set_subtitle(cloud.status, status);
    if (first || view->history != cloud.shown.history) adw_switch_row_set_active(cloud.history, view->history);
    if (first || view->keys != cloud.shown.keys) adw_switch_row_set_active(cloud.keys, view->keys);
    g_free(cloud.shown.status);
    cloud.shown = *view;
    cloud.shown.status = status;
    refresh_cloud();
}

/* Back to "not started": nothing can be pressed. */
static void reset_cloud(void) {
    g_clear_pointer(&cloud.shown.status, g_free);
    cloud.shown = (CloudView){ 0 };
    adw_action_row_set_subtitle(cloud.status, initial_status);
    adw_switch_row_set_active(cloud.history, FALSE);
    adw_switch_row_set_active(cloud.keys, FALSE);
    gtk_editable_set_text(GTK_EDITABLE(cloud.passphrase), "");
    refresh_cloud();
}

static void on_cloud_keys(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    refresh_cloud();
}

static void on_cloud_apply(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    gint32 choices =
        (adw_switch_row_get_active(cloud.history) ? 1 : 0) | (adw_switch_row_get_active(cloud.keys) ? 2 : 0);
    /* The entry's secure buffer is wiped when its text is replaced. */
    cloud_emit(JSTI_EVENT_CLOUD_SYNC_APPLY, gtk_editable_get_text(GTK_EDITABLE(cloud.passphrase)), choices);
    gtk_editable_set_text(GTK_EDITABLE(cloud.passphrase), "");
}

static void on_cloud_button(GtkButton *button, gpointer data) {
    (void)button;
    cloud_emit(GPOINTER_TO_INT(data), "", 0);
}

static GtkButton *cloud_button(const char *label, gint32 event) {
    GtkButton *button = GTK_BUTTON(gtk_button_new_with_mnemonic(label));
    g_signal_connect(button, "clicked", G_CALLBACK(on_cloud_button), GINT_TO_POINTER(event));
    return button;
}

void jsti_cloud_sync_build(gpointer page) {
    GtkWidget *group = adw_preferences_group_new();
    adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(group), "iCloud sync");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(group),
        "Sync History with your Mac through iCloud. Only transcripts sync; audio stays on the device that "
        "recorded it.");
    cloud.status = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cloud.status), "Apple ID");
    adw_action_row_set_subtitle(cloud.status, initial_status);
    adw_action_row_set_subtitle_selectable(cloud.status, TRUE);
    cloud.sign_in = cloud_button("_Sign in…", JSTI_EVENT_CLOUD_SYNC_SIGN_IN);
    cloud.sign_out = cloud_button("Sign _out", JSTI_EVENT_CLOUD_SYNC_SIGN_OUT);
    gtk_widget_set_valign(GTK_WIDGET(cloud.sign_in), GTK_ALIGN_CENTER);
    gtk_widget_set_valign(GTK_WIDGET(cloud.sign_out), GTK_ALIGN_CENTER);
    adw_action_row_add_suffix(cloud.status, GTK_WIDGET(cloud.sign_in));
    adw_action_row_add_suffix(cloud.status, GTK_WIDGET(cloud.sign_out));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(cloud.status));

    cloud.history = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cloud.history), "Sync History with my Mac");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(cloud.history));
    cloud.keys = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cloud.keys), "Import API keys from my Mac");
    adw_action_row_set_subtitle(
        ADW_ACTION_ROW(cloud.keys),
        "Saved in the desktop keyring, replacing keys saved here for the same providers. Keys are never uploaded.");
    g_signal_connect(cloud.keys, "notify::active", G_CALLBACK(on_cloud_keys), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(cloud.keys));
    cloud.passphrase = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(
        ADW_PREFERENCES_ROW(cloud.passphrase), "API-key sync passphrase (the one set on your Mac; not saved)");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(cloud.passphrase));

    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(actions, 6);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    cloud.sync_now = cloud_button("Sync _now", JSTI_EVENT_CLOUD_SYNC_NOW);
    cloud.apply = GTK_BUTTON(gtk_button_new_with_mnemonic("_Apply"));
    g_signal_connect(cloud.apply, "clicked", G_CALLBACK(on_cloud_apply), NULL);
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(cloud.sync_now));
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(cloud.apply));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), actions);
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), ADW_PREFERENCES_GROUP(group));
    reset_cloud();
}

static void cloud_view_free(gpointer pointer) {
    CloudView *view = pointer;
    g_free(view->status);
    g_free(view);
}

static void cloud_view_apply(gpointer pointer) { show_cloud(pointer); }

int32_t jsti_window_set_cloud_sync(const JSTICloudSyncView *view) {
    if (view == NULL) return -1;
    CloudView *copy = g_new0(CloudView, 1);
    copy->status = g_strdup(view->status);
    copy->available = view->available != 0;
    copy->signed_in = view->signed_in != 0;
    copy->history = view->history_enabled != 0;
    copy->keys = view->key_import_enabled != 0;
    return jsti_window_post(cloud_view_apply, copy, cloud_view_free);
}

/* ------------------------------------------------------------ sign-in page */

static gboolean trusted_host(const char *host) {
    gchar *lower = g_ascii_strdown(host, -1);
    gboolean trusted = g_strcmp0(lower, "apple.com") == 0 || g_strcmp0(lower, "icloud.com") == 0 ||
        g_str_has_suffix(lower, ".apple.com") || g_str_has_suffix(lower, ".icloud.com");
    g_free(lower);
    return trusted;
}

/* Only an https page on apple.com or icloud.com, without credentials in it. */
static gboolean trusted_sign_in_page(const char *url) {
    GUri *uri = url != NULL ? g_uri_parse(url, G_URI_FLAGS_NONE, NULL) : NULL;
    if (uri == NULL) return FALSE;
    const char *scheme = g_uri_get_scheme(uri), *host = g_uri_get_host(uri);
    gboolean trusted = scheme != NULL && g_ascii_strcasecmp(scheme, "https") == 0 && g_uri_get_userinfo(uri) == NULL &&
        host != NULL && trusted_host(host);
    g_uri_unref(uri);
    return trusted;
}

int32_t jsti_open_sign_in_page(const char *url, char *error, size_t capacity) {
    if (!trusted_sign_in_page(url)) {
        jsti_set_error(error, capacity, "Only Apple's own sign-in page can be opened.");
        return -1;
    }
    /* Inside Flatpak GIO hands the page to the OpenURI portal. */
    GError *failure = NULL;
    if (!g_app_info_launch_default_for_uri(url, NULL, &failure)) {
        jsti_set_error(
            error, capacity, "The browser could not be opened for Apple ID sign-in: %s",
            failure != NULL ? failure->message : "no browser is set.");
        g_clear_error(&failure);
        return -1;
    }
    return 0;
}

/* --------------------------------------------------------------- self-test */

typedef struct Emitted {
    gint calls;
    gint32 event;
    gint32 index;
    gchar *text;
} Emitted;

static Emitted emitted;

static void record_emit(int32_t event, const char *text, int32_t index) {
    emitted.calls++;
    emitted.event = event;
    emitted.index = index;
    g_free(emitted.text);
    emitted.text = g_strdup(text);
}

static gboolean sensitive(gpointer widget) { return gtk_widget_get_sensitive(GTK_WIDGET(widget)); }

static const char *check_cloud_group(void) {
    if (jsti_window_set_cloud_sync(NULL) != -1) return "a missing iCloud sync state was accepted";
    if (sensitive(cloud.sign_in) || sensitive(cloud.apply)) return "iCloud sync could be used before it started";
    const char *reason = "iCloud sync is not available in this build: it was built without a CloudKit API token.";
    show_cloud(&(CloudView){ .status = (gchar *)reason });
    if (g_strcmp0(adw_action_row_get_subtitle(cloud.status), reason) != 0) {
        return "the unavailable reason was not shown";
    }
    if (sensitive(cloud.sign_in) || sensitive(cloud.history) || sensitive(cloud.sync_now) || sensitive(cloud.apply)) {
        return "iCloud sync actions stayed available without an API token";
    }
    show_cloud(&(CloudView){ .status = (gchar *)"Signed out.", .available = TRUE });
    if (!sensitive(cloud.sign_in) || sensitive(cloud.sign_out) || sensitive(cloud.apply)) {
        return "signing in was not the only action while signed out";
    }
    CloudView signed_in = { .status = (gchar *)"Signed in.", .available = TRUE, .signed_in = TRUE };
    show_cloud(&signed_in);
    if (sensitive(cloud.sign_in) || !sensitive(cloud.sign_out) || sensitive(cloud.passphrase)) {
        return "the signed-in actions did not follow the state";
    }
    adw_switch_row_set_active(cloud.history, TRUE);
    adw_switch_row_set_active(cloud.keys, TRUE);
    if (!sensitive(cloud.passphrase)) return "turning key import on did not ask for the passphrase";
    /* A status refresh keeps choices the user has not applied yet. */
    show_cloud(&signed_in);
    if (!adw_switch_row_get_active(cloud.history) || !adw_switch_row_get_active(cloud.keys)) {
        return "a status refresh undid unapplied choices";
    }
    gtk_editable_set_text(GTK_EDITABLE(cloud.passphrase), "synthetic passphrase");
    g_signal_emit_by_name(cloud.apply, "clicked");
    if (emitted.calls != 1 || emitted.event != JSTI_EVENT_CLOUD_SYNC_APPLY || emitted.index != 3 ||
        g_strcmp0(emitted.text, "synthetic passphrase") != 0) {
        return "Apply did not report the choices and passphrase exactly once";
    }
    if (g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(cloud.passphrase)), "") != 0) {
        return "the passphrase stayed in its entry after Apply";
    }
    show_cloud(&(CloudView){ .status = (gchar *)"Synced.", .available = TRUE, .signed_in = TRUE, .keys = TRUE });
    if (!adw_switch_row_get_active(cloud.keys) || sensitive(cloud.passphrase)) {
        return "key import turned on without the passphrase entry closing";
    }
    g_signal_emit_by_name(cloud.sync_now, "clicked");
    gboolean synced = emitted.calls == 2 && emitted.event == JSTI_EVENT_CLOUD_SYNC_NOW;
    g_signal_emit_by_name(cloud.sign_out, "clicked");
    if (!synced || emitted.calls != 3 || emitted.event != JSTI_EVENT_CLOUD_SYNC_SIGN_OUT) {
        return "Sync now or Sign out did not report their events";
    }
    char failure[128];
    if (jsti_open_sign_in_page("http://idmsa.apple.com/signin", failure, sizeof failure) != -1 ||
        jsti_open_sign_in_page("https://apple.com.example.net/signin", failure, sizeof failure) != -1 ||
        jsti_open_sign_in_page("https://user@idmsa.apple.com/signin", failure, sizeof failure) != -1) {
        return "a sign-in page that is not Apple's was accepted";
    }
    return NULL;
}

int32_t jsti_cloud_sync_self_test(char *error, size_t capacity) {
    if (cloud.status == NULL) {
        jsti_set_error(error, capacity, "Window self-test: the iCloud sync group was not built");
        return -1;
    }
    /* The group is exercised with recorded events, then put back as it was. */
    CloudView before = cloud.shown;
    before.status = g_strdup(cloud.shown.status);
    cloud_emit = record_emit;
    const char *failure = check_cloud_group();
    cloud_emit = jsti_window_emit;
    g_clear_pointer(&emitted.text, g_free);
    emitted = (Emitted){ 0 };
    reset_cloud();
    if (before.status != NULL) show_cloud(&before);
    g_free(before.status);
    if (failure != NULL) {
        jsti_set_error(error, capacity, "Window self-test: %s", failure);
        return -1;
    }
    return 0;
}
