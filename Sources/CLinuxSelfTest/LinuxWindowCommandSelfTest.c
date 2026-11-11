/* Self-tests for sidebar navigation, action shortcuts and command forwarding. */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowDashboardState.h"
#include "../CLinuxSupport/LinuxWindowHistoryState.h"
#include "../CLinuxSupport/LinuxWindowNavigationState.h"
#include "../CLinuxSupport/LinuxWindowVoiceState.h"

gboolean sidebar_navigation_self_test(void) {
    SidebarUpdate saved = { 0 }, fixture = { 0 };
    const gint original_page = ui.page;
    const gboolean configured = sidebar_shortcuts_state()->configured;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) {
        saved.digits[page] = sidebar_shortcuts_state()->digits[page];
        saved.hints[page] = g_strdup(gtk_label_get_text(GTK_LABEL(sidebar_shortcuts_state()->hints[page])));
        fixture.digits[page] = -1;
    }
    saved.show_hints = gtk_widget_get_visible(sidebar_shortcuts_state()->hints[JSTI_PAGE_DASHBOARD]);
    fixture.digits[JSTI_PAGE_DASHBOARD] = 1;
    fixture.hints[JSTI_PAGE_DASHBOARD] = (gchar *)"Ctrl+1";
    fixture.digits[JSTI_PAGE_PROFILES] = 9;
    fixture.hints[JSTI_PAGE_PROFILES] = (gchar *)"Ctrl+9";
    fixture.show_hints = TRUE;
    sidebar_update_apply(&fixture);
    GtkWidget *hint = sidebar_shortcuts_state()->hints[JSTI_PAGE_DASHBOARD];
    gboolean okay = gtk_widget_get_visible(hint) &&
        g_strcmp0(gtk_label_get_text(GTK_LABEL(hint)), "Ctrl+1") == 0;
    show_page(JSTI_PAGE_HISTORY);
    okay = okay && sidebar_navigate(GDK_KEY_9, GDK_CONTROL_MASK, NULL) && ui.page == JSTI_PAGE_PROFILES;
    show_page(JSTI_PAGE_HISTORY);
    const GdkModifierType blocked[] = { 0, GDK_CONTROL_MASK | GDK_SHIFT_MASK, GDK_CONTROL_MASK | GDK_ALT_MASK,
                                       GDK_CONTROL_MASK | GDK_SUPER_MASK };
    for (guint i = 0; i < G_N_ELEMENTS(blocked); ++i)
        okay = okay && !sidebar_navigate(GDK_KEY_1, blocked[i], NULL) && ui.page == JSTI_PAGE_HISTORY;
    GtkWidget *entry = gtk_entry_new();
    g_object_ref_sink(entry);
    okay = okay && !sidebar_navigate(GDK_KEY_1, GDK_CONTROL_MASK, entry) && ui.page == JSTI_PAGE_HISTORY;
    g_object_unref(entry);
    okay = okay && !sidebar_navigate(GDK_KEY_1, GDK_CONTROL_MASK, GTK_WIDGET(history_page()->transcript));
    GtkWidget *row = GTK_WIDGET(gtk_list_box_get_row_at_index(ui.sidebar, JSTI_PAGE_DASHBOARD));
    gtk_widget_set_sensitive(row, FALSE);
    okay = okay && !sidebar_navigate(GDK_KEY_1, GDK_CONTROL_MASK, NULL) && ui.page == JSTI_PAGE_HISTORY;
    gtk_widget_set_sensitive(row, TRUE);
    fixture.show_hints = FALSE;
    sidebar_update_apply(&fixture);
    okay = okay && !gtk_widget_get_visible(hint) &&
        sidebar_navigate(GDK_KEY_1, GDK_CONTROL_MASK, NULL) && ui.page == JSTI_PAGE_DASHBOARD;
    const JSTISidebarShortcut invalid[] = { { "dashboard", 1, "Ctrl+1" }, { "history", 1, "Ctrl+1" } };
    okay = okay && jsti_window_set_sidebar_shortcuts(invalid, 2, 1) == -1;
    sidebar_update_apply(&saved);
    sidebar_shortcuts_state()->configured = configured;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page) g_free(saved.hints[page]);
    show_page(original_page);
    return okay;
}

