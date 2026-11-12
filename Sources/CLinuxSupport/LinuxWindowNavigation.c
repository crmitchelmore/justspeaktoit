/* Navigation: page switching, the sidebar, its shortcuts and cancel keys. */
#include "LinuxWindowNavigationState.h"

/* Sidebar entries in page order, with the Mac sidebar's tints. */
typedef struct PageInfo {
    const char *name;
    const char *title;
    const char *icon;
    const char *tint;
} PageInfo;

static const PageInfo page_info[JSTI_PAGE_COUNT] = {
    [JSTI_PAGE_DASHBOARD] = { "dashboard", "Dashboard", "view-grid-symbolic", "jsti-tint-lagoon" },
    [JSTI_PAGE_HISTORY] = { "history", "History", "document-open-recent-symbolic", "jsti-tint-accent" },
    [JSTI_PAGE_VOICE_OUTPUT] = { "voice-output", "Voice Output", "audio-speakers-symbolic", "jsti-tint-green" },
    [JSTI_PAGE_GENERAL] = { "general", "General", "emblem-system-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_TRANSCRIPTION] = { "transcription", "Transcription", "audio-input-microphone-symbolic",
                                  "jsti-tint-warm" },
    [JSTI_PAGE_POST_PROCESSING] = { "post-processing", "Post-processing", "starred-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_CORRECTIONS] = { "corrections", "Corrections", "document-edit-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_PRONUNCIATION] = { "pronunciation", "Pronunciation", "accessories-dictionary-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_PROFILES] = { "profiles", "Profiles", "system-users-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_KEYBOARD] = { "keyboard", "Keyboard", "input-keyboard-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_CLOUD_SYNC] = { "icloud-sync", "iCloud Sync", "emblem-synchronizing-symbolic", "jsti-tint-warm" },
    [JSTI_PAGE_ABOUT] = { "about", "About", "help-about-symbolic", "jsti-tint-warm" },
};
static SidebarShortcuts sidebar_shortcuts;
SidebarShortcuts *sidebar_shortcuts_state(void) { return &sidebar_shortcuts; }

const char *page_name(gint32 page) {
    return page >= 0 && page < JSTI_PAGE_COUNT ? page_info[page].name : NULL;
}

void show_page(gint32 page) {
    if (page < 0 || page >= JSTI_PAGE_COUNT) return;
    if (ui.page != page) retire_cleanup_preview();
    ui.page = page;
    if (page == JSTI_PAGE_CORRECTIONS || page == JSTI_PAGE_PRONUNCIATION)
        emit(71, "", page == JSTI_PAGE_CORRECTIONS ? 0 : 1);
    if (page == JSTI_PAGE_PROFILES) emit(JSTI_EVENT_PROFILES, "refresh", 0);
    GtkWidget *focus = gtk_root_get_focus(GTK_ROOT(ui.window));
    gtk_stack_set_visible_child_name(ui.pages, page_info[page].name);
    adw_window_title_set_title(ui.title, page_info[page].title);
    GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.sidebar, page);
    if (row != NULL && gtk_list_box_get_selected_row(ui.sidebar) != row) gtk_list_box_select_row(ui.sidebar, row);
    adw_navigation_split_view_set_show_content(ui.split, TRUE);
    /* GtkStack moves focus off a page it hides, but never off the sidebar. Focus there
     * would be lost when the collapsed layout hides it, or left on the search that chose
     * the page, so it moves into the page. A shortcut pressed on a sidebar row moves
     * focus to the new row, so the row Orca reads and Return opens is the shown page. */
    GtkWidget *visible = gtk_stack_get_visible_child(ui.pages);
    GtkWidget *sidebar = GTK_WIDGET(adw_navigation_split_view_get_sidebar(ui.split));
    if (focus == NULL || visible == NULL || sidebar == NULL || !gtk_widget_is_ancestor(focus, sidebar)) return;
    if (adw_navigation_split_view_get_collapsed(ui.split) || !gtk_widget_is_ancestor(focus, GTK_WIDGET(ui.sidebar)))
        gtk_widget_child_focus(visible, GTK_DIR_TAB_FORWARD);
    else if (row != NULL && focus != GTK_WIDGET(row))
        gtk_widget_grab_focus(GTK_WIDGET(row));
}

static void on_sidebar(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    (void)box; (void)data;
    if (row != NULL) show_page(gtk_list_box_row_get_index(row));
}

