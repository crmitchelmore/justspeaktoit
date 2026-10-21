#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

static GMutex lock;
static jsti_setup_fn callback;
static gpointer context;
static guint64 revision;
static struct {
    GtkWindow *window;
    GtkLabel *title, *progress, *detail, *status;
    GtkWidget *actions, *footer, *back, *next;
    gint32 step;
    gboolean pending, last;
} guide;

uint64_t jsti_setup_revision(void) {
    g_mutex_lock(&lock); guint64 value = revision; g_mutex_unlock(&lock);
    return value;
}
int32_t jsti_setup_configure(jsti_setup_fn fn, void *data) {
    if (fn == NULL || data == NULL) return -1;
    g_mutex_lock(&lock);
    gboolean available = callback == NULL;
    if (available) { callback = fn; context = data; ++revision; }
    g_mutex_unlock(&lock);
    return available ? 0 : -1;
}
void jsti_setup_clear(void) {
    g_mutex_lock(&lock); callback = NULL; context = NULL; ++revision; g_mutex_unlock(&lock);
}
static void invalidate(GtkWindow *window) {
    if (guide.window != window) return;
    memset(&guide, 0, sizeof guide);
    g_mutex_lock(&lock); ++revision; g_mutex_unlock(&lock);
}
static void finalized(gpointer data, GObject *object) { (void)data; invalidate((GtkWindow *)object); }
static gboolean closing(GtkWindow *window, gpointer data) { (void)data; invalidate(window); return FALSE; }
void jsti_setup_close(void) {
    GtkWindow *window = guide.window;
    if (window != NULL) { invalidate(window); gtk_window_destroy(window); }
}
static void request(gint command, const char *action) {
    if (guide.window == NULL || guide.pending) return;
    g_mutex_lock(&lock);
    jsti_setup_fn fn = callback; gpointer data = context; guint64 ticket = ++revision;
    g_mutex_unlock(&lock);
    if (fn == NULL) {
        gtk_label_set_text(guide.status, "Setup is unavailable. Close and reopen the app.");
        return;
    }
    guide.pending = TRUE;
    gtk_widget_set_sensitive(guide.footer, FALSE);
    gtk_widget_set_sensitive(guide.actions, FALSE);
    fn(ticket, command, guide.step, action != NULL ? action : "", data);
}
static void clicked(GtkButton *button, gpointer data) {
    (void)button;
    gint command = GPOINTER_TO_INT(data);
    request(command == 1 && guide.last ? 4 : command, "");
}
static void action_clicked(GtkButton *button, gpointer data) { (void)button; request(5, data); }
static GtkWidget *label(const char *text) {
    GtkWidget *widget = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(widget), 0);
    gtk_label_set_wrap(GTK_LABEL(widget), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(widget), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_max_width_chars(GTK_LABEL(widget), 68);
    return widget;
}
static GtkWidget *button(const char *title, gint command) {
    GtkWidget *widget = gtk_button_new_with_label(title);
    gtk_widget_set_size_request(widget, -1, 44);
    g_signal_connect(widget, "clicked", G_CALLBACK(clicked), GINT_TO_POINTER(command));
    return widget;
}
static gboolean key_pressed(
    GtkEventControllerKey *controller, guint key, guint code, GdkModifierType modifiers, gpointer data
) {
    (void)controller; (void)code; (void)modifiers; (void)data;
    if (key != GDK_KEY_Escape || guide.window == NULL) return FALSE;
    gtk_window_close(guide.window);
    return TRUE;
}
void jsti_setup_open(GtkWindow *owner) {
    if (guide.window != NULL) { gtk_window_present(guide.window); return; }
    guide.window = GTK_WINDOW(adw_window_new());
    guide.step = -1;
    gtk_window_set_title(guide.window, "Set up Just Speak to It");
    gtk_window_set_icon_name(guide.window, gtk_window_get_icon_name(owner));
    gtk_window_set_default_size(guide.window, 620, 520);
    gtk_window_set_transient_for(guide.window, owner);
    gtk_window_set_destroy_with_parent(guide.window, TRUE);
    gtk_window_set_application(guide.window, gtk_window_get_application(owner));
    g_signal_connect(guide.window, "close-request", G_CALLBACK(closing), NULL);
    g_object_weak_ref(G_OBJECT(guide.window), finalized, NULL);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), NULL);
    gtk_widget_add_controller(GTK_WIDGET(guide.window), keys);
    GtkWidget *toolbar = adw_toolbar_view_new();
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar), adw_header_bar_new());
    GtkWidget *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_start(column, 24); gtk_widget_set_margin_end(column, 24);
    gtk_widget_set_margin_top(column, 20); gtk_widget_set_margin_bottom(column, 20);
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    guide.progress = GTK_LABEL(label("Preparing setup..."));
    guide.title = GTK_LABEL(label(""));
    gtk_widget_add_css_class(GTK_WIDGET(guide.title), "title-1");
    guide.detail = GTK_LABEL(label(""));
    guide.status = GTK_LABEL(label(""));
    guide.actions = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_box_append(GTK_BOX(content), GTK_WIDGET(guide.progress));
    gtk_box_append(GTK_BOX(content), GTK_WIDGET(guide.title));
    gtk_box_append(GTK_BOX(content), GTK_WIDGET(guide.detail));
    gtk_box_append(GTK_BOX(content), GTK_WIDGET(guide.status));
    gtk_box_append(GTK_BOX(content), guide.actions);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), content);
    gtk_box_append(GTK_BOX(column), scroll);
    guide.footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    guide.back = button("Back", 2);
    guide.next = button("Next", 1);
    gtk_widget_add_css_class(guide.next, "suggested-action");
    gtk_box_append(GTK_BOX(guide.footer), button("Skip setup", 3));
    gtk_box_append(GTK_BOX(guide.footer), button("Check again", 6));
    gtk_box_append(GTK_BOX(guide.footer), guide.back);
    gtk_box_append(GTK_BOX(guide.footer), guide.next);
    gtk_box_append(GTK_BOX(column), guide.footer);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), column);
    adw_window_set_content(ADW_WINDOW(guide.window), toolbar);
    gtk_window_present(guide.window);
    request(0, "");
}

