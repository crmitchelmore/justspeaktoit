#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

typedef struct {
    AdwPreferencesGroup *group;
    AdwPasswordEntryRow *key;
    AdwActionRow *status;
    GtkWidget *save, *remove, *recheck;
    JSTIVoiceCredentialCallback callback;
    void *context;
    gchar *view_token, *epoch, *identifier, *pending_token, *pending_epoch, *outcome;
    gboolean ready, can_save, saved, idle, loading;
} Credentials;
static Credentials *active;

static gboolean same_uuid(const char *first, const char *second) {
    return first != NULL && second != NULL && strlen(first) == 36 && strlen(second) == 36 &&
        g_ascii_strcasecmp(first, second) == 0;
}
static void enable(Credentials *form) {
    gboolean editable = form->idle && form->ready && form->can_save && form->pending_token == NULL;
    gtk_widget_set_sensitive(GTK_WIDGET(form->key), editable);
    gtk_widget_set_sensitive(form->save, editable);
    gtk_widget_set_sensitive(form->remove, editable && form->saved);
    gtk_widget_set_sensitive(form->recheck, form->idle && form->callback != NULL && form->pending_token == NULL);
}
static void request_view(Credentials *form) {
    gtk_editable_set_text(GTK_EDITABLE(form->key), "");
    form->ready = FALSE;
    form->loading = TRUE;
    g_free(form->view_token); form->view_token = g_uuid_string_random();
    enable(form);
    if (form->callback != NULL)
        form->callback("open", "voice-output", "", form->view_token, "", "", form->context);
}
static void cancel(Credentials *form) {
    if (form->callback != NULL && form->pending_token != NULL)
        form->callback("cancel", "voice-output", "", form->pending_token, "", "", form->context);
    if (form->callback != NULL && form->loading && form->view_token != NULL)
        form->callback("cancel", "voice-output", "", form->view_token, "", "", form->context);
}
static void unmap(GtkWidget *widget, gpointer data) {
    (void)widget; Credentials *form = data;
    gtk_editable_set_text(GTK_EDITABLE(form->key), ""); cancel(form);
}
static void map(GtkWidget *widget, gpointer data) {
    (void)widget; Credentials *form = data;
    if (form->callback != NULL && form->pending_token == NULL) request_view(form);
}
static void destroy(gpointer data) {
    Credentials *form = data;
    if (active == form) active = NULL;
    cancel(form);
    g_free(form->view_token); g_free(form->epoch); g_free(form->identifier);
    g_free(form->pending_token); g_free(form->pending_epoch); g_free(form->outcome); g_free(form);
}
static gboolean emit(Credentials *form, gboolean remove) {
    if (!form->idle || !form->ready || !form->can_save || form->pending_token != NULL ||
        (remove && !form->saved) || form->callback == NULL) return FALSE;
    const gchar *value = remove ? "" : gtk_editable_get_text(GTK_EDITABLE(form->key));
    if (!remove && (value[0] == '\0' || strlen(value) > 8192)) {
        adw_action_row_set_subtitle(form->status,
            value[0] == '\0' ? "Enter a new key. Blank input never removes the saved key."
                : "The key exceeds 8,192 UTF-8 bytes. Enter the complete provider key within that limit.");
        return FALSE;
    }
    gchar *secret = g_strdup(value);
    form->pending_token = g_uuid_string_random(); form->pending_epoch = g_strdup(form->epoch);
    gtk_editable_set_text(GTK_EDITABLE(form->key), "");
    enable(form);
    adw_action_row_set_subtitle(form->status, remove ? "Removing the provider key..." : "Saving the provider key...");
    form->callback(remove ? "remove" : "replace", "voice-output", form->identifier,
        form->pending_token, form->pending_epoch, secret, form->context);
    volatile gchar *wipe = secret;
    for (gsize index = 0, length = strlen(secret); index < length; ++index) wipe[index] = 0;
    g_free(secret);
    return TRUE;
}
static void save(GtkButton *button, gpointer data) { (void)button; emit(data, FALSE); }
static void recheck(GtkButton *button, gpointer data) {
    (void)button; Credentials *form = data;
    if (form->pending_token == NULL) { g_clear_pointer(&form->outcome, g_free); request_view(form); }
}
typedef struct { gchar *view_token, *epoch; } Removal;
static void free_removal(gpointer data) {
    Removal *removal = data; g_free(removal->view_token); g_free(removal->epoch); g_free(removal);
}
static void confirm_removal(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)dialog; Removal *removal = data;
    if (g_strcmp0(response, "remove") == 0 && active != NULL &&
        same_uuid(active->view_token, removal->view_token) && same_uuid(active->epoch, removal->epoch))
        emit(active, TRUE);
}
static void remove_key(GtkButton *button, gpointer data) {
    (void)button; Credentials *form = data;
    if (!gtk_widget_get_sensitive(form->remove)) return;
    GtkRoot *root = gtk_widget_get_root(GTK_WIDGET(form->group));
    GtkWidget *dialog = adw_message_dialog_new(GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL,
        "Remove Voice provider key?",
        "Other features using this same key also lose access. Cancel keeps the existing key.");
    adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "remove", "Remove saved key", NULL);
    adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "remove", ADW_RESPONSE_DESTRUCTIVE);
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    Removal *removal = g_new0(Removal, 1);
    removal->view_token = g_strdup(form->view_token); removal->epoch = g_strdup(form->epoch);
    g_object_set_data_full(G_OBJECT(dialog), "voice-key-removal", removal, free_removal);
    g_signal_connect(dialog, "response", G_CALLBACK(confirm_removal), removal);
    gtk_window_present(GTK_WINDOW(dialog));
}
GtkWidget *jsti_voice_credentials_group_new(void) {
    Credentials *form = g_new0(Credentials, 1);
    form->idle = TRUE;
    form->group = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(form->group, "Voice provider key");
    adw_preferences_group_set_description(form->group,
        "No key is shown or prefilled. This form does not send Voice text or make a provider request.");
    form->key = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(form->key), "New API key (blank keeps saved key)");
    gtk_editable_set_enable_undo(GTK_EDITABLE(form->key), FALSE);
    adw_preferences_group_add(form->group, GTK_WIDGET(form->key));
    form->status = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(form->status), "Saved key state");
    adw_action_row_set_subtitle(form->status, "Waiting for the selected Voice provider.");
    adw_action_row_set_subtitle_lines(form->status, 0);
    adw_preferences_group_add(form->group, GTK_WIDGET(form->status));
    form->save = gtk_button_new_with_label("Save key");
    form->remove = gtk_button_new_with_label("Remove saved key");
    form->recheck = gtk_button_new_with_label("Recheck");
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *controls[] = {form->save, form->remove, form->recheck};
    for (gsize index = 0; index < G_N_ELEMENTS(controls); ++index) {
        gtk_widget_set_size_request(controls[index], -1, 44);
        gtk_box_append(GTK_BOX(buttons), controls[index]);
    }
    gtk_widget_set_margin_top(buttons, 8); gtk_widget_set_margin_bottom(buttons, 8);
    gtk_widget_set_halign(buttons, GTK_ALIGN_END);
    adw_preferences_group_add(form->group, buttons);
    g_signal_connect(form->save, "clicked", G_CALLBACK(save), form);
    g_signal_connect(form->remove, "clicked", G_CALLBACK(remove_key), form);
    g_signal_connect(form->recheck, "clicked", G_CALLBACK(recheck), form);
    g_signal_connect(form->group, "unmap", G_CALLBACK(unmap), form);
    g_signal_connect(form->group, "map", G_CALLBACK(map), form);
    g_object_set_data_full(G_OBJECT(form->group), "voice-credentials", form, destroy);
    active = form; enable(form);
    return GTK_WIDGET(form->group);
}
void jsti_voice_credentials_set_idle(gboolean idle) {
    if (active != NULL) {
        gboolean was_idle = active->idle;
        active->idle = idle;
        if (!idle) gtk_editable_set_text(GTK_EDITABLE(active->key), "");
        if (!was_idle && idle && active->pending_token == NULL) request_view(active);
        enable(active);
    }
}
void jsti_voice_credentials_selection_changed(void) {
    if (active != NULL) { cancel(active); request_view(active); }
}
void jsti_voice_credentials_selection_pending(void) {
    if (active != NULL) {
        cancel(active); gtk_editable_set_text(GTK_EDITABLE(active->key), "");
        active->ready = FALSE; enable(active);
    }
}
typedef struct { JSTIVoiceCredentialCallback callback; void *context; } Handler;
static void apply_handler(gpointer data) {
    Handler *handler = data;
    if (active != NULL) {
        active->callback = handler->callback; active->context = handler->context;
        request_view(active);
    }
}
int32_t jsti_window_set_voice_credential_handler(JSTIVoiceCredentialCallback callback, void *context) {
    if (callback == NULL || context == NULL) return -1;
    Handler *handler = g_new0(Handler, 1); handler->callback = callback; handler->context = context;
    return jsti_window_post(apply_handler, handler, g_free);
}
static void clear(gpointer data) {
    (void)data;
    if (active != NULL) {
        cancel(active);
        gtk_editable_set_text(GTK_EDITABLE(active->key), "");
        active->callback = NULL; active->context = NULL; active->ready = FALSE; enable(active);
    }
}
void jsti_window_clear_voice_credentials(void) { jsti_window_post(clear, NULL, NULL); }
void jsti_voice_credentials_close(void) { clear(NULL); }