gboolean sidebar_navigate(guint keyval, GdkModifierType modifiers, GtkWidget *focused) {
    GdkModifierType relevant = modifiers & (GDK_CONTROL_MASK | GDK_SHIFT_MASK | GDK_ALT_MASK |
                                            GDK_SUPER_MASK | GDK_HYPER_MASK | GDK_META_MASK);
    if (relevant != GDK_CONTROL_MASK || keyval < GDK_KEY_0 || keyval > GDK_KEY_9 ||
        !sidebar_shortcuts.configured || !gtk_widget_is_sensitive(GTK_WIDGET(ui.window))) return FALSE;
    for (GtkWidget *focus = focused; focus != NULL; focus = gtk_widget_get_parent(focus)) {
        if (GTK_IS_EDITABLE(focus) || GTK_IS_TEXT_VIEW(focus) || GTK_IS_DROP_DOWN(focus)) return FALSE;
    }
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
        GtkWidget *row = GTK_WIDGET(gtk_list_box_get_row_at_index(ui.sidebar, page));
        if (sidebar_shortcuts.digits[page] == (gint)(keyval - GDK_KEY_0) &&
            gtk_widget_is_sensitive(row) && gtk_widget_get_visible(row)) {
            show_page(page);
            return TRUE;
        }
    }
    return FALSE;
}

/* Ctrl+F and Ctrl+K focus settings search from anywhere in the window. No page
 * binds either (History filters as you type in its own entry), and they run
 * after configured action shortcuts, so a user's own binding still wins. */
static gboolean settings_search_key(guint keyval, GdkModifierType modifiers) {
    GdkModifierType relevant = modifiers & (GDK_CONTROL_MASK | GDK_SHIFT_MASK | GDK_ALT_MASK |
                                            GDK_SUPER_MASK | GDK_HYPER_MASK | GDK_META_MASK);
    guint key = gdk_keyval_to_lower(keyval);
    if (relevant != GDK_CONTROL_MASK || (key != GDK_KEY_f && key != GDK_KEY_k)) return FALSE;
    if (adw_navigation_split_view_get_collapsed(ui.split)) adw_navigation_split_view_set_show_content(ui.split, FALSE);
    jsti_settings_search_focus();
    return TRUE;
}

gboolean cancel_key(guint keyval, GdkModifierType modifiers, GtkWidget *focused, gboolean active) {
    if (keyval != GDK_KEY_Escape || !active || ui.closing || ui.suppress ||
        !gtk_widget_is_sensitive(GTK_WIDGET(ui.window))) return FALSE;
    for (GtkWidget *focus = focused; focus != NULL; focus = gtk_widget_get_parent(focus)) {
        if (GTK_IS_POPOVER(focus) || (GTK_IS_WINDOW(focus) && focus != GTK_WIDGET(ui.window))) return FALSE;
#if ADW_CHECK_VERSION(1, 5, 0)
        if (ADW_IS_DIALOG(focus)) return FALSE;
#endif
    }
    GdkModifierType relevant = modifiers & (GDK_CONTROL_MASK | GDK_SHIFT_MASK | GDK_ALT_MASK |
                                            GDK_SUPER_MASK | GDK_HYPER_MASK | GDK_META_MASK);
    if (!escape_enabled()) {
        if (relevant == 0) ui.cancel_key_held = TRUE;
        return FALSE;
    }
    if (ui.cancel_key_held) return TRUE;
    if (relevant != 0 || (ui.state != JSTI_STATE_RECORDING && ui.state != JSTI_STATE_WORKING)) return FALSE;
    guint64 token = window_escape_token();
    if (token == 0) return FALSE;
    ui.cancel_key_held = TRUE;
    gchar value[32];
    g_snprintf(value, sizeof(value), "%" G_GUINT64_FORMAT, token);
    retire_cleanup_preview();
    emit(JSTI_EVENT_CANCEL, value, 0);
    return TRUE;
}

gboolean cancel_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode,
                                   GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)keycode; (void)data;
    return cancel_key(keyval, modifiers, gtk_window_get_focus(ui.window), gtk_window_is_active(ui.window));
}

gboolean sidebar_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode,
                                    GdkModifierType modifiers, gpointer data) {
    (void)data;
    GtkWidget *focused = gtk_window_get_focus(ui.window);
    if (sidebar_navigate(keyval, modifiers, focused)) return TRUE;
    if (ui.closing || !gtk_window_is_active(ui.window) ||
        !gtk_widget_is_sensitive(GTK_WIDGET(ui.window))) return FALSE;
    if (jsti_action_shortcuts_key(controller, keyval, keycode, modifiers, focused, action_shortcut_run)) return TRUE;
    return settings_search_key(keyval, modifiers);
}

