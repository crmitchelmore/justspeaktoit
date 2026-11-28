#include "LinuxVoiceSourcesInternal.h"

typedef struct {
    GtkWindow *window;
    GtkWidget *name, *language, *transcript, *consent, *save, *reference_label;
    gchar *reference;
    Dialog *source;
} ProfileForm;

static void dispose_form(gpointer data) {
    ProfileForm *form = data;
    g_free(form->reference);
    release(form->source);
    g_free(form);
}

static const char *value(GtkWidget *entry) { return gtk_editable_get_text(GTK_EDITABLE(entry)); }

static void refresh_form(GObject *unused, gpointer data) {
    (void)unused;
    ProfileForm *form = data;
    gtk_widget_set_sensitive(form->save, form->reference && *form->reference &&
        *value(form->name) && *value(form->language) && *value(form->transcript) &&
        gtk_check_button_get_active(GTK_CHECK_BUTTON(form->consent)));
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
    if (!form) return;
    g_free(form->reference);
    form->reference = g_file_get_path(file);
    g_autofree gchar *name = g_file_get_basename(file);
    gtk_label_set_text(GTK_LABEL(form->reference_label), form->reference ? name : "Choose a local audio file.");
    gtk_editable_set_text(GTK_EDITABLE(form->transcript), "");
    refresh_form(NULL, form);
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

static void save_profile(GtkButton *unused, gpointer data) {
    (void)unused;
    ProfileForm *form = data;
    if (!gtk_widget_get_sensitive(form->save) || !form->source->window) return;
    g_autofree gchar *metadata = g_strjoin("\n", value(form->name), value(form->language), NULL);
    form->source->callback(120, 1, value(form->transcript), metadata, form->reference, form->source->context);
    gtk_label_set_text(form->source->notice, "Check the main window for the profile save result.");
    gtk_window_destroy(form->window);
}

void jsti_voice_profile_open(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *source = data;
    ProfileForm *form = g_new0(ProfileForm, 1);
    form->source = retain(source);
    form->window = GTK_WINDOW(gtk_window_new());
    g_object_set_data_full(G_OBJECT(form->window), "profile-form", form, dispose_form);
    gtk_window_set_title(form->window, "Create voice profile");
    gtk_window_set_transient_for(form->window, source->window);
    gtk_window_set_modal(form->window, TRUE);
    gtk_window_set_destroy_with_parent(form->window, TRUE);
    GtkBox *box = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8));
    gtk_window_set_child(form->window, GTK_WIDGET(box));
    form->name = entry(box, "Profile name", "voice-profile-name");
    form->language = entry(box, "Language", "voice-profile-language");
    form->reference = g_strdup(source->record);
    form->reference_label = label(*source->record ? "Reference: selected History recording" : "Choose a reference clip.");
    gtk_box_append(box, form->reference_label);
    GtkWidget *choose = gtk_button_new_with_label("Choose audio file...");
    gtk_widget_set_name(choose, "voice-profile-import");
    gtk_box_append(box, choose);
    g_signal_connect(choose, "clicked", G_CALLBACK(choose_file), form);
    form->transcript = entry(box, "Reference clip transcript", "voice-profile-transcript");
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
    g_signal_connect(form->save, "clicked", G_CALLBACK(save_profile), form);
    refresh_form(NULL, form);
    gtk_window_present(form->window);
}
