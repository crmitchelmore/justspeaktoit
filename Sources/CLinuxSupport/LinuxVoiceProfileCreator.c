#include "LinuxVoiceSourcesInternal.h"
#include <adwaita.h>

typedef struct {
    GtkWindow *window;
    GtkWidget *name, *language, *transcript, *consent, *save, *reference_label;
    GtkDropDown *profiles;
    GtkStringList *names, *ids;
    GtkWidget *remove;
    GtkWidget *choose, *record, *preview, *transcribe, *add, *status;
    gchar *reference, *session;
    gboolean ready, pending, recording;
    guint added;
    Dialog *source;
} ProfileForm;

static ProfileForm *active_profile;
static void profile_request(ProfileForm *form, int op, const char *text, const char *metadata);

static void editor_destroyed(GtkWidget *widget, gpointer data) {
    (void)widget;
    ProfileForm *form = data;
    if (active_profile != form) return;
    active_profile = NULL;
    if (form->source->window)
        form->source->callback(120, JSTI_PROFILE_CLOSE, "", form->session, "", form->source->context);
}

static void dispose_form(gpointer data) {
    ProfileForm *form = data;
    editor_destroyed(NULL, form);
    g_object_unref(form->ids);
    g_free(form->session);
    g_free(form->reference);
    release(form->source);
    g_free(form);
}

static const char *value(GtkWidget *entry) { return gtk_editable_get_text(GTK_EDITABLE(entry)); }

static void refresh_form(GObject *unused, gpointer data) {
    (void)unused;
    ProfileForm *form = data;
    gboolean idle = !form->pending && !form->recording;
    gboolean has_words = *value(form->transcript) != '\0';
    gtk_widget_set_sensitive(form->remove, idle && g_list_model_get_n_items(G_LIST_MODEL(form->ids)) > 0);
    gtk_widget_set_sensitive(form->choose, idle);
    gtk_widget_set_sensitive(form->record, !form->pending);
    gtk_button_set_label(GTK_BUTTON(form->record), form->recording ? "Stop recording" : "Record guided script");
    gtk_widget_set_sensitive(form->preview, idle && form->ready);
    gtk_widget_set_sensitive(form->transcribe, idle && form->ready);
    gtk_widget_set_sensitive(form->add, idle && form->ready && has_words && form->added < 2);
    gtk_widget_set_sensitive(form->transcript, idle && form->ready);
    gtk_widget_set_sensitive(form->save, idle && (form->ready ? has_words : form->added > 0) &&
        *value(form->name) && *value(form->language) && gtk_check_button_get_active(GTK_CHECK_BUTTON(form->consent)));
}

static GtkWidget *entry(GtkBox *box, const char *title, const char *id) {
    gtk_box_append(box, label(title));
    GtkWidget *widget = gtk_entry_new();
    jsti_accessible_set_name(widget, title);
    gtk_widget_set_name(widget, id);
    gtk_box_append(box, widget);
    return widget;
}

static void file_selected(GObject *object, GAsyncResult *result, gpointer data) {
    GWeakRef *request = data;
    g_autoptr(GObject) window = g_weak_ref_get(request);
    g_weak_ref_clear(request);
    g_free(request);
    g_autoptr(GError) error = NULL;
    g_autoptr(GFile) file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(object), result, &error);
    if (!window || !file) return;
    ProfileForm *form = g_object_get_data(window, "profile-form");
    if (!form || active_profile != form) return;
    g_free(form->reference);
    form->reference = g_file_get_path(file);
    g_autofree gchar *name = g_file_get_basename(file);
    gtk_label_set_text(GTK_LABEL(form->reference_label), form->reference ? name : "Choose a local audio file.");
    gtk_editable_set_text(GTK_EDITABLE(form->transcript), "");
    form->ready = FALSE;
    profile_request(form, JSTI_PROFILE_PREPARE, "", form->session);
}

static void choose_file(GtkButton *unused, gpointer data) {
    (void)unused;
    ProfileForm *form = data;
    g_autoptr(GtkFileDialog) dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Choose reference audio (WAV, M4A or MP3)");
    GWeakRef *request = g_new0(GWeakRef, 1);
    g_weak_ref_init(request, G_OBJECT(form->window));
    gtk_file_dialog_open(dialog, form->window, NULL, file_selected, request);
}

static void profile_request(ProfileForm *form, int op, const char *text, const char *metadata) {
    if (!form->source->window) return;
    form->pending = TRUE;
    refresh_form(NULL, form);
    form->source->callback(120, op, text, metadata, form->reference ? form->reference : "", form->source->context);
}

static void deletion_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    ProfileForm *form = g_object_get_data(G_OBJECT(data), "profile-form");
    if (!form || !g_str_equal(response, "delete")) return;
    const char *id = g_object_get_data(G_OBJECT(dialog), "profile-id");
    form->pending = TRUE;
    refresh_form(NULL, form);
    form->source->callback(120, JSTI_PROFILE_DELETE, "", form->session, id, form->source->context);
}