void action_key_released(GtkEventControllerKey *controller, guint keyval, guint keycode,
                                GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)modifiers; (void)data;
    if (keyval == GDK_KEY_Escape) ui.cancel_key_held = FALSE;
    jsti_action_shortcuts_release(keycode);
}

/* GTK hides the focus ring when a key press leaves focus where it was and the ring has already
 * timed out (gtk-keyboard-focus-visible-timeout), so pressing Return on Start Recording with no API key left the button
 * focused with no visible ring. Activating a control from the keyboard keeps its ring visible.
 * This runs in the window's bubble phase, after GTK's capture-phase handler. */
void focus_ring_key_released(GtkEventControllerKey *controller, guint keyval, guint keycode,
                             GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)keycode; (void)modifiers; (void)data;
    if (keyval != GDK_KEY_Return && keyval != GDK_KEY_KP_Enter && keyval != GDK_KEY_ISO_Enter &&
        keyval != GDK_KEY_space && keyval != GDK_KEY_KP_Space) return;
    GtkWidget *focus = gtk_root_get_focus(GTK_ROOT(ui.window));
    if (focus == NULL || GTK_IS_EDITABLE(focus) || GTK_IS_TEXT_VIEW(focus)) return;
    gtk_window_set_focus_visible(ui.window, TRUE);
}

void action_window_active(GObject *object, GParamSpec *spec, gpointer data) {
    (void)spec; (void)data;
    if (!gtk_window_is_active(GTK_WINDOW(object))) {
        ui.cancel_key_held = FALSE;
        jsti_action_shortcuts_reset();
    }
}

static void sidebar_header(GtkListBoxRow *row, GtkListBoxRow *before, gpointer data) {
    (void)before; (void)data;
    gint index = gtk_list_box_row_get_index(row);
    const char *heading = index == JSTI_PAGE_DASHBOARD ? "Speak" : index == JSTI_PAGE_GENERAL ? "Settings" : NULL;
    if (heading == NULL) {
        gtk_list_box_row_set_header(row, NULL);
        return;
    }
    GtkWidget *label = gtk_label_new(heading);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_add_css_class(label, "jsti-sidebar-heading");
    gtk_list_box_row_set_header(row, label);
}

#if !GTK_CHECK_VERSION(4, 18, 0)
/* GTK before 4.18 has no gtk_list_box_set_tab_behavior and GtkListBox cannot be
 * subclassed, so this wrapper gives the sidebar GTK_LIST_TAB_ITEM behaviour: Tab
 * from a row leaves the list and only the arrow keys move between rows. */
typedef struct { GtkWidget parent_instance; } JstiTabItemScope;
typedef struct { GtkWidgetClass parent_class; } JstiTabItemScopeClass;
G_DEFINE_TYPE(JstiTabItemScope, jsti_tab_item_scope, GTK_TYPE_WIDGET)

static gboolean tab_item_scope_focus(GtkWidget *widget, GtkDirectionType direction) {
    if ((direction == GTK_DIR_TAB_FORWARD || direction == GTK_DIR_TAB_BACKWARD) &&
        gtk_widget_get_focus_child(widget) != NULL) return FALSE;
    return GTK_WIDGET_CLASS(jsti_tab_item_scope_parent_class)->focus(widget, direction);
}

static void tab_item_scope_dispose(GObject *object) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(object))) != NULL) gtk_widget_unparent(child);
    G_OBJECT_CLASS(jsti_tab_item_scope_parent_class)->dispose(object);
}

static void jsti_tab_item_scope_class_init(JstiTabItemScopeClass *klass) {
    G_OBJECT_CLASS(klass)->dispose = tab_item_scope_dispose;
    GTK_WIDGET_CLASS(klass)->focus = tab_item_scope_focus;
    gtk_widget_class_set_layout_manager_type(GTK_WIDGET_CLASS(klass), GTK_TYPE_BIN_LAYOUT);
}

static void jsti_tab_item_scope_init(JstiTabItemScope *scope) { (void)scope; }
#endif

/* The sidebar is one Tab stop, as GTK lists are: Tab enters on the shown page's
 * row and leaves the list, and the arrow keys move between rows. */
static GtkWidget *sidebar_tab_item(GtkWidget *scroller) {
#if GTK_CHECK_VERSION(4, 18, 0)
    gtk_list_box_set_tab_behavior(ui.sidebar, GTK_LIST_TAB_ITEM);
    return scroller;
#else
    GtkWidget *scope = g_object_new(jsti_tab_item_scope_get_type(), NULL);
    gtk_widget_set_vexpand(scope, TRUE);
    gtk_widget_set_parent(scroller, scope);
    return scope;
#endif
}

