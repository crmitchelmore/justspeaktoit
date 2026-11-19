/* Cloud sharing consent (CloudSharing.h): the first-use question and the window that lists, and
 * withdraws, the AI providers the user allowed. The host owns every answer; these windows only
 * report it. Setters run on the GTK main thread through the window's ordered post queue. */
#include "LinuxWindowInternal.h"

typedef struct ProviderRow {
    gchar *identifier, *name, *detail, *policy_url, *withdraw_label;
} ProviderRow;

static void provider_row_free(gpointer pointer) {
    ProviderRow *row = pointer;
    g_free(row->identifier); g_free(row->name); g_free(row->detail);
    g_free(row->policy_url); g_free(row->withdraw_label);
    g_free(row);
}

static gboolean text_valid(const char *text) { return text == NULL || g_utf8_validate(text, -1, NULL); }

/* NULL when a row is malformed: the host would otherwise show a blank provider. */
static GPtrArray *rows_copy(const JSTICloudSharingRow *rows, size_t count) {
    if (count > 0 && rows == NULL) return NULL;
    GPtrArray *copy = g_ptr_array_new_with_free_func(provider_row_free);
    for (size_t index = 0; index < count; ++index) {
        const JSTICloudSharingRow *row = &rows[index];
        if (row->identifier == NULL || row->identifier[0] == '\0' || row->name == NULL || row->name[0] == '\0' ||
            !text_valid(row->identifier) || !text_valid(row->name) || !text_valid(row->detail) ||
            !text_valid(row->policy_url) || !text_valid(row->withdraw_label)) {
            g_ptr_array_unref(copy);
            return NULL;
        }
        ProviderRow *item = g_new0(ProviderRow, 1);
        item->identifier = g_strdup(row->identifier);
        item->name = g_strdup(row->name);
        item->detail = g_strdup(row->detail != NULL ? row->detail : "");
        item->policy_url = g_strdup(row->policy_url != NULL ? row->policy_url : "");
        item->withdraw_label = g_strdup(row->withdraw_label != NULL && row->withdraw_label[0] != '\0'
                                        ? row->withdraw_label : row->name);
        g_ptr_array_add(copy, item);
    }
    return copy;
}

static gchar *widget_id(const char *prefix, const char *identifier) {
    return g_strdup_printf("%s-%s", prefix, identifier);
}

static void policy_launched(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(source), result, &error)) {
        g_warning("Could not open the privacy policy: %s", error->message);
        g_error_free(error);
    }
}

static void policy_clicked(GtkButton *button, gpointer data) {
    GtkUriLauncher *launcher = gtk_uri_launcher_new(data);
    GtkRoot *root = gtk_widget_get_root(GTK_WIDGET(button));
    gtk_uri_launcher_launch(launcher, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL, NULL, policy_launched, NULL);
    g_object_unref(launcher);
}

static GtkWidget *wrapped_label(const char *text, const char *css) {
    GtkWidget *label = gtk_label_new(text);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    if (css != NULL) gtk_widget_add_css_class(label, css);
    return label;
}

/* The provider's name and what it receives, with a privacy policy link when it has one. */
static GtkWidget *provider_text(const ProviderRow *row, gboolean with_link) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_hexpand(box, TRUE);
    GtkWidget *name = wrapped_label(row->name, "heading");
    gtk_box_append(GTK_BOX(box), name);
    gtk_box_append(GTK_BOX(box), wrapped_label(row->detail, "dim-label"));
    if (with_link && g_str_has_prefix(row->policy_url, "https://")) {
        gchar *label = g_strdup_printf("%s privacy policy", row->name);
        GtkWidget *link = gtk_button_new_with_label("Privacy policy");
        gtk_widget_set_halign(link, GTK_ALIGN_START);
        gtk_widget_set_tooltip_text(link, row->policy_url);
        jsti_accessible_set_name(link, label);
        gchar *id = widget_id("cloudSharingPrivacyPolicyLink", row->identifier);
        gtk_widget_set_name(link, id);
        g_free(id); g_free(label);
        g_signal_connect_data(link, "clicked", G_CALLBACK(policy_clicked), g_strdup(row->policy_url),
                              (GClosureNotify)g_free, 0);
        gtk_box_append(GTK_BOX(box), link);
    }
    return box;
}

