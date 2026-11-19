/* The markup helper: wrapping, examples, copy and its configuration from Swift. */
#include "LinuxVoiceSourcesInternal.h"

/* The host's markup helper configuration, kept for the next dialog. */
static MarkupConfiguration markup_configuration;

void clear_markup(MarkupConfiguration *config) {
    g_strfreev(config->texts); g_strfreev(config->descriptions);
    *config = (MarkupConfiguration){0};
}
static gboolean copy_markup(GtkWidget *widget, const char *value, gpointer data) {
    (void)data;
    GdkClipboard *clipboard = gtk_widget_get_clipboard(widget);
    if (clipboard == NULL) return FALSE;
    gdk_clipboard_set_text(clipboard, value);
    return TRUE;
}
static void markup_destroyed(gpointer data) {
    MarkupHelper *helper = data;
    if (helper->source->markup_window == helper->window) {
        helper->source->markup_window = NULL; helper->source->markup_apply = NULL;
    }
    clear_markup(&helper->config); release(helper->source); g_free(helper);
}
void close_markup(GtkButton *button, gpointer data) {
    (void)button;
    MarkupHelper *helper = data;
    if (helper->source->markup_window == helper->window) {
        helper->source->markup_window = NULL; helper->source->markup_apply = NULL;
    }
    if (helper->source->window != NULL) gtk_widget_grab_focus(GTK_WIDGET(helper->source->editor));
    gtk_window_destroy(helper->window);
}
static gboolean markup_close_request(GtkWindow *window, gpointer data) {
    (void)window; close_markup(NULL, data); return TRUE;
}
gboolean markup_key(GtkEventControllerKey *controller, guint key, guint code,
                            GdkModifierType state, gpointer data) {
    (void)controller; (void)code; (void)state;
    if (key != GDK_KEY_Escape) return FALSE;
    close_markup(NULL, data); return TRUE;
}
static void select_markup_example(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec;
    MarkupHelper *helper = data;
    guint index = gtk_drop_down_get_selected(helper->examples);
    if (index >= g_strv_length(helper->config.texts)) return;
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(helper->example), helper->config.texts[index], -1);
}
static void copy_markup_example(GtkButton *button, gpointer data) {
    MarkupHelper *helper = data;
    guint index = gtk_drop_down_get_selected(helper->examples);
    gboolean copied = index < g_strv_length(helper->config.texts) && helper->copy != NULL &&
        helper->copy(GTK_WIDGET(button), helper->config.texts[index], helper->copy_context);
    gtk_label_set_text(helper->notice, copied ? "Example copied. The draft is unchanged."
        : "The example could not be copied. Try again.");
}
gboolean apply_markup(MarkupHelper *helper) {
    Dialog *dialog = helper->source;
    if (!can_edit_markup(dialog)) {
        gtk_label_set_text(helper->notice, "Choose an editable draft and enable SSML for a compatible voice.");
        return FALSE;
    }
    gchar *original = text(dialog);
    gsize bytes = strlen(original);
    if (bytes > 1000000) {
        gtk_label_set_text(helper->notice, "The draft is too large to wrap. Its text and selection are unchanged.");
        g_free(original); return FALSE;
    }
    gchar *wrapped = g_malloc0(bytes + 1024);
    int32_t leading_utf16 = 0, leading_scalars = 0;
    gboolean valid = helper->config.wrap != NULL &&
        helper->config.wrap(original, wrapped, bytes + 1024, &leading_utf16, &leading_scalars) == 0 &&
        memchr(wrapped, 0, bytes + 1024) != NULL && g_utf8_validate(wrapped, -1, NULL) &&
        leading_scalars >= 0 && leading_scalars <= g_utf8_strlen(wrapped, -1);
    if (!valid) {
        gtk_label_set_text(helper->notice, "The draft could not be wrapped. Its text and selection are unchanged.");
        g_free(original); g_free(wrapped); return FALSE;
    }
    if (strcmp(original, wrapped) != 0) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(dialog->editor);
        GtkTextIter insert, bound, start, end;
        gtk_text_buffer_get_iter_at_mark(buffer, &insert, gtk_text_buffer_get_insert(buffer));
        gtk_text_buffer_get_iter_at_mark(buffer, &bound, gtk_text_buffer_get_selection_bound(buffer));
        gint insert_offset = gtk_text_iter_get_offset(&insert) + leading_scalars;
        gint bound_offset = gtk_text_iter_get_offset(&bound) + leading_scalars;
        gtk_text_buffer_begin_user_action(buffer);
        gtk_text_buffer_get_bounds(buffer, &start, &end); gtk_text_buffer_delete(buffer, &start, &end);
        gtk_text_buffer_get_start_iter(buffer, &start); gtk_text_buffer_insert(buffer, &start, wrapped, -1);
        gtk_text_buffer_end_user_action(buffer);
        gtk_text_buffer_get_iter_at_offset(buffer, &insert, insert_offset);
        gtk_text_buffer_get_iter_at_offset(buffer, &bound, bound_offset);
        gtk_text_buffer_select_range(buffer, &insert, &bound);
    }
    gtk_label_set_text(dialog->notice, "SSML draft updated. No speech was generated or settings saved.");
    g_free(original); g_free(wrapped); return TRUE;
}
static void wrap_markup(GtkButton *button, gpointer data) {
    if (apply_markup(data)) close_markup(button, data);
}
MarkupHelper *make_markup_helper(Dialog *dialog) {
    if (!can_edit_markup(dialog)) return NULL;
    MarkupHelper *helper = g_new0(MarkupHelper, 1);
    helper->source = retain(dialog); helper->copy = copy_markup;
    helper->config = markup_configuration;
    helper->config.texts = g_strdupv(markup_configuration.texts);
    helper->config.descriptions = g_strdupv(markup_configuration.descriptions);
    helper->window = GTK_WINDOW(gtk_window_new());
    dialog->markup_window = helper->window;
    g_object_set_data_full(G_OBJECT(helper->window), "ssml-helper", helper, markup_destroyed);
    gtk_window_set_title(helper->window, "SSML Helper");
    gtk_window_set_transient_for(helper->window, dialog->window);
    gtk_window_set_modal(helper->window, TRUE); gtk_window_set_destroy_with_parent(helper->window, TRUE);
    gtk_window_set_default_size(helper->window, 510, 425);
    g_signal_connect(helper->window, "close-request", G_CALLBACK(markup_close_request), helper);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20); gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 20); gtk_widget_set_margin_bottom(box, 20);
    gtk_window_set_child(helper->window, box);
    gtk_box_append(GTK_BOX(box), label("Wrap the entire draft with SSML tags. Copy examples to edit manually; "
        "copying does not insert or replace text."));
    gtk_box_append(GTK_BOX(box), label("Common tags"));
    helper->examples = GTK_DROP_DOWN(gtk_drop_down_new_from_strings(
        (const char *const *)helper->config.descriptions));
    jsti_accessible_set_name(GTK_WIDGET(helper->examples), "Common SSML tags");
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(helper->examples));
    helper->example = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_editable(helper->example, FALSE);
    gtk_text_view_set_wrap_mode(helper->example, GTK_WRAP_WORD_CHAR);
    gtk_accessible_update_property(GTK_ACCESSIBLE(helper->example),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "SSML example markup", -1);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_size_request(scroll, -1, 90);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(helper->example));
    gtk_box_append(GTK_BOX(box), scroll);
    GtkWidget *copy = gtk_button_new_with_mnemonic("_Copy example");
    helper->copy_button = copy;
    gtk_box_append(GTK_BOX(box), copy);
    helper->notice = GTK_LABEL(label("Closing leaves the draft and its selection unchanged."));
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(helper->notice));
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *close = gtk_button_new_with_label("Close");
    GtkWidget *wrap = gtk_button_new_with_mnemonic("_Wrap with <speak>");
    dialog->markup_apply = wrap;
    gtk_widget_set_size_request(close, -1, 36); gtk_widget_set_size_request(wrap, -1, 36);
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0); gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(actions), close); gtk_box_append(GTK_BOX(actions), spacer);
    gtk_box_append(GTK_BOX(actions), wrap); gtk_box_append(GTK_BOX(box), actions);
    gtk_widget_add_css_class(wrap, "suggested-action"); gtk_window_set_default_widget(helper->window, wrap);
    g_signal_connect(helper->examples, "notify::selected", G_CALLBACK(select_markup_example), helper);
    g_signal_connect(copy, "clicked", G_CALLBACK(copy_markup_example), helper);
    g_signal_connect(close, "clicked", G_CALLBACK(close_markup), helper);
    g_signal_connect(wrap, "clicked", G_CALLBACK(wrap_markup), helper);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(markup_key), helper);
    gtk_widget_add_controller(GTK_WIDGET(helper->window), keys);
    select_markup_example(NULL, NULL, helper);
    return helper;
}
void show_markup(GtkButton *button, gpointer data) {
    (void)button;
    Dialog *dialog = data;
    if (dialog->markup_window != NULL) { gtk_window_present(dialog->markup_window); return; }
    MarkupHelper *helper = make_markup_helper(dialog);
    if (helper != NULL) gtk_window_present(helper->window);
}
gboolean markup_configured(void) { return markup_configuration.enabled && markup_configuration.wrap != NULL; }
void reset_markup_configuration(void) { clear_markup(&markup_configuration); }
void swap_markup_configuration(MarkupConfiguration *value) {
    MarkupConfiguration previous = markup_configuration;
    markup_configuration = *value; *value = previous;
}
static void apply_markup_configuration(gpointer data) {
    MarkupConfiguration *changed = data;
    swap_markup_configuration(changed);
    clear_markup(changed);
    Dialog *open = voice_open_dialog();
    if (open != NULL) refresh(open);
}
static void free_markup_configuration(gpointer data) {
    MarkupConfiguration *config = data; clear_markup(config); g_free(config);
}
int32_t jsti_window_set_voice_markup_helper(int32_t enabled, const JSTIVoiceMarkupExample *examples,
                                           size_t count, JSTIVoiceMarkupWrapCallback wrap) {
    if ((enabled != 0 && enabled != 1) || examples == NULL || count == 0 || count > 32 || wrap == NULL) return -1;
    MarkupConfiguration *config = g_new0(MarkupConfiguration, 1);
    config->enabled = enabled != 0; config->wrap = wrap;
    config->texts = g_new0(gchar *, count + 1); config->descriptions = g_new0(gchar *, count + 1);
    for (size_t index = 0; index < count; ++index) {
        if (examples[index].text == NULL || examples[index].description == NULL ||
            examples[index].text[0] == '\0' || examples[index].description[0] == '\0' ||
            strlen(examples[index].text) > 8192 || strlen(examples[index].description) > 256 ||
            !g_utf8_validate(examples[index].text, -1, NULL) ||
            !g_utf8_validate(examples[index].description, -1, NULL)) {
            free_markup_configuration(config); return -1;
        }
        config->texts[index] = g_strdup(examples[index].text);
        config->descriptions[index] = g_strdup(examples[index].description);
    }
    return jsti_window_post(apply_markup_configuration, config, free_markup_configuration);
}