GtkWidget *build_sidebar(void) {
    ui.sidebar = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(ui.sidebar), "navigation-sidebar");
    gtk_widget_add_css_class(GTK_WIDGET(ui.sidebar), "jsti-sidebar");
    gtk_list_box_set_header_func(ui.sidebar, sidebar_header, NULL, NULL);
    for (gint32 page = 0; page < JSTI_PAGE_COUNT; page++) {
        GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
        GtkWidget *image = gtk_image_new_from_icon_name(page_info[page].icon);
        gtk_widget_add_css_class(image, page_info[page].tint);
        gtk_box_append(GTK_BOX(line), image);
        GtkWidget *label = gtk_label_new(page_info[page].title);
        gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_widget_set_hexpand(label, TRUE);
        gtk_box_append(GTK_BOX(line), label);
        GtkWidget *hint = gtk_label_new("");
        gtk_widget_add_css_class(hint, "dim-label");
        gtk_accessible_update_state(GTK_ACCESSIBLE(hint), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);
        sidebar_shortcuts.hints[page] = hint;
        gtk_widget_set_visible(hint, FALSE);
        gtk_box_append(GTK_BOX(line), hint);
        GtkWidget *row = gtk_list_box_row_new();
        gtk_accessible_update_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_LABEL, page_info[page].title, -1);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), line);
        if (page >= JSTI_PAGE_GENERAL) gtk_widget_add_css_class(row, "jsti-settings-row");
        gtk_list_box_append(ui.sidebar, row);
    }
    g_signal_connect(ui.sidebar, "row-selected", G_CALLBACK(on_sidebar), NULL);
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), GTK_WIDGET(ui.sidebar));
    GtkWidget *toolbar = adw_toolbar_view_new();
    GtkWidget *header = adw_header_bar_new();
    GtkWidget *brand = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(brand), jsti_brand_icon_new(22));
    GtkWidget *name = gtk_label_new("Just Speak to It");
    gtk_widget_add_css_class(name, "heading");
    gtk_box_append(GTK_BOX(brand), name);
    adw_header_bar_set_title_widget(ADW_HEADER_BAR(header), brand);
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar), header);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), jsti_settings_search_new(sidebar_tab_item(scroller)));
    return toolbar;
}

static void sidebar_update_free(gpointer pointer) {
    SidebarUpdate *update = pointer;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) g_free(update->hints[page]);
    g_free(update);
}

void sidebar_update_apply(gpointer pointer) {
    SidebarUpdate *update = pointer;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
        sidebar_shortcuts.digits[page] = update->digits[page];
        GtkWidget *hint = sidebar_shortcuts.hints[page];
        const gchar *text = update->hints[page] != NULL ? update->hints[page] : "";
        gtk_label_set_text(GTK_LABEL(hint), text);
        gtk_widget_set_visible(hint, update->show_hints && text[0] != '\0');
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(ui.sidebar, page);
        gchar *description = update->show_hints && text[0] != '\0' ? g_strdup_printf("Shortcut: %s.", text) : g_strdup("");
        gtk_accessible_update_property(GTK_ACCESSIBLE(row),
            GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
        g_free(description);
    }
    sidebar_shortcuts.configured = TRUE;
}

int32_t jsti_window_set_sidebar_shortcuts(const JSTISidebarShortcut *bindings, size_t count, int32_t show_hints) {
    if (bindings == NULL || count > 10 || (show_hints != 0 && show_hints != 1)) return -1;
    SidebarUpdate *update = g_new0(SidebarUpdate, 1);
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) update->digits[page] = -1;
    gboolean used[10] = { FALSE };
    for (size_t index = 0; index < count; ++index) {
        const JSTISidebarShortcut *binding = &bindings[index];
        gchar expected[8];
        g_snprintf(expected, sizeof(expected), "Ctrl+%d", binding->digit);
        if (binding->destination == NULL || binding->digit < 0 || binding->digit > 9 ||
            used[binding->digit] || g_strcmp0(binding->hint, expected) != 0) {
            sidebar_update_free(update);
            return -1;
        }
        used[binding->digit] = TRUE;
        for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
            if (g_strcmp0(page_info[page].name, binding->destination) != 0) continue;
            if (update->digits[page] != -1) { sidebar_update_free(update); return -1; }
            update->digits[page] = binding->digit;
            update->hints[page] = g_strdup(binding->hint);
        }
    }
    update->show_hints = show_hints != 0;
    return post(sidebar_update_apply, update, sidebar_update_free);
}