typedef struct ActionShortcutCapture {
    gint32 event, slot;
    guint calls;
} ActionShortcutCapture;

static void action_shortcut_capture(gint32 event, const char *text, gint32 slot, void *context) {
    (void)text;
    ActionShortcutCapture *capture = context;
    capture->event = event;
    capture->slot = slot;
    ++capture->calls;
}

gboolean action_execution_self_test(void) {
    jsti_window_event_fn callback = ui.callback;
    void *context = ui.context;
    gint original_page = ui.page, original_state = ui.state;
    gboolean window_sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.window));
    gboolean record_sensitive = gtk_widget_get_sensitive(GTK_WIDGET(dashboard_page()->record));
    gboolean stop_sensitive = gtk_widget_get_sensitive(GTK_WIDGET(voice_page()->voice_stop));
    ActionShortcutCapture capture = { 0 };
    ui.callback = action_shortcut_capture;
    ui.context = &capture;
    gboolean okay = TRUE;
    for (gint page = 0; page < JSTI_PAGE_COUNT; ++page)
        okay = okay && action_shortcut_run(2, page_name(page), 0) && ui.page == page;
    GtkWidget *history = GTK_WIDGET(gtk_list_box_get_row_at_index(ui.sidebar, JSTI_PAGE_HISTORY));
    gboolean history_sensitive = gtk_widget_get_sensitive(history);
    gtk_widget_set_sensitive(history, FALSE);
    okay = okay && !action_shortcut_run(2, "history", 0);
    gtk_widget_set_sensitive(history, history_sensitive);
    capture.calls = 0;
    gtk_widget_set_sensitive(GTK_WIDGET(dashboard_page()->record), TRUE);
    okay = okay && action_shortcut_run(1, "", 0) && capture.calls == 1 &&
        capture.event == JSTI_EVENT_TOGGLE_RECORDING;
    gtk_widget_set_sensitive(GTK_WIDGET(dashboard_page()->record), FALSE);
    okay = okay && !action_shortcut_run(1, "", 0) && capture.calls == 1;
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_stop), TRUE);
    okay = okay && action_shortcut_run(3, "", 0) && capture.calls == 2 &&
        capture.event == JSTI_EVENT_PLAYBACK_STOP;
    ui.state = JSTI_STATE_IDLE;
    for (gint slot = 1; slot <= 3; ++slot)
        okay = okay && action_shortcut_run(6, "", slot) && capture.event == JSTI_EVENT_QUICK_VOICE &&
            capture.slot == slot && capture.calls == (guint)(2 + slot);
    okay = okay && !action_shortcut_run(6, "", 0) && !action_shortcut_run(6, "", 4);
    okay = okay && action_shortcut_run(7, "", 0) && capture.event == JSTI_EVENT_SPEAK_CLIPBOARD &&
        capture.slot == 0 && capture.calls == 6;
    okay = okay && action_shortcut_run(8, "", 0) && capture.event == JSTI_EVENT_SPEECH_PAUSE &&
        capture.slot == 0 && capture.calls == 7;
    okay = okay && action_shortcut_run(9, "", 0) && capture.event == JSTI_EVENT_API_KEYS &&
        capture.slot == 0 && capture.calls == 8;
    okay = okay && action_shortcut_run(10, "", 0) && capture.event == JSTI_EVENT_PERMISSIONS &&
        capture.slot == 0 && capture.calls == 9;
    gint paste_page = ui.page;
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_stop), FALSE);
    gtk_widget_set_sensitive(history, FALSE);
    okay = okay && action_shortcut_run(11, "", 0) && capture.event == JSTI_EVENT_PASTE_LAST_HISTORY &&
        capture.slot == 0 && capture.calls == 10 && ui.page == paste_page;
    gtk_widget_set_sensitive(history, history_sensitive);
    okay = okay && action_shortcut_run(12, "", 0) && capture.event == JSTI_EVENT_SPEAK_SELECTED_TEXT &&
        capture.slot == 0 && capture.calls == 11;
    ui.state = JSTI_STATE_WORKING;
    okay = okay && !action_shortcut_run(6, "", 1) && !action_shortcut_run(5, "", 0) &&
        !action_shortcut_run(7, "", 0) && !action_shortcut_run(8, "", 0) &&
        !action_shortcut_run(9, "", 0) && !action_shortcut_run(11, "", 0) &&
        !action_shortcut_run(12, "", 0) && capture.calls == 11;
    ui.state = JSTI_STATE_RECORDING;
    okay = okay && !action_shortcut_run(11, "", 0) && !action_shortcut_run(12, "", 0) && capture.calls == 11;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), FALSE);
    ui.state = JSTI_STATE_IDLE;
    okay = okay && !action_shortcut_run(4, "", 0) && !action_shortcut_run(2, "about", 0) &&
        !action_shortcut_run(7, "", 0) && !action_shortcut_run(8, "", 0) &&
        !action_shortcut_run(9, "", 0) && !action_shortcut_run(10, "", 0) &&
        !action_shortcut_run(11, "", 0) && !action_shortcut_run(12, "", 0) && capture.calls == 11;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), window_sensitive);
    gtk_widget_set_sensitive(GTK_WIDGET(dashboard_page()->record), record_sensitive);
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_stop), stop_sensitive);
    ui.state = original_state;
    show_page(original_page);
    ui.callback = callback;
    ui.context = context;
    return okay;
}

