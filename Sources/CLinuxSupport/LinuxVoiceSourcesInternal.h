/* Private to the LinuxVoiceSources*.c units and their self-test: the dialog
 * state and the helpers they share. Never exported. */
#ifndef JSTI_LINUX_VOICE_SOURCES_INTERNAL_H
#define JSTI_LINUX_VOICE_SOURCES_INTERNAL_H
#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>

typedef struct {
    gboolean enabled;
    gchar **texts, **descriptions;
    JSTIVoiceMarkupWrapCallback wrap;
} MarkupConfiguration;

typedef struct { gchar **labels, **identifiers; guint selected; gchar *status; } FormatState;

typedef struct {
    gint refs;
    GtkWindow *window;
    GtkDropDown *source;
    GtkDropDown *format;
    GtkTextView *editor;
    GtkLabel *notice;
    GtkButton *read, *export_button, *load;
    GtkButton *generate, *play_result, *export_result;
    GtkCheckButton *auto_play, *save;
    GtkWidget *helper, *markup_apply;
    GtkWindow *markup_window;
    gchar *result_id, *result_format;
    gboolean format_pending;
    guint generation_flags;
    gboolean working, applying_options;
    gchar *record, *history, *typed, *clipboard, *file, *import_token;
    guint selected;
    guint64 revision;
    GCancellable *clipboard_cancel;
    JSTIVoiceSourceCallback callback;
    void *context;
} Dialog;

typedef struct {
    Dialog *source;
    GtkWindow *window;
    GtkDropDown *examples;
    GtkTextView *example;
    GtkLabel *notice;
    GtkWidget *copy_button;
    MarkupConfiguration config;
    gboolean (*copy)(GtkWidget *, const char *, gpointer);
    gpointer copy_context;
} MarkupHelper;

typedef struct { Dialog *dialog; gchar *text, *record, *format; guint source; gboolean retained; } Export;

void jsti_show_voice_controls(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context);
void jsti_show_voice_usage(GtkWindow *owner, const char *snapshot, JSTIVoiceSourceCallback callback, void *context);
void jsti_show_voice_discovery(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context);

#pragma GCC visibility push(hidden)

extern MarkupConfiguration markup_configuration;  /* LinuxVoiceSources.c */
extern guint generation_flags;  /* LinuxVoiceSources.c */
extern gboolean generation_working;  /* LinuxVoiceSources.c */
extern gchar *generated_result;  /* LinuxVoiceSources.c */
extern gchar *generated_format;  /* LinuxVoiceSources.c */
extern FormatState format_state;  /* LinuxVoiceSources.c */
extern Dialog *active;  /* LinuxVoiceSources.c */
Dialog *retain(Dialog *dialog);
void release(gpointer data);
gchar *text(Dialog *dialog);
gboolean can_edit_markup(Dialog *dialog);
void refresh(Dialog *dialog);
GtkWidget *label(const char *value);
void clear_markup(MarkupConfiguration *config);
void close_markup(GtkButton *button, gpointer data);
gboolean markup_key(GtkEventControllerKey *controller, guint key, guint code,
                            GdkModifierType state, gpointer data);
gboolean apply_markup(MarkupHelper *helper);
MarkupHelper *make_markup_helper(Dialog *dialog);
void show_markup(GtkButton *button, gpointer data);
void cancel_import(Dialog *dialog);
void changed(GtkTextBuffer *buffer, gpointer data);
void select_source(GObject *object, GParamSpec *spec, gpointer data);
gboolean apply_import_result(Dialog *dialog, const char *token, const char *value, const char *error);
void load_clipboard(GtkButton *button, gpointer data);
void voice_read_aloud(GtkButton *button, gpointer data);
void stop(GtkButton *button, gpointer data);
const char *selected_format(Dialog *dialog);
void export_audio(GtkButton *button, gpointer data);
void generate_audio(GtkButton *button, gpointer data);
void format_changed(GObject *object, GParamSpec *spec, gpointer data);
void show_formats(Dialog *dialog);
void clear_formats(FormatState *value);
void play_result(GtkButton *button, gpointer data);
void preferences_changed(GtkCheckButton *button, gpointer data);
void synthesis_controls(GtkButton *button, gpointer data);
void usage_report(GtkButton *button, gpointer data);
void account_voices(GtkButton *button, gpointer data);
Dialog *make_dialog(GtkWindow *owner, const char *record, const char *history);

#pragma GCC visibility pop

#endif