static void action(GtkButton *button, gpointer data) {
    ProfileForm *form = data;
    GtkWidget *widget = GTK_WIDGET(button);
    if (!gtk_widget_get_sensitive(widget)) return;
    if (widget == form->remove) {
        const char *id = gtk_string_list_get_string(form->ids, gtk_drop_down_get_selected(form->profiles));
        if (!id) return;
        form->pending = TRUE;
        refresh_form(NULL, form);
        form->source->callback(120, JSTI_PROFILE_REVIEW_DELETE, "", form->session, id, form->source->context);
    } else if (widget == form->save) {
        g_autofree gchar *metadata = g_strjoin("\n", form->session, "consent-v1", value(form->name), value(form->language), NULL);
        profile_request(form, JSTI_PROFILE_SAVE, value(form->transcript), metadata);
    } else if (widget == form->record) {
        if (!form->recording) form->ready = FALSE;
        profile_request(form, form->recording ? JSTI_PROFILE_STOP_RECORDING : JSTI_PROFILE_RECORD, "", form->session);
    } else {
        int op = widget == form->preview ? JSTI_PROFILE_PREVIEW : widget == form->transcribe ? JSTI_PROFILE_TRANSCRIBE : JSTI_PROFILE_ADD;
        profile_request(form, op, value(form->transcript), form->session);
    }
}

static GtkWidget *action_button(GtkBox *box, const char *title, const char *id, ProfileForm *form) {
    GtkWidget *button = gtk_button_new_with_label(title);
    gtk_widget_set_name(button, id);
    gtk_box_append(box, button);
    g_signal_connect(button, "clicked", G_CALLBACK(action), form);
    return button;
}

typedef struct { gchar *session, *status, *transcript; int phase; } ProfileResult;
static void apply_result(gpointer data) {
    ProfileResult *result = data;
    ProfileForm *form = active_profile;
    if (!form || !g_str_equal(form->session, result->session)) return;
    if (result->phase == JSTI_PROFILE_CLEAR_PROFILES) {
        gtk_string_list_splice(form->ids, 0, g_list_model_get_n_items(G_LIST_MODEL(form->ids)), NULL);
        gtk_string_list_splice(form->names, 0, g_list_model_get_n_items(G_LIST_MODEL(form->names)), NULL);
        return;
    }
    if (result->phase == JSTI_PROFILE_PROFILE) {
        gtk_string_list_append(form->ids, result->status);
        gtk_string_list_append(form->names, result->transcript);
        return;
    }
    if (result->phase == JSTI_PROFILE_CONFIRM_DELETE) {
        form->pending = FALSE;
        refresh_form(NULL, form);
        GtkWidget *dialog = adw_message_dialog_new(form->window, "Delete voice profile?", result->status);
        adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "delete", "Delete", NULL);
        adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
        g_object_set_data_full(G_OBJECT(dialog), "profile-id", g_strdup(result->transcript), g_free);
        g_signal_connect_object(dialog, "response", G_CALLBACK(deletion_response), form->window, 0);
        gtk_window_present(GTK_WINDOW(dialog));
        return;
    }
    if (result->phase == JSTI_PROFILE_SAVED) {
        gtk_label_set_text(form->source->notice, result->status);
        gtk_window_destroy(form->window);
        return;
    }
    gtk_label_set_text(GTK_LABEL(form->status), result->status);
    if (result->phase == JSTI_PROFILE_LEVEL) return;
    jsti_accessible_announce(form->status, result->status, 1);
    form->recording = result->phase == JSTI_PROFILE_RECORDING;
    if (form->recording) gtk_label_set_text(GTK_LABEL(form->reference_label), result->transcript);
    form->pending = FALSE;
    if (result->phase == JSTI_PROFILE_STAGED) form->ready = TRUE;
    if (result->phase == JSTI_PROFILE_ADDED) { form->added++; form->ready = FALSE; }
    if (result->transcript) gtk_editable_set_text(GTK_EDITABLE(form->transcript), result->transcript);
    refresh_form(NULL, form);
}

static void free_result(gpointer data) {
    ProfileResult *result = data;
    g_free(result->session); g_free(result->status); g_free(result->transcript); g_free(result);
}

int32_t jsti_window_voice_profile_result(const char *session, int32_t phase, const char *status, const char *transcript) {
    ProfileResult *result = g_new0(ProfileResult, 1);
    result->session = g_strdup(session); result->phase = phase;
    result->status = g_strdup(status); result->transcript = g_strdup(transcript);
    return jsti_window_post(apply_result, result, free_result);
}