static guint command_wait_milliseconds(gint64 remaining) {
    if (remaining <= 0) return 0;
    return (guint)((MIN(remaining, 15 * G_TIME_SPAN_SECOND) + 999) / 1000);
}

gboolean command_forwarding_self_test(void) {
    WindowCommand command;
    const gchar *background[] = { "justspeaktoit", JSTI_LOGIN_LAUNCH_ARGUMENT };
    const gchar *toggle[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, JSTI_LOGIN_LAUNCH_ARGUMENT };
    const gchar *clipboard[] = { "justspeaktoit", JSTI_SPEAK_CLIPBOARD_ARGUMENT };
    const gchar *paste[] = { "justspeaktoit", JSTI_PASTE_LAST_HISTORY_ARGUMENT, JSTI_PASTE_LAST_HISTORY_ARGUMENT };
    const gchar *mixed[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, JSTI_SPEAK_CLIPBOARD_ARGUMENT };
    const gchar *mixed_output[] = { "justspeaktoit", JSTI_PASTE_LAST_HISTORY_ARGUMENT, JSTI_SPEAK_CLIPBOARD_ARGUMENT };
    const gchar *unknown[] = { "justspeaktoit", JSTI_SPEAK_CLIPBOARD_ARGUMENT, "--gapplication-service" };
    const struct { const gchar *argument; gint run, slot, event; } controls[] = {
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, 12, 0, JSTI_EVENT_SPEAK_SELECTED_TEXT },
        { JSTI_STOP_SPEECH_ARGUMENT, 3, 0, JSTI_EVENT_PLAYBACK_STOP },
        { JSTI_PAUSE_SPEECH_ARGUMENT, 8, 0, JSTI_EVENT_SPEECH_PAUSE },
        { JSTI_QUICK_VOICE_1_ARGUMENT, 6, 1, JSTI_EVENT_QUICK_VOICE },
        { JSTI_QUICK_VOICE_2_ARGUMENT, 6, 2, JSTI_EVENT_QUICK_VOICE },
        { JSTI_QUICK_VOICE_3_ARGUMENT, 6, 3, JSTI_EVENT_QUICK_VOICE }
    };
    gboolean okay = command_wait_milliseconds(-1) == 0 && command_wait_milliseconds(0) == 0 &&
        command_wait_milliseconds(1) == 1 && command_wait_milliseconds(15001) == 16 &&
        command_wait_milliseconds(15 * G_TIME_SPAN_SECOND) == 15000 &&
        command_wait_milliseconds(G_MAXINT64) == 15000 &&
        parse_window_command(2, background, &command) && command.run == 0 && command.background;
    okay = okay && parse_window_command(3, toggle, &command) && command.run == 1 && command.background;
    okay = okay && parse_window_command(2, clipboard, &command) && command.run == 7 && !command.background;
    okay = okay && parse_window_command(3, paste, &command) && command.run == 11;
    okay = okay && !parse_window_command(3, mixed, &command) && !parse_window_command(3, mixed_output, &command);
    okay = okay && parse_window_command(3, unknown, &command) && command.unknown_argument;
    const gchar *toggle_unknown[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, "--typo" };
    okay = okay && parse_window_command(3, toggle_unknown, &command) && command.run == 1 &&
        command.unknown_argument && !parse_action_command(3, toggle_unknown, &command) &&
        parse_action_command(3, toggle, &command) && command.run == 1 && command.background &&
        !parse_action_command(2, background, &command) && !parse_action_command(0, NULL, &command);
    for (guint index = 0; index < G_N_ELEMENTS(controls); ++index) {
        const gchar *arguments[] = { "justspeaktoit", controls[index].argument };
        okay = okay && parse_window_command(2, arguments, &command) &&
            command.run == controls[index].run && command.slot == controls[index].slot &&
            is_forwardable_command(command.run, command.slot);
    }
    const gchar *mixed_slots[] = { "justspeaktoit", JSTI_QUICK_VOICE_1_ARGUMENT, JSTI_QUICK_VOICE_2_ARGUMENT };
    okay = okay && !parse_window_command(3, mixed_slots, &command) && !is_forwardable_command(6, 0) &&
        !is_forwardable_command(6, 4) && !is_forwardable_command(1, 0) && !is_forwardable_command(3, 1);
    char *invalid[] = { "justspeaktoit", JSTI_SPEAK_CLIPBOARD_ARGUMENT, "--gapplication-service", NULL };
    char error[256] = { 0 };
    char *valid_toggle[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, JSTI_LOGIN_LAUNCH_ARGUMENT, NULL };
    char *repeated_toggle[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, JSTI_TOGGLE_ARGUMENT, NULL };
    char *invalid_toggle[] = { "justspeaktoit", JSTI_TOGGLE_ARGUMENT, "--gapplication-service", NULL };
    okay = okay && jsti_window_validate_action_command(3, valid_toggle, error, sizeof(error)) == 0 &&
        jsti_window_validate_action_command(3, repeated_toggle, error, sizeof(error)) == 0 &&
        jsti_window_validate_action_command(3, invalid_toggle, error, sizeof(error)) == -1 && error[0] != '\0';
    okay = okay && jsti_window_forward_action(
        "com.justspeaktoit.JustSpeakToIt", 3, invalid, error, sizeof(error)) == -1 && error[0] != '\0';
    jsti_window_event_fn callback = ui.callback;
    void *context = ui.context;
    gint state = ui.state, page = ui.page;
    gboolean sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.window)), closing = ui.closing;
    gboolean stop_sensitive = gtk_widget_get_sensitive(GTK_WIDGET(voice_page()->voice_stop));
    GtkWindow *window = ui.window;
    ActionShortcutCapture capture = { 0 };
    ui.callback = action_shortcut_capture;
    ui.context = &capture;
    ui.state = JSTI_STATE_IDLE;
    ui.closing = FALSE;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
    okay = okay && forward_window_command(7, 0, TRUE) == 0 && capture.event == JSTI_EVENT_SPEAK_CLIPBOARD &&
        capture.calls == 1 && ui.page == page;
    okay = okay && forward_window_command(11, 0, TRUE) == 0 && capture.event == JSTI_EVENT_PASTE_LAST_HISTORY &&
        capture.calls == 2 && ui.page == page;
    okay = okay && forward_window_command(7, 0, FALSE) == 2 && forward_window_command(11, 0, FALSE) == 2;
    ui.window = NULL;
    okay = okay && forward_window_command(7, 0, TRUE) == 2 && forward_window_command(11, 0, TRUE) == 2;
    ui.window = window;
    ui.state = JSTI_STATE_WORKING;
    okay = okay && forward_window_command(7, 0, TRUE) == 3 && forward_window_command(11, 0, TRUE) == 3;
    ui.state = JSTI_STATE_RECORDING;
    okay = okay && forward_window_command(7, 0, TRUE) == 3 && forward_window_command(11, 0, TRUE) == 3;
    ui.state = JSTI_STATE_IDLE;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), FALSE);
    okay = okay && forward_window_command(7, 0, TRUE) == 3 && forward_window_command(11, 0, TRUE) == 3;
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
    ui.closing = TRUE;
    okay = okay && forward_window_command(7, 0, TRUE) == 3 && forward_window_command(11, 0, TRUE) == 3 &&
        capture.calls == 2;
    ui.closing = FALSE;
    ui.state = JSTI_STATE_IDLE;
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_stop), TRUE);
    for (guint index = 0; index < G_N_ELEMENTS(controls); ++index) {
        capture = (ActionShortcutCapture){ 0 };
        gint run = controls[index].run, slot = controls[index].slot;
        okay = okay && forward_window_command(run, slot, TRUE) == 0 &&
            capture.calls == 1 && capture.event == controls[index].event &&
            capture.slot == slot && ui.page == page && forward_window_command(run, slot, FALSE) == 2;
        gtk_widget_set_sensitive(GTK_WIDGET(ui.window), FALSE);
        okay = okay && forward_window_command(run, slot, TRUE) == 3 && capture.calls == 1;
        gtk_widget_set_sensitive(GTK_WIDGET(ui.window), TRUE);
        ui.closing = TRUE;
        okay = okay && forward_window_command(run, slot, TRUE) == 3 && capture.calls == 1;
        ui.closing = FALSE;
        if (run != 3) {
            ui.state = JSTI_STATE_WORKING;
            okay = okay && forward_window_command(run, slot, TRUE) == 3 && capture.calls == 1;
            ui.state = JSTI_STATE_RECORDING;
            okay = okay && forward_window_command(run, slot, TRUE) == 3 && capture.calls == 1;
            ui.state = JSTI_STATE_IDLE;
        }
    }
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_stop), FALSE);
    okay = okay && forward_window_command(3, 0, TRUE) == 3;
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_stop), stop_sensitive);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), sensitive);
    ui.closing = closing;
    ui.state = state;
    ui.callback = callback;
    ui.context = context;
    return okay;
}

