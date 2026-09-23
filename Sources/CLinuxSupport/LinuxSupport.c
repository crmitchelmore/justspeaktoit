#include "LinuxSupportInternal.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <gio/gio.h>

void jsti_set_error(char *error, size_t capacity, const char *format, ...) {
    if (error == NULL || capacity == 0) return;
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(error, capacity, format, arguments);
    va_end(arguments);
}

void jsti_free(void *pointer) { g_free(pointer); }

/* ------------------------------------------------------------ main invoke */

struct JSTIMainCall {
    GMutex lock;
    GCond changed;
    gboolean done;
    gint references;
    jsti_main_work_fn work;
    gpointer data;
    GDestroyNotify destroy;
};

static void main_call_unref(JSTIMainCall *call) {
    if (!g_atomic_int_dec_and_test(&call->references)) return;
    if (call->destroy != NULL) call->destroy(call->data);
    g_mutex_clear(&call->lock);
    g_cond_clear(&call->changed);
    g_free(call);
}

void jsti_main_call_complete(JSTIMainCall *call) {
    g_mutex_lock(&call->lock);
    call->done = TRUE;
    g_cond_broadcast(&call->changed);
    g_mutex_unlock(&call->lock);
    main_call_unref(call);
}

static gboolean main_call_run(gpointer pointer) {
    JSTIMainCall *call = pointer;
    call->work(call, call->data);
    return G_SOURCE_REMOVE;
}

gboolean jsti_main_invoke_sync(jsti_main_work_fn work, gpointer data, GDestroyNotify destroy, guint timeout_ms) {
    if (!jsti_window_loop_running()) {
        if (destroy != NULL) destroy(data);
        return FALSE;
    }
    JSTIMainCall *call = g_new0(JSTIMainCall, 1);
    g_mutex_init(&call->lock);
    g_cond_init(&call->changed);
    call->references = 2; /* the caller and the work */
    call->work = work;
    call->data = data;
    call->destroy = destroy;
    GMainContext *context = g_main_context_default();
    if (g_main_context_is_owner(context)) {
        /* Inline on the GTK thread: asynchronous work cannot complete while
         * this thread waits, so only synchronous work is valid here. */
        work(call, data);
    } else {
        g_main_context_invoke_full(context, G_PRIORITY_HIGH, main_call_run, call, NULL);
    }
    gint64 deadline = g_get_monotonic_time() + (gint64)timeout_ms * G_TIME_SPAN_MILLISECOND;
    g_mutex_lock(&call->lock);
    while (!call->done) {
        if (!g_cond_wait_until(&call->changed, &call->lock, deadline)) break;
    }
    gboolean done = call->done;
    g_mutex_unlock(&call->lock);
    main_call_unref(call);
    return done;
}

/* ------------------------------------------------------------------ files */

static int32_t make_private_directory(const char *path, char *error, size_t capacity) {
    struct stat info;
    if (lstat(path, &info) == 0) {
        if (S_ISLNK(info.st_mode)) {
            jsti_set_error(error, capacity, "Refusing to use a symbolic link as a private folder: %s", path);
            return -1;
        }
        if (!S_ISDIR(info.st_mode)) {
            jsti_set_error(error, capacity, "A file already exists where a private folder is needed: %s", path);
            return -1;
        }
        if (info.st_uid != geteuid()) {
            jsti_set_error(error, capacity, "The private folder belongs to another user: %s", path);
            return -1;
        }
        if ((info.st_mode & 0077) != 0 && chmod(path, 0700) != 0) {
            jsti_set_error(error, capacity, "Could not restrict folder permissions: %s", g_strerror(errno));
            return -1;
        }
        return 0;
    }
    if (errno != ENOENT) {
        jsti_set_error(error, capacity, "Could not inspect %s: %s", path, g_strerror(errno));
        return -1;
    }
    gchar *parent = g_path_get_dirname(path);
    if (g_strcmp0(parent, path) != 0 && g_mkdir_with_parents(parent, 0700) != 0) {
        jsti_set_error(error, capacity, "Could not create %s: %s", parent, g_strerror(errno));
        g_free(parent);
        return -1;
    }
    g_free(parent);
    if (mkdir(path, 0700) != 0 && errno != EEXIST) {
        jsti_set_error(error, capacity, "Could not create %s: %s", path, g_strerror(errno));
        return -1;
    }
    return 0;
}

int32_t jsti_private_directory_prepare(const char *path, char *error, size_t capacity) {
    if (path == NULL || path[0] != '/') {
        jsti_set_error(error, capacity, "A private folder needs an absolute path.");
        return -1;
    }
    if (make_private_directory(path, error, capacity) != 0) return -1;
    /* A racing creator may have made a link or loosened the mode; verify. */
    return make_private_directory(path, error, capacity);
}

int32_t jsti_private_file_create(const char *path, char *error, size_t capacity) {
    if (path == NULL || path[0] != '/') {
        jsti_set_error(error, capacity, "A private file needs an absolute path.");
        return -1;
    }
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        jsti_set_error(error, capacity, "Could not create the private file %s: %s", path, g_strerror(errno));
        return -1;
    }
    close(descriptor);
    return 0;
}

int32_t jsti_open_path(const char *path, char *error, size_t capacity) {
    GError *failure = NULL;
    gchar *uri = g_filename_to_uri(path, NULL, &failure);
    if (uri == NULL || !g_app_info_launch_default_for_uri(uri, NULL, &failure)) {
        jsti_set_error(error, capacity, "%s", failure != NULL ? failure->message : "The file could not be opened.");
        g_clear_error(&failure);
        g_free(uri);
        return -1;
    }
    g_free(uri);
    return 0;
}

/* -------------------------------------------------------------- self-test */

int32_t jsti_native_self_test(char *error, size_t capacity) {
    gchar *root = g_dir_make_tmp("jsti-linux-self-test-XXXXXX", NULL);
    if (root == NULL) {
        jsti_set_error(error, capacity, "Self-test could not create a temporary folder.");
        return -1;
    }
    int32_t result = -1;
    gchar *folder = g_build_filename(root, "Private", "Nested", NULL);
    gchar *file = g_build_filename(folder, "upload.bin", NULL);
    gchar *link = g_build_filename(root, "Link", NULL);
    struct stat info;
    if (jsti_private_directory_prepare(folder, error, capacity) != 0) goto done;
    if (stat(folder, &info) != 0 || (info.st_mode & 0777) != 0700) {
        jsti_set_error(error, capacity, "Self-test: private folder mode is not 0700.");
        goto done;
    }
    if (jsti_private_file_create(file, error, capacity) != 0) goto done;
    if (stat(file, &info) != 0 || (info.st_mode & 0777) != 0600) {
        jsti_set_error(error, capacity, "Self-test: private file mode is not 0600.");
        goto done;
    }
    char ignored[256];
    if (jsti_private_file_create(file, ignored, sizeof ignored) == 0) {
        jsti_set_error(error, capacity, "Self-test: an existing private file was reopened.");
        goto done;
    }
    if (symlink(folder, link) != 0 || jsti_private_directory_prepare(link, ignored, sizeof ignored) == 0) {
        jsti_set_error(error, capacity, "Self-test: a symbolic link was accepted as a private folder.");
        goto done;
    }
    result = 0;
done:
    unlink(link);
    unlink(file);
    rmdir(folder);
    gchar *parent = g_path_get_dirname(folder);
    rmdir(parent);
    g_free(parent);
    rmdir(root);
    g_free(link);
    g_free(file);
    g_free(folder);
    g_free(root);
    return result;
}