void jsti_voice_profile_open(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *source = data;
    ProfileForm *form = g_new0(ProfileForm, 1);
    form->source = retain(source);
    active_profile = form;
    form->session = g_uuid_string_random();
    form->window = GTK_WINDOW(gtk_window_new());
    g_object_set_data_full(G_OBJECT(form->window), "profile-form", form, dispose_form);
    g_signal_connect(form->window, "destroy", G_CALLBACK(editor_destroyed), form);
    gtk_window_set_title(form->window, "Create voice profile");
    gtk_window_set_transient_for(form->window, source->window);
    gtk_window_set_modal(form->window, TRUE);
    gtk_window_set_destroy_with_parent(form->window, TRUE);
    GtkBox *box = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8));
    gtk_window_set_child(form->window, GTK_WIDGET(box));
    form->names = gtk_string_list_new(NULL);
    form->ids = gtk_string_list_new(NULL);
    form->profiles = GTK_DROP_DOWN(gtk_drop_down_new(G_LIST_MODEL(form->names), NULL));
    jsti_accessible_set_name(GTK_WIDGET(form->profiles), "Saved voice profiles");
    gtk_widget_set_name(GTK_WIDGET(form->profiles), "voice-profile-list");
    gtk_box_append(box, label("Saved voice profiles"));
    gtk_box_append(box, GTK_WIDGET(form->profiles));
    form->remove = action_button(box, "Delete selected profile...", "voice-profile-delete", form);
    form->name = entry(box, "Profile name", "voice-profile-name");
    form->language = entry(box, "Language", "voice-profile-language");
    form->reference = g_strdup(source->record);
    form->reference_label = label(*source->record ? "Reference: selected History recording" : "Choose a reference clip.");
    gtk_box_append(box, form->reference_label);
    GtkWidget *choose = form->choose = gtk_button_new_with_label("Choose audio file...");
    gtk_widget_set_name(choose, "voice-profile-import");
    gtk_box_append(box, choose);
    g_signal_connect(choose, "clicked", G_CALLBACK(choose_file), form);
    form->transcript = entry(box, "Reference clip transcript", "voice-profile-transcript");
    GtkBox *tools = GTK_BOX(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6));
    gtk_box_append(box, GTK_WIDGET(tools));
    form->record = action_button(tools, "Record guided script", "voice-profile-record", form);
    form->preview = action_button(tools, "Play clip", "voice-profile-preview", form);
    form->transcribe = action_button(tools, "Auto-fill transcript", "voice-profile-transcribe", form);
    form->add = action_button(tools, "Add clip", "voice-profile-add", form);
    form->status = label("");
    gtk_box_append(box, form->status);
    form->consent = gtk_check_button_new_with_label(
        "This is my voice, or I have the speaker's permission to copy it. I'll use it only for my own read aloud.");
    gtk_widget_set_name(form->consent, "voice-profile-consent");
    gtk_box_append(box, form->consent);
    form->save = gtk_button_new_with_label("Save voice profile");
    gtk_widget_set_name(form->save, "voice-profile-save");
    gtk_box_append(box, form->save);
    g_signal_connect(form->name, "changed", G_CALLBACK(refresh_form), form);
    g_signal_connect(form->language, "changed", G_CALLBACK(refresh_form), form);
    g_signal_connect(form->transcript, "changed", G_CALLBACK(refresh_form), form);
    g_signal_connect(form->consent, "toggled", G_CALLBACK(refresh_form), form);
    g_signal_connect(form->save, "clicked", G_CALLBACK(action), form);
    refresh_form(NULL, form);
    gtk_window_present(form->window);
    profile_request(form, JSTI_PROFILE_PREPARE, "", form->session);
}

static void fixture_event(int32_t action, int32_t operation, const char *text, const char *metadata,
                          const char *reference, void *context) {
    (void)reference;
    if (action == 120 && operation == JSTI_PROFILE_SAVE && g_str_equal(text, "Edited fixture.") &&
        g_str_has_suffix(metadata, "\nconsent-v1\nFixture\nen")) ++*(int *)context;
}

gboolean jsti_voice_profile_fixture(Dialog *source) {
    JSTIVoiceSourceCallback previous = source->callback;
    void *previous_context = source->context;
    int saves = 0;
    source->callback = fixture_event;
    source->context = &saves;
    jsti_voice_profile_open(NULL, source);
    ProfileForm *form = active_profile;
    ProfileResult ready = {form->session, "Synthetic clip ready", "Edited fixture.", JSTI_PROFILE_STAGED};
    apply_result(&ready);
    gtk_editable_set_text(GTK_EDITABLE(form->name), "Fixture");
    gtk_editable_set_text(GTK_EDITABLE(form->language), "en");
    gboolean gated = !gtk_widget_get_sensitive(form->save);
    action(GTK_BUTTON(form->save), form);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(form->consent), TRUE);
    gboolean enabled = gtk_widget_get_sensitive(form->save);
    action(GTK_BUTTON(form->save), form);
    gboolean pending = !gtk_widget_get_sensitive(form->save);
    gtk_window_destroy(form->window);
    source->callback = previous;
    source->context = previous_context;
    return gated && enabled && pending && saves == 1;
}