static GtkWidget *scrolled_column(GtkWidget **list) {
    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scrolled, TRUE);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scrolled), TRUE);
    *list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), *list);
    return scrolled;
}

/* --- The first-use question --- */

typedef struct Consent {
    gchar *token, *title, *intro, *allow_title, *not_now_title;
    GPtrArray *rows;
    gboolean answered, claimed;
} Consent;

static void consent_free(gpointer pointer) {
    Consent *consent = pointer;
    g_free(consent->token); g_free(consent->title); g_free(consent->intro);
    g_free(consent->allow_title); g_free(consent->not_now_title);
    g_clear_pointer(&consent->rows, g_ptr_array_unref);
    g_free(consent);
}

/* The post queue's destroy hook: frees a question that never reached a window. */
static void consent_release(gpointer pointer) {
    if (!((Consent *)pointer)->claimed) consent_free(pointer);
}

/* Reports the first answer only; closing the window answers "not now". */
static void consent_answer(Consent *consent, gint32 allow) {
    if (consent->answered) return;
    consent->answered = TRUE;
    jsti_window_emit(JSTI_EVENT_CLOUD_CONSENT_RESPONSE, consent->token, allow);
}

static gboolean consent_close_request(GtkWindow *window, gpointer data) {
    (void)window;
    consent_answer(data, 0);
    return FALSE;
}

static void consent_button(GtkButton *button, gpointer data) {
    Consent *consent = data;
    consent_answer(consent, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "allow")));
    gtk_window_close(GTK_WINDOW(gtk_widget_get_root(GTK_WIDGET(button))));
}

static GtkWidget *consent_action(Consent *consent, const char *label, const char *name, gint32 allow) {
    GtkWidget *button = gtk_button_new_with_label(label);
    gtk_widget_set_size_request(button, -1, 44);
    gtk_widget_set_name(button, name);
    g_object_set_data(G_OBJECT(button), "allow", GINT_TO_POINTER(allow));
    g_signal_connect(button, "clicked", G_CALLBACK(consent_button), consent);
    return button;
}

static void consent_apply(gpointer pointer) {
    Consent *consent = pointer;
    if (ui.window == NULL || ui.closing) {
        consent_answer(consent, 0);
        return;
    }
    GtkWidget *column;
    GtkWindow *window = jsti_tool_window_new(ui.window, consent->title, 520, &column);
    gtk_window_set_modal(window, TRUE);
    gtk_widget_set_name(GTK_WIDGET(window), "cloudSharingConsentSheet");
    /* The window owns the question; it is freed with the window. */
    consent->claimed = TRUE;
    g_object_set_data_full(G_OBJECT(window), "consent", consent, consent_free);
    g_signal_connect(window, "close-request", G_CALLBACK(consent_close_request), consent);
    GtkWidget *title = wrapped_label(consent->title, "title-2");
    gtk_widget_set_name(title, "cloudSharingConsentTitle");
    gtk_box_append(GTK_BOX(column), title);
    gtk_box_append(GTK_BOX(column), wrapped_label(consent->intro, NULL));
    GtkWidget *list;
    gtk_box_append(GTK_BOX(column), scrolled_column(&list));
    for (guint index = 0; index < consent->rows->len; ++index) {
        ProviderRow *row = g_ptr_array_index(consent->rows, index);
        GtkWidget *provider = provider_text(row, TRUE);
        gchar *id = widget_id("cloudSharingProvider", row->identifier);
        gtk_widget_set_name(provider, id);
        g_free(id);
        gtk_box_append(GTK_BOX(list), provider);
    }
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    gtk_box_append(GTK_BOX(actions),
                   consent_action(consent, consent->not_now_title, "cloudSharingConsentNotNowButton", 0));
    GtkWidget *allow = consent_action(consent, consent->allow_title, "cloudSharingConsentAllowButton", 1);
    gtk_widget_add_css_class(allow, "suggested-action");
    gtk_box_append(GTK_BOX(actions), allow);
    gtk_box_append(GTK_BOX(column), actions);
    gtk_window_present(window);
}