typedef struct {
    JSTILinuxSetupPage page;
    GPtrArray *actions;
    guint64 revision;
} Page;
static void action_free(gpointer data) {
    JSTILinuxSetupAction *action = data;
    g_free((gpointer)action->title); g_free((gpointer)action->action); g_free(action);
}
static void page_free(gpointer data) {
    Page *page = data;
    g_free((gpointer)page->page.title); g_free((gpointer)page->page.progress);
    g_free((gpointer)page->page.detail); g_free((gpointer)page->page.status);
    g_ptr_array_unref(page->actions); g_free(page);
}
static gboolean valid(const char *text, gsize maximum) {
    return text != NULL && strlen(text) <= maximum && g_utf8_validate(text, -1, NULL);
}
static Page *copy_page(
    const JSTILinuxSetupPage *value, const JSTILinuxSetupAction *actions, gsize count, guint64 ticket
) {
    if (value == NULL || ticket == 0 || value->step < 0 ||
        (value->has_previous != 0 && value->has_previous != 1) || (value->is_last != 0 && value->is_last != 1) ||
        !valid(value->title, 256) || !valid(value->progress, 128) || !valid(value->detail, 8192) ||
        !valid(value->status, 8192) || value->title[0] == '\0' || count > 32 ||
        (count != 0 && actions == NULL)) return NULL;
    Page *page = g_new0(Page, 1);
    page->revision = ticket; page->page = *value;
    page->page.title = g_strdup(value->title); page->page.progress = g_strdup(value->progress);
    page->page.detail = g_strdup(value->detail); page->page.status = g_strdup(value->status);
    page->actions = g_ptr_array_new_with_free_func(action_free);
    for (gsize index = 0; index < count; ++index) {
        if (!valid(actions[index].title, 256) || !valid(actions[index].action, 128) ||
            actions[index].title[0] == '\0' || actions[index].action[0] == '\0') { page_free(page); return NULL; }
        JSTILinuxSetupAction *action = g_new0(JSTILinuxSetupAction, 1);
        action->title = g_strdup(actions[index].title); action->action = g_strdup(actions[index].action);
        g_ptr_array_add(page->actions, action);
    }
    return page;
}
static void apply_page(gpointer data) {
    Page *page = data;
    if (guide.window == NULL || !guide.pending || page->revision != jsti_setup_revision()) return;
    guide.step = page->page.step; guide.last = page->page.is_last; guide.pending = FALSE;
    gtk_label_set_text(guide.title, page->page.title); gtk_label_set_text(guide.progress, page->page.progress);
    gtk_label_set_text(guide.detail, page->page.detail); gtk_label_set_text(guide.status, page->page.status);
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(guide.actions)) != NULL) gtk_box_remove(GTK_BOX(guide.actions), child);
    for (guint index = 0; index < page->actions->len; ++index) {
        JSTILinuxSetupAction *action = g_ptr_array_index(page->actions, index);
        GtkWidget *widget = gtk_button_new_with_label(action->title);
        gtk_widget_set_size_request(widget, -1, 44);
        g_object_set_data_full(G_OBJECT(widget), "jsti-setup-action", g_strdup(action->action), g_free);
        g_signal_connect(widget, "clicked", G_CALLBACK(action_clicked),
            g_object_get_data(G_OBJECT(widget), "jsti-setup-action"));
        gtk_box_append(GTK_BOX(guide.actions), widget);
    }
    gtk_widget_set_sensitive(guide.footer, TRUE); gtk_widget_set_sensitive(guide.actions, TRUE);
    gtk_widget_set_sensitive(guide.back, page->page.has_previous);
    gtk_button_set_label(GTK_BUTTON(guide.next), guide.last ? "Finish" : "Next");
}
int32_t jsti_setup_set_page(
    const JSTILinuxSetupPage *value, const JSTILinuxSetupAction *actions, size_t count, uint64_t ticket
) {
    Page *page = copy_page(value, actions, count, ticket);
    return page != NULL ? jsti_window_post(apply_page, page, page_free) : -1;
}
static void finish_apply(gpointer data) {
    if (guide.pending && *(guint64 *)data == jsti_setup_revision()) jsti_setup_close();
}
int32_t jsti_setup_finish(uint64_t ticket) {
    if (ticket == 0) return -1;
    guint64 *owned = g_new(guint64, 1); *owned = ticket;
    return jsti_window_post(finish_apply, owned, g_free);
}

