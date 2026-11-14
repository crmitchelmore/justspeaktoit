/* Command-line window commands forwarded to the running instance. */
#include "LinuxWindowInternal.h"

gboolean parse_window_command(gint argc, const gchar *const *argv, WindowCommand *command) {
    const struct { const gchar *argument; gint run, slot; } actions[] = {
        { JSTI_TOGGLE_ARGUMENT, 1, 0 }, { JSTI_SPEAK_CLIPBOARD_ARGUMENT, 7, 0 },
        { JSTI_PASTE_LAST_HISTORY_ARGUMENT, 11, 0 },
        { JSTI_SPEAK_SELECTED_TEXT_ARGUMENT, 12, 0 },
        { JSTI_EDIT_SELECTION_BY_VOICE_ARGUMENT, 13, 0 },
        { JSTI_STOP_SPEECH_ARGUMENT, 3, 0 }, { JSTI_PAUSE_SPEECH_ARGUMENT, 8, 0 },
        { JSTI_QUICK_VOICE_1_ARGUMENT, 6, 1 }, { JSTI_QUICK_VOICE_2_ARGUMENT, 6, 2 },
        { JSTI_QUICK_VOICE_3_ARGUMENT, 6, 3 }
    };
    *command = (WindowCommand){ 0 };
    for (gint index = 1; index < argc; ++index) {
        gboolean known = g_strcmp0(argv[index], JSTI_LOGIN_LAUNCH_ARGUMENT) == 0;
        if (known) command->background = TRUE;
        for (guint action = 0; action < G_N_ELEMENTS(actions); ++action) {
            if (g_strcmp0(argv[index], actions[action].argument) != 0) continue;
            known = TRUE;
            if (command->run != 0 &&
                (command->run != actions[action].run || command->slot != actions[action].slot)) return FALSE;
            command->run = actions[action].run;
            command->slot = actions[action].slot;
        }
        if (!known) command->unknown_argument = TRUE;
    }
    return TRUE;
}

gboolean is_forwardable_command(gint run, gint slot) {
    if (run == 6) return slot >= 1 && slot <= 3;
    return slot == 0 && (run == 3 || run == 7 || run == 8 || run == 11 || run == 12 || run == 13);
}

gboolean parse_action_command(int argc, const gchar *const *argv, WindowCommand *command) {
    return argc >= 1 && argv != NULL && parse_window_command(argc, argv, command) &&
        command->run != 0 && !command->unknown_argument;
}

int32_t jsti_window_validate_action_command(int argc, char **argv, char *error, size_t capacity) {
    WindowCommand command;
    if (!parse_action_command(argc, (const gchar *const *)argv, &command)) {
        jsti_set_error(error, capacity, "Choose exactly one supported desktop action command.");
        return -1;
    }
    return 0;
}

/* 0 means admitted, not completed; 2 requires the running app, 3 means unavailable now. */
gint forward_window_command(gint run, gint slot, gboolean remote) {
    if (!remote || ui.window == NULL) return 2;
    if (!is_forwardable_command(run, slot)) return 3;
    return action_shortcut_run(run, "", slot) ? 0 : 3;
}

static int reject_local_action(GApplication *application, GApplicationCommandLine *line, gpointer data) {
    (void)application; (void)data;
    g_application_command_line_printerr(line, "Open JustSpeakToIt before using this action command.\n");
    return 2;
}

int32_t jsti_window_forward_action(const char *app_id, int argc, char **argv, char *error, size_t capacity) {
    WindowCommand command;
    if (app_id == NULL || !g_application_id_is_valid(app_id) ||
        !parse_action_command(argc, (const gchar *const *)argv, &command) ||
        !is_forwardable_command(command.run, command.slot)) {
        jsti_set_error(error, capacity, "Choose exactly one supported desktop action command.");
        return -1;
    }
    GApplication *client = g_application_new(app_id, G_APPLICATION_HANDLES_COMMAND_LINE);
    g_signal_connect(client, "command-line", G_CALLBACK(reject_local_action), NULL);
    gint status = g_application_run(client, argc, argv);
    g_object_unref(client);
    if (status != 0) {
        jsti_set_error(error, capacity, "The desktop action was refused (status %d).", status);
        return -1;
    }
    return 0;
}

int on_command_line(GApplication *application, GApplicationCommandLine *line, gpointer data) {
    (void)data;
    gint argc = 0;
    gchar **argv = g_application_command_line_get_arguments(line, &argc);
    WindowCommand command;
    gboolean parsed = parse_window_command(argc, (const gchar *const *)argv, &command);
    g_strfreev(argv);
    if (!parsed) {
        g_application_command_line_printerr(line, "Choose only one action command per invocation.\n");
        return 2;
    }
    if (command.run != 0 && command.unknown_argument) {
        g_application_command_line_printerr(line, "Unsupported option for this desktop action command.\n");
        return 2;
    }
    gboolean remote = g_application_command_line_get_is_remote(line);
    if (command.run != 0 && command.run != 1) {
        gint status = forward_window_command(command.run, command.slot, remote);
        if (status == 2)
            g_application_command_line_printerr(line, "Open JustSpeakToIt before using this action command.\n");
        else if (status != 0 && command.run == 3)
            g_application_command_line_printerr(line, "Playback Stop is unavailable while a dialog is open or the app is closing.\n");
        else if (status != 0)
            g_application_command_line_printerr(line, "Finish the current operation or close dialogs first.\n");
        return status;
    }
    if (!remote || ui.window == NULL) {
        if (ui.window == NULL) ui.start_minimized = command.background && command.run == 0;
        g_application_activate(application);
    }
    /* A remote --toggle drives the running app without raising its window, so
     * focus stays on the field that should receive the text; a second login
     * launch leaves the running app as it is. */
    if (command.run == 1) emit(JSTI_EVENT_COMMAND_TOGGLE, selected_microphone(), selected_model_slot());
    else if (remote && !command.background) gtk_window_present(ui.window);
    return 0;
}