int32_t jsti_window_request_cloud_sharing(
    const char *token, const char *title, const char *intro, const JSTICloudSharingRow *rows, size_t count,
    const char *allow_title, const char *not_now_title) {
    if (token == NULL || !g_uuid_string_is_valid(token) || count == 0 || title == NULL || intro == NULL ||
        allow_title == NULL || not_now_title == NULL || !g_utf8_validate(title, -1, NULL) ||
        !g_utf8_validate(intro, -1, NULL) || !g_utf8_validate(allow_title, -1, NULL) ||
        !g_utf8_validate(not_now_title, -1, NULL)) return -1;
    GPtrArray *copy = rows_copy(rows, count);
    if (copy == NULL) return -1;
    Consent *consent = g_new0(Consent, 1);
    consent->token = g_strdup(token);
    consent->title = g_strdup(title);
    consent->intro = g_strdup(intro);
    consent->allow_title = g_strdup(allow_title);
    consent->not_now_title = g_strdup(not_now_title);
    consent->rows = copy;
    return post(consent_apply, consent, consent_release) == 0 ? 0 : -1;
}

/* --- The withdrawal window --- */

typedef struct Snapshot {
    gchar *title, *footer, *empty_text;
    GPtrArray *rows;
    gboolean claimed;
} Snapshot;

static void snapshot_free(gpointer pointer) {
    Snapshot *snapshot = pointer;
    if (snapshot == NULL) return;
    g_free(snapshot->title); g_free(snapshot->footer); g_free(snapshot->empty_text);
    g_clear_pointer(&snapshot->rows, g_ptr_array_unref);
    g_free(snapshot);
}

/* The post queue's destroy hook: frees a snapshot that was never applied. */
static void snapshot_release(gpointer pointer) {
    if (!((Snapshot *)pointer)->claimed) snapshot_free(pointer);
}

/* Main thread only. `window` is NULL while the withdrawal window is closed. */
static struct {
    Snapshot *latest;
    GtkWindow *window;
    GtkWidget *list;
    GtkLabel *footer;
} withdrawal;

static void withdrawal_finalized(gpointer data, GObject *object) {
    (void)data; (void)object;
    withdrawal.window = NULL;
    withdrawal.list = NULL;
    withdrawal.footer = NULL;
}

static void withdraw_clicked(GtkButton *button, gpointer data) {
    gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
    jsti_window_emit(JSTI_EVENT_CLOUD_SHARING_WITHDRAW, data, 0);
}

