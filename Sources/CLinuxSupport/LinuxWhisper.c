#include "LinuxSupportInternal.h"

/* The whisper.cpp headers vendored for Windows at the same pinned release
 * (see ../CWindowsSupport/whisper-cpp/PROVENANCE.md); one copy serves both. */
#include "../CWindowsSupport/whisper-cpp/whisper.h"
#include "../CWindowsSupport/whisper-cpp/ggml-backend.h"

#include <dlfcn.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * whisper.cpp is loaded at run time with dlopen, never linked, so the app
 * builds and runs without it and a missing runtime only disables on-device
 * models. The struct layouts in the vendored headers are valid for exactly
 * one release, so open refuses any other whisper_version(). Backends (the CPU
 * variants and Vulkan) register from the runtime directory only.
 */

static const char *const expected_version = "1.9.4";

typedef struct Api {
    const char *(*version)(void);
    struct whisper_context_params (*context_defaults)(void);
    struct whisper_context *(*init_with_params)(struct whisper_model_loader *, struct whisper_context_params);
    struct whisper_full_params (*full_defaults)(enum whisper_sampling_strategy);
    int (*full)(struct whisper_context *, struct whisper_full_params, const float *, int);
    int (*segment_count)(struct whisper_context *);
    const char *(*segment_text)(struct whisper_context *, int);
    void (*free)(struct whisper_context *);
    int (*language_id)(const char *);
    void (*log_set)(ggml_log_callback, void *);
    void (*load_backends)(const char *);
    size_t (*device_count)(void);
    ggml_backend_dev_t (*device)(size_t);
    enum ggml_backend_dev_type (*device_type)(ggml_backend_dev_t);
    const char *(*device_name)(ggml_backend_dev_t);
    const char *(*device_description)(ggml_backend_dev_t);
} Api;

struct jsti_whisper_runtime {
    gchar *directory;
    GPtrArray *handles;
    Api api;
    gboolean allow_gpu;
    gboolean has_gpu;
    gchar *description;
    GMutex mutex; /* Serialises model use; whisper_full is not reentrant per context. */
    struct whisper_context *context;
    gchar *context_path;
};

struct jsti_whisper_job {
    atomic_int cancelled;
};

static GMutex open_mutex;
static jsti_whisper_runtime *shared_runtime;

/* Recent log lines explain a failed model load; whisper.cpp logs no audio or
 * decoded text at these levels. */
static GMutex log_mutex;
static gchar *log_lines[8];
static GString *log_partial;

static void log_callback(enum ggml_log_level level, const char *text, void *data) {
    (void)data;
    if (text == NULL || (level != GGML_LOG_LEVEL_ERROR && level != GGML_LOG_LEVEL_WARN && level != GGML_LOG_LEVEL_INFO)) {
        return;
    }
    g_mutex_lock(&log_mutex);
    if (log_partial == NULL) log_partial = g_string_new(NULL);
    g_string_append(log_partial, text);
    gchar *newline;
    while ((newline = strchr(log_partial->str, '\n')) != NULL) {
        gsize length = (gsize)(newline - log_partial->str);
        if (length > 0) {
            g_free(log_lines[0]);
            memmove(log_lines, log_lines + 1, sizeof log_lines - sizeof log_lines[0]);
            log_lines[G_N_ELEMENTS(log_lines) - 1] = g_strndup(log_partial->str, length);
        }
        g_string_erase(log_partial, 0, (gssize)length + 1);
    }
    g_mutex_unlock(&log_mutex);
}

static gchar *last_log_line(void) {
    g_mutex_lock(&log_mutex);
    gchar *found = NULL;
    for (gint index = G_N_ELEMENTS(log_lines) - 1; index >= 0 && found == NULL; index--) {
        if (log_lines[index] != NULL && (strstr(log_lines[index], "error") || strstr(log_lines[index], "failed"))) {
            found = g_strdup(log_lines[index]);
        }
    }
    for (gint index = G_N_ELEMENTS(log_lines) - 1; index >= 0 && found == NULL; index--) {
        if (log_lines[index] != NULL) found = g_strdup(log_lines[index]);
    }
    g_mutex_unlock(&log_mutex);
    return found != NULL ? found : g_strdup("");
}