typedef struct { guint calls; gint32 command, step; char action[64]; } SetupFixture;
static void fixture_event(uint64_t ticket, int32_t command, int32_t step, const char *action, void *data) {
    (void)ticket;
    SetupFixture *fixture = data;
    ++fixture->calls; fixture->command = command; fixture->step = step;
    g_strlcpy(fixture->action, action, sizeof fixture->action);
}
int32_t jsti_setup_self_test(GtkWindow *owner, char *error, size_t capacity) {
    if (guide.window != NULL) {
        g_strlcpy(error, "Setup self-test requires no active guide", capacity); return -1;
    }
    SetupFixture fixture = {0};
    g_mutex_lock(&lock);
    jsti_setup_fn saved_callback = callback; gpointer saved_context = context;
    callback = fixture_event; context = &fixture; ++revision;
    g_mutex_unlock(&lock);
    jsti_setup_open(owner);
    guint64 opened = jsti_setup_revision();
    gboolean ok = fixture.calls == 1 && fixture.command == 0 && fixture.step == -1 && guide.pending &&
        !gtk_window_get_modal(guide.window) && gtk_window_get_transient_for(guide.window) == owner &&
        g_strcmp0(gtk_window_get_icon_name(guide.window), gtk_window_get_icon_name(owner)) == 0 &&
        !gtk_widget_get_sensitive(guide.footer) && !gtk_widget_get_sensitive(guide.actions);
    char title[] = "Fixture title", progress[] = "Fixture progress", detail[] = "Fixture detail";
    char status[] = "Fixture status", action_title[] = "Fixture action", action_id[] = "fixture-action";
    JSTILinuxSetupPage value = {2, 1, 0, title, progress, detail, status};
    JSTILinuxSetupAction action = {action_title, action_id};
    Page *page = copy_page(&value, &action, 1, opened);
    if (page != NULL) {
        title[0] = progress[0] = detail[0] = status[0] = action_title[0] = action_id[0] = 'X';
        apply_page(page);
        GtkWidget *first = gtk_widget_get_first_child(guide.actions);
        ok = ok && !guide.pending && guide.step == 2 && gtk_widget_get_sensitive(guide.back) &&
            strcmp(gtk_button_get_label(GTK_BUTTON(guide.next)), "Next") == 0 &&
            strcmp(gtk_label_get_text(guide.title), "Fixture title") == 0 &&
            strcmp(gtk_label_get_text(guide.progress), "Fixture progress") == 0 &&
            strcmp(gtk_label_get_text(guide.detail), "Fixture detail") == 0 &&
            strcmp(gtk_label_get_text(guide.status), "Fixture status") == 0 && first != NULL;
        page->page.step = 5;
        apply_page(page);
        finish_apply(&opened);
        ok = ok && guide.window != NULL && guide.step == 2;
        page->page.step = 2;
        if (first != NULL) {
            ok = ok && strcmp(gtk_button_get_label(GTK_BUTTON(first)), "Fixture action") == 0;
            g_signal_emit_by_name(first, "clicked");
            ok = ok && fixture.calls == 2 && fixture.command == 5 && fixture.step == 2 &&
                strcmp(fixture.action, "fixture-action") == 0 && guide.pending;
        }
        request(6, "");
        apply_page(page);
        ok = ok && fixture.calls == 2 && guide.pending;
        page_free(page);
    } else { ok = FALSE; }
    value.is_last = 2;
    ok = ok && jsti_setup_set_page(&value, &action, 1, jsti_setup_revision()) == -1;
    value.is_last = 1; value.has_previous = 0;
    page = copy_page(&value, NULL, 0, jsti_setup_revision());
    if (page != NULL) {
        apply_page(page); page_free(page);
        ok = ok && !gtk_widget_get_sensitive(guide.back) &&
            strcmp(gtk_button_get_label(GTK_BUTTON(guide.next)), "Finish") == 0;
        clicked(GTK_BUTTON(guide.next), GINT_TO_POINTER(1));
        ok = ok && fixture.calls == 3 && fixture.command == 4 && guide.pending;
    } else { ok = FALSE; }
    guint64 before_close = jsti_setup_revision();
    jsti_setup_close();
    ok = ok && guide.window == NULL && jsti_setup_revision() != before_close;
    jsti_setup_open(owner);
    GtkWindow *reopened = guide.window;
    finish_apply(&before_close);
    ok = ok && guide.window == reopened && guide.pending;
    page = copy_page(&value, NULL, 0, before_close);
    if (page != NULL) { apply_page(page); page_free(page); }
    ok = ok && guide.pending && guide.step == -1;
    guint64 current = jsti_setup_revision();
    finish_apply(&current);
    ok = ok && guide.window == NULL;
    jsti_setup_open(owner);
    ok = key_pressed(NULL, GDK_KEY_Escape, 0, 0, NULL) && ok && guide.window == NULL;
    jsti_setup_close();
    g_mutex_lock(&lock); callback = saved_callback; context = saved_context; ++revision; g_mutex_unlock(&lock);
    if (!ok) { g_strlcpy(error, "Setup revision, owned page, navigation or close fixture failed", capacity); return -1; }
    return 0;
}