typedef struct {
    gchar *token, *epoch, *identifier, *label, *privacy, *status;
    gint saved; gboolean can_save, finish;
} Delivery;
static void free_delivery(gpointer data) {
    Delivery *value = data;
    g_free(value->token); g_free(value->epoch); g_free(value->identifier);
    g_free(value->label); g_free(value->privacy); g_free(value->status); g_free(value);
}
static void apply_delivery(gpointer data) {
    Delivery *value = data;
    Credentials *form = active;
    if (form == NULL) return;
    if (value->finish) {
        if (!same_uuid(form->pending_token, value->token) || !same_uuid(form->pending_epoch, value->epoch)) return;
        g_clear_pointer(&form->pending_token, g_free); g_clear_pointer(&form->pending_epoch, g_free);
        g_free(form->outcome); form->outcome = g_strdup(value->status);
        adw_action_row_set_subtitle(form->status, form->outcome); request_view(form); return;
    }
    if (!same_uuid(form->view_token, value->token)) return;
    form->loading = FALSE;
    if (!same_uuid(form->epoch, value->epoch))
        gtk_editable_set_text(GTK_EDITABLE(form->key), "");
    g_free(form->epoch); form->epoch = g_strdup(value->epoch);
    g_free(form->identifier); form->identifier = g_strdup(value->identifier);
    form->ready = value->saved >= 0; form->saved = value->saved == 1; form->can_save = value->can_save;
    adw_preferences_group_set_title(form->group, value->label);
    adw_preferences_group_set_description(form->group, value->privacy);
    gchar *status = form->outcome != NULL ? g_strconcat(form->outcome, "\n", value->status, NULL) : g_strdup(value->status);
    adw_action_row_set_subtitle(form->status, status); g_free(status); enable(form);
}
static gboolean valid_text(const char *text, gsize maximum) {
    return text != NULL && strlen(text) <= maximum && g_utf8_validate(text, -1, NULL);
}
int32_t jsti_window_set_voice_credential(const char *token, const char *epoch, const char *identifier,
    const char *label, const char *privacy, const char *status, int32_t saved, int32_t can_save) {
    if (!valid_text(token, 36) || strlen(token) != 36 || !valid_text(epoch, 36) || !valid_text(identifier, 128) ||
        !valid_text(label, 512) || !valid_text(privacy, 4096) || !valid_text(status, 2048) ||
        saved < -1 || saved > 1 || (can_save != 0 && can_save != 1) ||
        (saved >= 0 && (strlen(epoch) != 36 || identifier[0] == '\0')) || (saved == -1 && can_save)) return -1;
    Delivery *value = g_new0(Delivery, 1);
    value->token = g_strdup(token); value->epoch = g_strdup(epoch); value->identifier = g_strdup(identifier);
    value->label = g_strdup(label); value->privacy = g_strdup(privacy); value->status = g_strdup(status);
    value->saved = saved; value->can_save = can_save;
    return jsti_window_post(apply_delivery, value, free_delivery);
}
int32_t jsti_window_finish_voice_credential(const char *token, const char *epoch, int32_t success, const char *message) {
    if (!valid_text(token, 36) || strlen(token) != 36 || !valid_text(epoch, 36) || strlen(epoch) != 36 ||
        !valid_text(message, 2048) || (success != 0 && success != 1)) return -1;
    Delivery *value = g_new0(Delivery, 1);
    value->finish = TRUE; value->token = g_strdup(token); value->epoch = g_strdup(epoch); value->status = g_strdup(message);
    return jsti_window_post(apply_delivery, value, free_delivery);
}