static void *resolve(GPtrArray *handles, const char *name) {
    for (guint index = 0; index < handles->len; index++) {
        void *address = dlsym(g_ptr_array_index(handles, index), name);
        if (address != NULL) return address;
    }
    return NULL;
}

/* Loads the first existing candidate globally, so libraries loaded later
 * resolve their DT_NEEDED entries to it by soname, whatever their RUNPATH. */
static void *load_first(const char *directory, const char *const *names, gchar **failure) {
    for (const char *const *name = names; *name != NULL; name++) {
        gchar *path = g_build_filename(directory, *name, NULL);
        if (g_file_test(path, G_FILE_TEST_EXISTS)) {
            void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
            if (handle == NULL && failure != NULL && *failure == NULL) *failure = g_strdup(dlerror());
            g_free(path);
            if (handle != NULL) return handle;
            continue;
        }
        g_free(path);
    }
    return NULL;
}

static void describe_devices(jsti_whisper_runtime *runtime) {
    GString *gpus = g_string_new(NULL);
    gboolean cpu = FALSE, gpu = FALSE;
    size_t count = runtime->api.device_count();
    for (size_t index = 0; index < count; index++) {
        ggml_backend_dev_t device = runtime->api.device(index);
        if (device == NULL) continue;
        enum ggml_backend_dev_type type = runtime->api.device_type(device);
        if (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
            const char *name = runtime->api.device_name(device);
            const char *description = runtime->api.device_description(device);
            if (gpus->len > 0) g_string_append(gpus, ", ");
            g_string_append(gpus, name != NULL ? name : "device");
            if (description != NULL && *description != '\0') g_string_append_printf(gpus, " (%s)", description);
            gpu = TRUE;
        } else if (type == GGML_BACKEND_DEVICE_TYPE_CPU) {
            cpu = TRUE;
        }
    }
    runtime->has_gpu = gpu && runtime->allow_gpu;
    GString *description = g_string_new(NULL);
    g_string_printf(description, "whisper.cpp %s", expected_version);
    if (gpus->len > 0) g_string_append_printf(description, runtime->allow_gpu ? "; GPU: %s" : "; GPU off: %s", gpus->str);
    g_string_append(description, cpu ? "; CPU" : "; no CPU backend");
    runtime->description = g_string_free(description, FALSE);
    g_string_free(gpus, TRUE);
}

static void runtime_free(jsti_whisper_runtime *runtime) {
    /* The libraries stay mapped: unloading ggml after partial use is unsafe. */
    g_ptr_array_unref(runtime->handles);
    g_free(runtime->directory);
    g_free(runtime->description);
    g_free(runtime);
}