typedef struct CommandProcessResult {
    GMainLoop *loop;
    GSubprocess *child;
    gboolean completed, timed_out;
    gchar *diagnostic;
    GError *failure;
} CommandProcessResult;

static void command_process_finished(GObject *object, GAsyncResult *result, gpointer data) {
    CommandProcessResult *check = data;
    check->completed = g_subprocess_communicate_utf8_finish(
        G_SUBPROCESS(object), result, NULL, &check->diagnostic, &check->failure);
    g_main_loop_quit(check->loop);
}

static gboolean command_process_expired(gpointer data) {
    CommandProcessResult *check = data;
    check->timed_out = TRUE;
    g_subprocess_force_exit(check->child);
    return G_SOURCE_REMOVE;
}

static gboolean check_command_process(
    const gchar *const *arguments, const gchar *directory, gboolean success,
    const gchar *refusal, gint64 group_deadline, char *error, size_t capacity
) {
    if (g_get_monotonic_time() >= group_deadline) {
        jsti_set_error(error, capacity, "The shared command-client fixture budget expired before %s.", arguments[1]);
        return FALSE;
    }
    GSubprocessLauncher *launcher = g_subprocess_launcher_new(
        G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_PIPE);
    g_subprocess_launcher_setenv(launcher, "XDG_DATA_HOME", directory, TRUE);
    CommandProcessResult check = { 0 };
    check.child = g_subprocess_launcher_spawnv(launcher, arguments, &check.failure);
    g_object_unref(launcher);
    if (check.child == NULL) {
        jsti_set_error(error, capacity, "Could not start the command client: %s", check.failure->message);
        g_clear_error(&check.failure);
        return FALSE;
    }
    GMainContext *context = g_main_context_get_thread_default();
    check.loop = g_main_loop_new(context, FALSE);
    GSource *deadline = g_timeout_source_new(command_wait_milliseconds(group_deadline - g_get_monotonic_time()));
    g_source_set_callback(deadline, command_process_expired, &check, NULL);
    g_source_attach(deadline, context);
    g_subprocess_communicate_utf8_async(check.child, NULL, NULL, command_process_finished, &check);
    g_main_loop_run(check.loop);
    g_source_destroy(deadline);
    g_source_unref(deadline);
    if (!check.completed) {
        g_subprocess_force_exit(check.child);
        g_subprocess_wait(check.child, NULL, NULL);
    }
    const gboolean group_expired = g_get_monotonic_time() >= group_deadline;
    gboolean okay = check.completed && !check.timed_out && !group_expired && g_subprocess_get_if_exited(check.child) &&
        g_subprocess_get_successful(check.child) == success &&
        (refusal == NULL || (check.diagnostic != NULL && strstr(check.diagnostic, refusal) != NULL));
    if (!okay) jsti_set_error(error, capacity, "Command %s failed its process contract: %s%s",
        arguments[1], group_expired ? "shared command-client budget expired; " : check.timed_out ? "timed out; " : "",
        check.failure != NULL ? check.failure->message :
            (check.diagnostic != NULL ? check.diagnostic : "unexpected process status"));
    g_clear_error(&check.failure);
    g_free(check.diagnostic);
    g_main_loop_unref(check.loop);
    g_object_unref(check.child);
    return okay;
}