static void withdrawal_rebuild(void) {
    if (withdrawal.window == NULL) return;
    for (GtkWidget *child = gtk_widget_get_first_child(withdrawal.list); child != NULL;) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(withdrawal.list), child);
        child = next;
    }
    Snapshot *snapshot = withdrawal.latest;
    const char *footer = snapshot != NULL ? snapshot->footer : "";
    gtk_label_set_text(withdrawal.footer, footer);
    gtk_widget_set_visible(GTK_WIDGET(withdrawal.footer), footer[0] != '\0');
    if (snapshot == NULL || snapshot->rows->len == 0) {
        GtkWidget *empty = wrapped_label(snapshot != NULL ? snapshot->empty_text : "", NULL);
        gtk_widget_set_name(empty, "cloudSharingConsentEmpty");
        gtk_box_append(GTK_BOX(withdrawal.list), empty);
        return;
    }
    GtkWidget *first = NULL;
    for (guint index = 0; index < snapshot->rows->len; ++index) {
        ProviderRow *row = g_ptr_array_index(snapshot->rows, index);
        GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
        gchar *id = widget_id("cloudSharingProvider", row->identifier);
        gtk_widget_set_name(line, id);
        g_free(id);
        gtk_box_append(GTK_BOX(line), provider_text(row, TRUE));
        GtkWidget *withdraw = gtk_button_new_with_label("Withdraw");
        gtk_widget_set_valign(withdraw, GTK_ALIGN_CENTER);
        gtk_widget_set_size_request(withdraw, -1, 44);
        jsti_accessible_set_name(withdraw, row->withdraw_label);
        id = widget_id("cloudSharingWithdrawButton", row->identifier);
        gtk_widget_set_name(withdraw, id);
        g_free(id);
        g_signal_connect_data(withdraw, "clicked", G_CALLBACK(withdraw_clicked), g_strdup(row->identifier),
                              (GClosureNotify)g_free, 0);
        gtk_box_append(GTK_BOX(line), withdraw);
        gtk_box_append(GTK_BOX(withdrawal.list), line);
        if (first == NULL) first = withdraw;
    }
    if (gtk_window_get_focus(withdrawal.window) == NULL && first != NULL) gtk_widget_grab_focus(first);
}

void jsti_cloud_sharing_open(GtkWindow *owner) {
    if (withdrawal.window != NULL) { gtk_window_present(withdrawal.window); return; }
    GtkWidget *column;
    const char *title = withdrawal.latest != NULL ? withdrawal.latest->title : "AI providers you allowed";
    withdrawal.window = jsti_tool_window_new(owner, title, 520, &column);
    gtk_widget_set_name(GTK_WIDGET(withdrawal.window), "cloudSharingWithdrawalWindow");
    g_object_weak_ref(G_OBJECT(withdrawal.window), withdrawal_finalized, NULL);
    withdrawal.footer = GTK_LABEL(wrapped_label("", "dim-label"));
    gtk_box_append(GTK_BOX(column), scrolled_column(&withdrawal.list));
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(withdrawal.footer));
    withdrawal_rebuild();
    gtk_window_present(withdrawal.window);
}

void jsti_cloud_sharing_close(void) {
    if (withdrawal.window != NULL) gtk_window_destroy(withdrawal.window);
}

static void snapshot_apply(gpointer pointer) {
    snapshot_free(withdrawal.latest);
    withdrawal.latest = pointer;
    withdrawal.latest->claimed = TRUE;
    if (withdrawal.window == NULL) return;
    gtk_window_set_title(withdrawal.window, withdrawal.latest->title);
    withdrawal_rebuild();
    jsti_accessible_announce(GTK_WIDGET(withdrawal.window), withdrawal.latest->rows->len == 0
                             ? withdrawal.latest->empty_text : "AI provider list updated.",
                             GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
}

int32_t jsti_window_set_cloud_sharing(
    const char *title, const char *footer, const char *empty_text, const JSTICloudSharingRow *rows, size_t count) {
    if (title == NULL || footer == NULL || empty_text == NULL || !g_utf8_validate(title, -1, NULL) ||
        !g_utf8_validate(footer, -1, NULL) || !g_utf8_validate(empty_text, -1, NULL)) return -1;
    GPtrArray *copy = rows_copy(rows, count);
    if (copy == NULL) return -1;
    Snapshot *snapshot = g_new0(Snapshot, 1);
    snapshot->title = g_strdup(title);
    snapshot->footer = g_strdup(footer);
    snapshot->empty_text = g_strdup(empty_text);
    snapshot->rows = copy;
    return post(snapshot_apply, snapshot, snapshot_release) == 0 ? 0 : -1;
}