jsti_whisper_runtime *jsti_whisper_runtime_open(const char *directory, int32_t allow_gpu, char *error, size_t capacity) {
    if (directory == NULL || directory[0] != '/') {
        jsti_set_error(error, capacity, "The speech runtime directory must be an absolute path.");
        return NULL;
    }
    g_mutex_lock(&open_mutex);
    if (shared_runtime != NULL) {
        jsti_whisper_runtime *existing = shared_runtime;
        g_mutex_unlock(&open_mutex);
        if (g_strcmp0(existing->directory, directory) != 0) {
            jsti_set_error(error, capacity, "The speech runtime is already loaded from another directory.");
            return NULL;
        }
        return existing;
    }
    gchar *library = g_build_filename(directory, "libwhisper.so.1", NULL);
    gboolean installed = g_file_test(library, G_FILE_TEST_EXISTS);
    g_free(library);
    if (!installed) {
        g_mutex_unlock(&open_mutex);
        jsti_set_error(error, capacity, "The on-device speech runtime (whisper.cpp) is not installed with this build.");
        return NULL;
    }
    /* Implicit layers (overlays, capture tools) have crashed Vulkan inference
     * in other dictation apps. An explicit user choice is respected. */
    if (allow_gpu && g_getenv("VK_LOADER_LAYERS_DISABLE") == NULL) g_setenv("VK_LOADER_LAYERS_DISABLE", "~implicit~", TRUE);
    jsti_whisper_runtime *runtime = g_new0(jsti_whisper_runtime, 1);
    runtime->directory = g_strdup(directory);
    runtime->handles = g_ptr_array_new();
    runtime->allow_gpu = allow_gpu != 0;
    g_mutex_init(&runtime->mutex);
    gchar *failure = NULL;
    const char *base[] = { "libggml-base.so", "libggml-base.so.0", NULL };
    const char *ggml[] = { "libggml.so", "libggml.so.0", NULL };
    const char *whisper[] = { "libwhisper.so.1", "libwhisper.so", NULL };
    void *handle;
    if ((handle = load_first(directory, base, &failure)) != NULL) g_ptr_array_add(runtime->handles, handle);
    if ((handle = load_first(directory, ggml, &failure)) != NULL) g_ptr_array_add(runtime->handles, handle);
    void *whisper_handle = load_first(directory, whisper, &failure);
    if (whisper_handle == NULL) {
        g_mutex_unlock(&open_mutex);
        jsti_set_error(error, capacity, "Loading the on-device speech runtime failed: %s",
                       failure != NULL ? failure : "libwhisper could not be loaded");
        g_free(failure);
        runtime_free(runtime);
        return NULL;
    }
    g_free(failure);
    g_ptr_array_insert(runtime->handles, 0, whisper_handle);
    Api *api = &runtime->api;
    GPtrArray *handles = runtime->handles;
    api->version = resolve(handles, "whisper_version");
    api->context_defaults = resolve(handles, "whisper_context_default_params");
    api->init_with_params = resolve(handles, "whisper_init_with_params");
    api->full_defaults = resolve(handles, "whisper_full_default_params");
    api->full = resolve(handles, "whisper_full");
    api->segment_count = resolve(handles, "whisper_full_n_segments");
    api->segment_text = resolve(handles, "whisper_full_get_segment_text");
    api->free = resolve(handles, "whisper_free");
    api->language_id = resolve(handles, "whisper_lang_id");
    api->log_set = resolve(handles, "whisper_log_set");
    api->load_backends = resolve(handles, "ggml_backend_load_all_from_path");
    api->device_count = resolve(handles, "ggml_backend_dev_count");
    api->device = resolve(handles, "ggml_backend_dev_get");
    api->device_type = resolve(handles, "ggml_backend_dev_type");
    api->device_name = resolve(handles, "ggml_backend_dev_name");
    api->device_description = resolve(handles, "ggml_backend_dev_description");
    gboolean complete = api->version && api->context_defaults && api->init_with_params && api->full_defaults &&
        api->full && api->segment_count && api->segment_text && api->free && api->language_id && api->log_set &&
        api->load_backends && api->device_count && api->device && api->device_type && api->device_name &&
        api->device_description;
    const char *version = complete ? api->version() : NULL;
    if (version == NULL || strcmp(version, expected_version) != 0) {
        g_mutex_unlock(&open_mutex);
        jsti_set_error(error, capacity, "The on-device speech runtime is whisper.cpp %s; this app needs %s. Reinstall the app.",
                       version != NULL ? version : "with an incomplete API", expected_version);
        runtime_free(runtime);
        return NULL;
    }
    api->log_set(log_callback, NULL);
    /* The best CPU variant and, when a Vulkan loader and driver exist, Vulkan. */
    api->load_backends(directory);
    describe_devices(runtime);
    if (strstr(runtime->description, "; CPU") == NULL) {
        g_mutex_unlock(&open_mutex);
        gchar *detail = last_log_line();
        jsti_set_error(error, capacity, "The on-device speech runtime found no usable CPU backend. %s", detail);
        g_free(detail);
        runtime_free(runtime);
        return NULL;
    }
    shared_runtime = runtime;
    g_mutex_unlock(&open_mutex);
    return runtime;
}