gboolean command_process_self_test(char *error, size_t capacity) {
    /* Opt in only from the harness's private session bus. No provider/Host event
     * is delivered: a private context serves the real handler with a test callback. */
    if (g_strcmp0(g_getenv("JSTI_COMMAND_FORWARDING_CHECK"), "1") != 0) return TRUE;
    if (!(ui.flags & JSTI_WINDOW_SMOKE_TEST)) {
        jsti_set_error(error, capacity, "Command process checks require the isolated smoke-test window.");
        return FALSE;
    }
    GMainContext *context = g_main_context_new();
    g_main_context_push_thread_default(context);
    GApplication *primary = g_application_new(
        "com.justspeaktoit.JustSpeakToIt", G_APPLICATION_HANDLES_COMMAND_LINE);
    g_signal_connect(primary, "command-line", G_CALLBACK(on_command_line), NULL);
    GError *failure = NULL;
    gboolean okay = g_application_register(primary, NULL, &failure);
    if (!okay || g_application_get_is_remote(primary)) {
        jsti_set_error(error, capacity, "Command fixture could not own its private application name: %s",
            failure != NULL ? failure->message : "another instance is running");
        g_clear_error(&failure);
        g_object_unref(primary);
        g_main_context_pop_thread_default(context);
        g_main_context_unref(context);
        return FALSE;
    }
    gchar *executable = g_file_read_link("/proc/self/exe", &failure);
    gchar *directory = executable != NULL ? g_dir_make_tmp("jsti-command-check-XXXXXX", &failure) : NULL;
    if (directory == NULL) {
        jsti_set_error(error, capacity, "Command fixture setup failed: %s", failure->message);
        g_clear_error(&failure);
        g_free(executable);
        g_object_unref(primary);
        g_main_context_pop_thread_default(context);
        g_main_context_unref(context);
        return FALSE;
    }
    jsti_window_event_fn callback = ui.callback;
    void *callback_context = ui.context;
    gint state = ui.state, page = ui.page;
    gboolean closing = ui.closing, sensitive = gtk_widget_get_sensitive(GTK_WIDGET(ui.window));
    gboolean visible = gtk_widget_get_visible(GTK_WIDGET(ui.window));
    gboolean stop_enabled = gtk_widget_get_sensitive(GTK_WIDGET(voice_page()->voice_stop));
    ActionShortcutCapture capture = { 0 };
    ui.callback = action_shortcut_capture;
    ui.context = &capture;
    gtk_widget_set_visible(GTK_WIDGET(ui.window), FALSE);
    const struct {
        const gchar *argument, *second;
        gint state, event, slot;
        gboolean sensitive, closing;
        const gchar *refusal;
    } cases[] = {
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_SPEAK_SELECTED_TEXT, 0, TRUE, FALSE, NULL },
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, JSTI_SPEAK_SELECTED_TEXT_ARGUMENT,
            JSTI_STATE_IDLE, JSTI_EVENT_SPEAK_SELECTED_TEXT, 0, TRUE, FALSE, NULL },
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, "--typo",
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, JSTI_SPEAK_CLIPBOARD_ARGUMENT,
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_SPEAK_CLIPBOARD, 0, TRUE, FALSE, NULL },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_PASTE_LAST_HISTORY, 0, TRUE, FALSE, NULL },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, JSTI_PASTE_LAST_HISTORY_ARGUMENT,
            JSTI_STATE_IDLE, JSTI_EVENT_PASTE_LAST_HISTORY, 0, TRUE, FALSE, NULL },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, JSTI_LOGIN_LAUNCH_ARGUMENT,
            JSTI_STATE_IDLE, JSTI_EVENT_SPEAK_CLIPBOARD, 0, TRUE, FALSE, NULL },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, NULL, JSTI_STATE_WORKING, 0, 0, TRUE, FALSE, "Finish the current operation" },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, NULL, JSTI_STATE_RECORDING, 0, 0, TRUE, FALSE, "Finish the current operation" },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, NULL, JSTI_STATE_IDLE, 0, 0, FALSE, FALSE, "Finish the current operation" },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, NULL, JSTI_STATE_IDLE, 0, 0, TRUE, TRUE, "Finish the current operation" },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, JSTI_PASTE_LAST_HISTORY_ARGUMENT,
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_TOGGLE_ARGUMENT, JSTI_SPEAK_CLIPBOARD_ARGUMENT,
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_SPEAK_CLIPBOARD_ARGUMENT, "--gapplication-service",
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_TOGGLE_ARGUMENT, "--typo",
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_TOGGLE_ARGUMENT, "--gapplication-service",
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_PLAYBACK_STOP, 0, TRUE, FALSE, NULL },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_WORKING, JSTI_EVENT_PLAYBACK_STOP, 0, TRUE, FALSE, NULL },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_RECORDING, JSTI_EVENT_PLAYBACK_STOP, 0, TRUE, FALSE, NULL },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_IDLE, 0, 0, FALSE, FALSE, "Playback Stop is unavailable" },
        { JSTI_STOP_SPEECH_ARGUMENT, NULL, JSTI_STATE_IDLE, 0, 0, TRUE, TRUE, "Playback Stop is unavailable" },
        { JSTI_PAUSE_SPEECH_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_SPEECH_PAUSE, 0, TRUE, FALSE, NULL },
        { JSTI_QUICK_VOICE_1_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_QUICK_VOICE, 1, TRUE, FALSE, NULL },
        { JSTI_QUICK_VOICE_2_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_QUICK_VOICE, 2, TRUE, FALSE, NULL },
        { JSTI_QUICK_VOICE_3_ARGUMENT, NULL, JSTI_STATE_IDLE, JSTI_EVENT_QUICK_VOICE, 3, TRUE, FALSE, NULL },
        { JSTI_QUICK_VOICE_1_ARGUMENT, JSTI_QUICK_VOICE_3_ARGUMENT,
            JSTI_STATE_IDLE, 0, 0, TRUE, FALSE, "Choose exactly one supported desktop action command" },
        { JSTI_QUICK_VOICE_1_ARGUMENT, NULL, JSTI_STATE_WORKING, 0, 0, TRUE, FALSE, "Finish the current operation" },
        { JSTI_PAUSE_SPEECH_ARGUMENT, NULL, JSTI_STATE_RECORDING, 0, 0, TRUE, FALSE, "Finish the current operation" }
    };
    /* Leave most of the 600-second smoke envelope for non-command checks. */
    const gint64 group_deadline = g_get_monotonic_time() + 180 * G_TIME_SPAN_SECOND;
    for (guint index = 0; okay && index < G_N_ELEMENTS(cases); ++index) {
        const gchar *arguments[] = { executable, cases[index].argument, cases[index].second, NULL };
        capture = (ActionShortcutCapture){ 0 };
        ui.state = cases[index].state;
        ui.closing = cases[index].closing;
        gtk_widget_set_sensitive(GTK_WIDGET(ui.window), cases[index].sensitive);
        refresh_actions();
        okay = check_command_process(
            arguments, directory, cases[index].event != 0, cases[index].refusal, group_deadline, error, capacity);
        if (okay && (capture.calls != (cases[index].event != 0 ? 1u : 0u) ||
            capture.event != cases[index].event || capture.slot != cases[index].slot || ui.page != page ||
            gtk_widget_get_visible(GTK_WIDGET(ui.window)))) {
            jsti_set_error(error, capacity, "Command fixture %u changed page/visibility or emitted the wrong event.", index);
            okay = FALSE;
        }
    }
    g_clear_object(&primary);
    const gchar *cold[] = {
        JSTI_SPEAK_SELECTED_TEXT_ARGUMENT,
        JSTI_SPEAK_CLIPBOARD_ARGUMENT, JSTI_PASTE_LAST_HISTORY_ARGUMENT, JSTI_STOP_SPEECH_ARGUMENT,
        JSTI_PAUSE_SPEECH_ARGUMENT, JSTI_QUICK_VOICE_1_ARGUMENT, JSTI_QUICK_VOICE_2_ARGUMENT, JSTI_QUICK_VOICE_3_ARGUMENT
    };
    for (guint index = 0; okay && index < G_N_ELEMENTS(cold); ++index) {
        const gchar *arguments[] = { executable, cold[index], NULL };
        okay = check_command_process(arguments, directory, FALSE,
            "Open JustSpeakToIt before using this action command", group_deadline, error, capacity);
    }
    const gchar *cold_invalid[] = { "--typo", "--gapplication-service" };
    for (guint index = 0; okay && index < G_N_ELEMENTS(cold_invalid); ++index) {
        const gchar *arguments[] = { executable, JSTI_TOGGLE_ARGUMENT, cold_invalid[index], NULL };
        okay = check_command_process(arguments, directory, FALSE,
            "Choose exactly one supported desktop action command", group_deadline, error, capacity);
    }
    ui.state = state;
    ui.closing = closing;
    refresh_actions();
    ui.callback = callback;
    ui.context = callback_context;
    gtk_widget_set_sensitive(GTK_WIDGET(voice_page()->voice_stop), stop_enabled);
    gtk_widget_set_sensitive(GTK_WIDGET(ui.window), sensitive);
    gtk_widget_set_visible(GTK_WIDGET(ui.window), visible);
    GDir *contents = g_dir_open(directory, 0, &failure);
    gboolean empty = contents != NULL && g_dir_read_name(contents) == NULL;
    if (contents != NULL) g_dir_close(contents);
    if (!empty) {
        if (okay) jsti_set_error(
            error, capacity, "Command clients created data in %s or the fixture could not inspect it.", directory);
        g_printerr("Retaining command fixture directory for diagnosis: %s\n", directory);
        okay = FALSE;
    }
    g_clear_error(&failure);
    if (empty && g_rmdir(directory) != 0) {
        if (okay) jsti_set_error(error, capacity, "Could not remove the empty command fixture directory.");
        g_printerr("Could not remove command fixture directory: %s\n", directory);
        okay = FALSE;
    }
    g_free(directory);
    g_free(executable);
    g_main_context_pop_thread_default(context);
    g_main_context_unref(context);
    if (okay) g_print("Desktop commands: %u real client processes passed forwarding, refusal and store-isolation checks.\n",
        (guint)(G_N_ELEMENTS(cases) + G_N_ELEMENTS(cold) + G_N_ELEMENTS(cold_invalid)));
    return okay;
}
