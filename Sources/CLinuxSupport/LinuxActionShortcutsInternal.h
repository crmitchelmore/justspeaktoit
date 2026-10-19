#ifndef JSTI_LINUX_ACTION_SHORTCUTS_INTERNAL_H
#define JSTI_LINUX_ACTION_SHORTCUTS_INTERNAL_H
#include "LinuxSupportInternal.h"
#include <adwaita.h>

typedef struct ActionRow {
    gchar *identifier, *title, *chord, *note, *page;
    guint keysym, modifiers;
    gint run, slot;
    gboolean enabled, binding_enabled, binding_global, can_be_global, has_key;
} ActionRow;

GPtrArray *jsti_action_shortcuts_copy_rows(const JSTILinuxActionShortcut *rows, size_t count);
GPtrArray *jsti_action_shortcuts_clone_rows(GPtrArray *rows);
void jsti_action_shortcut_editor_rows(GPtrArray *rows);
void jsti_action_shortcut_editor_open(GtkWindow *owner);
void jsti_action_shortcut_editor_set_idle(gboolean idle);
void jsti_action_shortcut_editor_close(void);
int32_t jsti_action_shortcut_editor_self_test(GtkWindow *owner, char *error, size_t capacity);
#endif