int32_t jsti_whisper_runtime_describe(jsti_whisper_runtime *runtime, char *text, size_t capacity) {
    if (runtime == NULL || text == NULL || capacity == 0) return -1;
    jsti_set_error(text, capacity, "%s", runtime->description);
    return 0;
}

int32_t jsti_whisper_runtime_uses_gpu(jsti_whisper_runtime *runtime) {
    return runtime != NULL && runtime->has_gpu ? 1 : 0;
}

jsti_whisper_job *jsti_whisper_job_create(void) { return g_new0(jsti_whisper_job, 1); }

void jsti_whisper_job_cancel(jsti_whisper_job *job) {
    if (job != NULL) atomic_store(&job->cancelled, 1);
}

void jsti_whisper_job_destroy(jsti_whisper_job *job) { g_free(job); }

void jsti_whisper_free_text(char *text) { free(text); }

static void release_context(jsti_whisper_runtime *runtime) {
    if (runtime->context != NULL) runtime->api.free(runtime->context);
    runtime->context = NULL;
    g_clear_pointer(&runtime->context_path, g_free);
}

void jsti_whisper_runtime_release_model(jsti_whisper_runtime *runtime) {
    if (runtime == NULL) return;
    g_mutex_lock(&runtime->mutex);
    release_context(runtime);
    g_mutex_unlock(&runtime->mutex);
}

/* Checked under the lock transcription loads under, so a model that replaced
 * this one in the cache is never freed in its place. */
int32_t jsti_whisper_runtime_release_model_at(jsti_whisper_runtime *runtime, const char *model_path) {
    if (runtime == NULL || model_path == NULL || model_path[0] == '\0') return -1;
    g_mutex_lock(&runtime->mutex);
    int32_t released = 0;
    if (runtime->context != NULL && g_strcmp0(runtime->context_path, model_path) == 0) {
        release_context(runtime);
        released = 1;
    }
    g_mutex_unlock(&runtime->mutex);
    return released;
}

typedef struct FileLoader { FILE *file; } FileLoader;

static size_t loader_read(void *context, void *output, size_t size) {
    return fread(output, 1, size, ((FileLoader *)context)->file);
}

static bool loader_eof(void *context) { return feof(((FileLoader *)context)->file) != 0; }

static void loader_close(void *context) {
    FileLoader *loader = context;
    if (loader->file != NULL) fclose(loader->file);
    loader->file = NULL;
}

static bool abort_requested(void *data) { return atomic_load(&((jsti_whisper_job *)data)->cancelled) != 0; }

static bool encoder_begin(struct whisper_context *context, struct whisper_state *state, void *data) {
    (void)context; (void)state;
    return !abort_requested(data);
}

