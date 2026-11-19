/* Corrections and Pronunciation editors: the editor model shared by the page
 * (LinuxVocabulary.c), its button actions (LinuxVocabularyActions.c) and host
 * payloads (LinuxVocabularyPresentation.c), and the operations its self-test
 * (CLinuxSelfTest) drives. Not public ABI. */
#ifndef JSTI_LINUX_VOCABULARY_INTERNAL_H
#define JSTI_LINUX_VOCABULARY_INTERNAL_H

#include "LinuxSupportInternal.h"
#include <adwaita.h>

typedef struct {
    gchar *value;
    guint count;
} Category;
typedef struct {
    int kind;
    GtkWidget *root, *fields[8], *preview, *preview_tags, *status, *search, *category_filter;
    GtkWidget *learning_preferences;
    GtkListBox *list;
    GPtrArray *rows, *categories;
    gchar *category;
    GPtrArray *buttons;
    gint selected;
    gboolean filling, busy;
    guint64 consent_token;
    GtkCheckButton *include_rules, *include_tags;
    GtkEntry *tags;
} Editor;

/* A host payload for one editor, applied on the GTK main thread. */
typedef struct { int kind; gchar *payload; gboolean refresh; } Presentation;

#pragma GCC visibility push(hidden)

/* The open editor of each vocabulary kind (0...4), or NULL. LinuxVocabulary.c
 * owns the table; the self-test swaps an entry and puts it back. GTK main
 * thread only. */
Editor *vocabulary_editor(int kind);
void vocabulary_set_editor(int kind, Editor *editor);

GtkWidget *jsti_vocabulary_page_new(int kind);
/* The selected row is filtered out of view. */
gboolean vocabulary_hidden_selection(Editor *e);
gchar *vocabulary_text(GtkWidget *widget);
void vocabulary_set_text(GtkWidget *widget, const char *value);
/* Shows `row` (or clears the fields when NULL) without reporting edits. */
void vocabulary_fill(Editor *e, gchar **row);
void vocabulary_pending(Editor *e, gboolean busy);
/* The TAB-separated payload `action` sends for the editor's fields. */
gchar *vocabulary_action_payload(Editor *e, const char *action);
void vocabulary_send_action(Editor *e, const char *action);
/* Applies a Presentation (its `data`); the caller keeps ownership. */
void vocabulary_present(gpointer data);

/* LinuxVocabulary.c, for the action and presentation units. */
/* Appends a TAB and `value`, escaping %, TAB, CR and LF. */
void vocabulary_append_field(GString *payload, const char *value);
/* Disables row actions while the selection is hidden by filters. */
void vocabulary_selection_controls(Editor *e);
/* Re-runs the list filter and keeps the selection only while it is visible. */
void vocabulary_apply_filters(Editor *e);
/* A word-wrapping text view in a scroller; `*view` receives the text view. */
GtkWidget *vocabulary_multiline(GtkWidget **view);
/* LinuxVocabularyActions.c: a button that runs `action` (a static string). */
GtkWidget *vocabulary_button(Editor *e, const char *title, const char *action);
/* LinuxVocabularyPresentation.c: frees a Category. */
void vocabulary_category_free(gpointer data);

#pragma GCC visibility pop

#endif