typedef struct { gint opens, saves, removes, cancels; gboolean valid; } Observed;
static void fixture_callback(const char *operation, const char *purpose, const char *identifier,
    const char *token, const char *epoch, const char *secret, void *context) {
    Observed *observed = context;
    observed->valid = observed->valid && g_strcmp0(purpose, "voice-output") == 0 && g_uuid_string_is_valid(token);
    if (g_strcmp0(operation, "open") == 0) ++observed->opens;
    else if (g_strcmp0(operation, "cancel") == 0) ++observed->cancels;
    else {
        observed->valid = observed->valid && g_strcmp0(identifier, "openai.tts.apiKey") == 0 &&
            g_uuid_string_is_valid(epoch);
        if (g_strcmp0(operation, "replace") == 0) {
            ++observed->saves; observed->valid = observed->valid && g_strcmp0(secret, "synthetic-only") == 0;
        } else if (g_strcmp0(operation, "remove") == 0) {
            ++observed->removes; observed->valid = observed->valid && secret[0] == '\0';
        } else observed->valid = FALSE;
    }
}
int32_t jsti_voice_credentials_self_test(char *error, size_t capacity) {
    Credentials *original = active;
    GtkWidget *group = jsti_voice_credentials_group_new();
    g_object_ref_sink(group);
    Credentials *form = active;
    Observed observed = {.valid = TRUE};
    form->callback = fixture_callback; form->context = &observed;
    request_view(form);
    gchar *epoch = g_uuid_string_random(), *obsolete = g_uuid_string_random();
    Delivery view = {.token = obsolete, .epoch = epoch, .identifier = "openai.tts.apiKey",
        .label = "OpenAI Voice Output key (separate from transcription)",
        .privacy = "Synthetic fixture only: no vault access, provider calls or actual credentials.",
        .status = "A synthetic saved key is present. It is not prefilled.", .saved = 1, .can_save = TRUE};
    apply_delivery(&view);
    gboolean passed = !gtk_widget_get_sensitive(GTK_WIDGET(form->key));
    gchar *canonical_view = g_ascii_strup(form->view_token, -1);
    view.token = canonical_view; apply_delivery(&view);
    passed = passed && gtk_widget_get_sensitive(GTK_WIDGET(form->key)) &&
        gtk_editable_get_text(GTK_EDITABLE(form->key))[0] == '\0' && ADW_IS_PASSWORD_ENTRY_ROW(form->key);
    passed = !emit(form, FALSE) && observed.saves == 0 && passed;
    gtk_editable_set_text(GTK_EDITABLE(form->key), "synthetic-only");
    passed = emit(form, FALSE) && observed.saves == 1 && passed;
    passed = passed && gtk_editable_get_text(GTK_EDITABLE(form->key))[0] == '\0' &&
        !gtk_widget_get_sensitive(GTK_WIDGET(form->key));
    gchar *first_token = g_ascii_strup(form->pending_token, -1), *previous_view = g_strdup(form->view_token);
    Delivery completion = {.token = first_token, .epoch = obsolete, .status = "Wrong epoch", .finish = TRUE};
    apply_delivery(&completion); passed = passed && form->pending_token != NULL;
    completion.epoch = epoch; completion.status = "The save could not be confirmed. Check the credential store.";
    apply_delivery(&completion);
    passed = passed && form->pending_token == NULL && g_strcmp0(form->view_token, previous_view) != 0;
    view.token = form->view_token; apply_delivery(&view);
    gtk_editable_set_text(GTK_EDITABLE(form->key), "synthetic-new-input");
    apply_delivery(&completion);
    passed = passed && g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(form->key)), "synthetic-new-input") == 0;
    jsti_voice_credentials_selection_pending();
    passed = passed && gtk_editable_get_text(GTK_EDITABLE(form->key))[0] == '\0' && !form->ready;
    jsti_voice_credentials_selection_changed();
    view.token = previous_view; apply_delivery(&view); passed = passed && !form->ready;
    view.token = form->view_token; apply_delivery(&view);
    Removal stale = {.view_token = obsolete, .epoch = epoch};
    confirm_removal(NULL, "remove", &stale); passed = passed && observed.removes == 0;
    Removal current = {.view_token = form->view_token, .epoch = epoch};
    confirm_removal(NULL, "cancel", &current); passed = passed && observed.removes == 0;
    confirm_removal(NULL, "remove", &current);
    passed = passed && observed.removes == 1 && form->pending_token != NULL;
    clear(NULL);
    passed = passed && observed.cancels == 1 && !gtk_widget_get_sensitive(GTK_WIDGET(form->key)) && observed.valid;
    g_object_unref(group); active = original;
    g_free(epoch); g_free(obsolete); g_free(first_token); g_free(previous_view); g_free(canonical_view);
    if (!passed) jsti_set_error(error, capacity,
        "Voice key masking, explicit removal, snapshot fencing, cancellation or late-completion protection failed.");
    return passed ? 0 : -1;
}