int32_t jsti_whisper_transcribe(
    jsti_whisper_runtime *runtime, const char *model_path, const float *samples, size_t sample_count,
    const char *language, int32_t threads, jsti_whisper_job *job, char **text, char *error, size_t capacity) {
    if (runtime == NULL || model_path == NULL || job == NULL || text == NULL || (sample_count > 0 && samples == NULL) ||
        sample_count > (size_t)INT_MAX) {
        jsti_set_error(error, capacity, "Invalid on-device transcription request.");
        return JSTI_WHISPER_FAILED;
    }
    *text = NULL;
    g_mutex_lock(&runtime->mutex);
    int32_t result = JSTI_WHISPER_FAILED;
    if (abort_requested(job)) { result = JSTI_WHISPER_CANCELLED; goto done; }
    if (runtime->context == NULL || g_strcmp0(runtime->context_path, model_path) != 0) {
        release_context(runtime);
        FileLoader file = { .file = fopen(model_path, "rbe") };
        if (file.file == NULL) {
            jsti_set_error(error, capacity, "The downloaded model file could not be opened.");
            goto done;
        }
        struct whisper_model_loader loader = {
            .context = &file, .read = loader_read, .eof = loader_eof, .close = loader_close,
        };
        struct whisper_context_params parameters = runtime->api.context_defaults();
        parameters.use_gpu = runtime->has_gpu;
        parameters.gpu_device = 0;
        runtime->context = runtime->api.init_with_params(&loader, parameters);
        loader_close(&file);
        if (runtime->context == NULL) {
            gchar *detail = last_log_line();
            jsti_set_error(error, capacity, "The model could not be loaded%s%s", detail[0] ? ": " : ".", detail);
            g_free(detail);
            goto done;
        }
        runtime->context_path = g_strdup(model_path);
    }
    if (abort_requested(job)) { result = JSTI_WHISPER_CANCELLED; goto done; }
    struct whisper_full_params parameters = runtime->api.full_defaults(WHISPER_SAMPLING_GREEDY);
    long hardware = sysconf(_SC_NPROCESSORS_ONLN);
    parameters.n_threads = threads > 0 ? threads : (int)CLAMP(hardware, 1, 8);
    parameters.translate = false;
    parameters.no_timestamps = true;
    parameters.single_segment = false;
    parameters.print_special = false;
    parameters.print_progress = false;
    parameters.print_realtime = false;
    parameters.print_timestamps = false;
    parameters.suppress_blank = true;
    parameters.suppress_nst = true;
    gboolean known = language != NULL && *language != '\0' && runtime->api.language_id(language) >= 0;
    parameters.language = known ? language : "auto";
    parameters.detect_language = false;
    parameters.abort_callback = abort_requested;
    parameters.abort_callback_user_data = job;
    parameters.encoder_begin_callback = encoder_begin;
    parameters.encoder_begin_callback_user_data = job;
    int status = runtime->api.full(runtime->context, parameters, samples, (int)sample_count);
    if (abort_requested(job)) { result = JSTI_WHISPER_CANCELLED; goto done; }
    if (status != 0) {
        jsti_set_error(error, capacity, "On-device transcription failed (whisper.cpp status %d).", status);
        goto done;
    }
    GString *collected = g_string_new(NULL);
    int segments = runtime->api.segment_count(runtime->context);
    for (int index = 0; index < segments; index++) {
        const char *segment = runtime->api.segment_text(runtime->context, index);
        if (segment != NULL) g_string_append(collected, segment);
    }
    *text = strdup(collected->str);
    g_string_free(collected, TRUE);
    if (*text == NULL) {
        jsti_set_error(error, capacity, "Could not allocate the transcript.");
        goto done;
    }
    result = JSTI_WHISPER_OK;
done:
    g_mutex_unlock(&runtime->mutex);
    return result;
}

/* ---------------------------------------------------------------- SHA-256 */

struct jsti_sha256 { GChecksum *checksum; };

jsti_sha256 *jsti_sha256_create(char *error, size_t capacity) {
    GChecksum *checksum = g_checksum_new(G_CHECKSUM_SHA256);
    if (checksum == NULL) {
        jsti_set_error(error, capacity, "SHA-256 is unavailable.");
        return NULL;
    }
    jsti_sha256 *hasher = g_new0(jsti_sha256, 1);
    hasher->checksum = checksum;
    return hasher;
}

int32_t jsti_sha256_update(jsti_sha256 *hasher, const void *bytes, size_t count, char *error, size_t capacity) {
    if (hasher == NULL || (count > 0 && bytes == NULL)) {
        jsti_set_error(error, capacity, "Invalid SHA-256 input.");
        return -1;
    }
    const guchar *cursor = bytes;
    while (count > 0) {
        gssize chunk = (gssize)MIN(count, (size_t)G_MAXSSIZE);
        g_checksum_update(hasher->checksum, cursor, chunk);
        cursor += chunk;
        count -= (size_t)chunk;
    }
    return 0;
}

int32_t jsti_sha256_finish(jsti_sha256 *hasher, char *hex, size_t hex_capacity, char *error, size_t capacity) {
    if (hasher == NULL || hex == NULL || hex_capacity < 65) {
        jsti_set_error(error, capacity, "Invalid SHA-256 output buffer.");
        return -1;
    }
    g_strlcpy(hex, g_checksum_get_string(hasher->checksum), hex_capacity);
    return 0;
}

void jsti_sha256_destroy(jsti_sha256 *hasher) {
    if (hasher == NULL) return;
    g_checksum_free(hasher->checksum);
    g_free(hasher);
}
