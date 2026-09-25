#include "LinuxSupportInternal.h"
/* Declarations and struct layouts only, from the headers vendored for Windows
 * at the same whisper.cpp pin (../CWindowsSupport/whisper-cpp/PROVENANCE.md).
 * Nothing from whisper.cpp is linked: the libraries are opened at run time. */
#include "../CWindowsSupport/whisper-cpp/whisper.h"

#include <dirent.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/*
 * whisper.cpp loaded at run time from one directory. The struct layouts the
 * headers describe are only valid for the pinned release, so open() refuses
 * any other whisper_version(). The libraries are opened by absolute path in
 * dependency order, so the sonames libwhisper needs resolve to those copies
 * and the dynamic loader never searches LD_LIBRARY_PATH or the system. ggml's
 * own loader is not used for backends: it would also honour GGML_BACKEND_PATH.
 * The best CPU backend (and Vulkan, when allowed and built) is chosen from the
 * runtime directory only.
 */

#define EXPECTED_VERSION "1.9.4"
#define CPU_BACKEND_PREFIX "libggml-cpu-"
#define VULKAN_BACKEND "libggml-vulkan.so"

static const char *const runtime_libraries[] = { "libggml-base.so.0", "libggml.so.0", "libwhisper.so.1" };

/* ggml runs gdb against the process to print a backtrace when it aborts or a
 * C++ exception escapes (a terminate handler installed when libggml-base
 * loads), found through PATH. The switch is read at load, so it is set here,
 * before main and any thread, without overriding an explicit choice. */
__attribute__((constructor)) static void disable_debugger_backtraces(void) { setenv("GGML_NO_BACKTRACE", "1", 0); }

typedef int (*backend_score_fn)(void);

typedef struct Api {
    __typeof__(&whisper_version) version;
    __typeof__(&whisper_context_default_params) context_defaults;
    __typeof__(&whisper_init_with_params) init_with_params;
    __typeof__(&whisper_full_default_params) full_defaults;
    __typeof__(&whisper_full) full;
    __typeof__(&whisper_full_n_segments) segment_count;
    __typeof__(&whisper_full_get_segment_text) segment_text;
    __typeof__(&whisper_free) free;
    __typeof__(&whisper_lang_id) language_id;
    __typeof__(&whisper_log_set) log_set;
    __typeof__(&ggml_backend_load) load_backend;
    __typeof__(&ggml_backend_dev_count) device_count;
    __typeof__(&ggml_backend_dev_get) device;
    __typeof__(&ggml_backend_dev_type) device_type;
    __typeof__(&ggml_backend_dev_name) device_name;
    __typeof__(&ggml_backend_dev_description) device_description;
} Api;

struct JSTIWhisperRuntime {
    gchar *directory;
    Api api;
    gboolean allow_gpu;
    gboolean has_gpu;
    gchar *description;
    GMutex mutex; /* Serialises model use; whisper_full is not reentrant per context. */
    struct whisper_context *context;
    gchar *context_path;
    gchar *context_sha256; /* Lowercase SHA-256 of the bytes `context` was loaded from. */
};

struct JSTIWhisperJob {
    gint cancelled;
};

static GMutex open_lock;
static JSTIWhisperRuntime *shared_runtime;

/* Recent runtime log lines explain a failed model load without exposing
 * transcript text: whisper.cpp logs no audio or decoded text at these levels. */
static GMutex log_lock;
static GQueue log_lines = G_QUEUE_INIT;
static GString *log_partial;

static void log_callback(enum ggml_log_level level, const char *text, void *data) {
    (void)data;
    if (text == NULL || (level != GGML_LOG_LEVEL_ERROR && level != GGML_LOG_LEVEL_WARN &&
                         level != GGML_LOG_LEVEL_INFO && level != GGML_LOG_LEVEL_CONT)) return;
    g_mutex_lock(&log_lock);
    if (log_partial == NULL) log_partial = g_string_new(NULL);
    g_string_append(log_partial, text);
    char *newline;
    while ((newline = strchr(log_partial->str, '\n')) != NULL) {
        gsize length = (gsize)(newline - log_partial->str);
        if (length > 0) g_queue_push_tail(&log_lines, g_strndup(log_partial->str, length));
        g_string_erase(log_partial, 0, (gssize)length + 1);
        while (g_queue_get_length(&log_lines) > 8) g_free(g_queue_pop_head(&log_lines));
    }
    g_mutex_unlock(&log_lock);
}

/* The latest error or failure line, else the latest line; caller frees. */
static gchar *last_log_line(void) {
    g_mutex_lock(&log_lock);
    gchar *found = NULL;
    for (GList *line = log_lines.tail; line != NULL && found == NULL; line = line->prev) {
        if (strstr(line->data, "error") != NULL || strstr(line->data, "failed") != NULL) found = g_strdup(line->data);
    }
    if (found == NULL && log_lines.tail != NULL) found = g_strdup(log_lines.tail->data);
    g_mutex_unlock(&log_lock);
    return found != NULL ? found : g_strdup("");
}

/* A runtime file must be a regular file (not a link) that other users cannot
 * replace. Group write is allowed: user-private groups are the norm. */
static gboolean trusted_file(const char *path) {
    struct stat info;
    return lstat(path, &info) == 0 && S_ISREG(info.st_mode) && (info.st_mode & S_IWOTH) == 0;
}

static gboolean resolve(void *handles[], size_t count, const char *name, void **target) {
    for (size_t index = 0; index < count; index++) {
        void *address = handles[index] != NULL ? dlsym(handles[index], name) : NULL;
        if (address != NULL) {
            *target = address;
            return TRUE;
        }
    }
    return FALSE;
}

/* The CPU backend variant scoring highest on this processor, as ggml's own
 * loader would pick it, but from `directory` only. NULL when none scores. */
static gchar *best_cpu_backend(const char *directory) {
    DIR *folder = opendir(directory);
    if (folder == NULL) return NULL;
    gchar *best = NULL;
    int best_score = 0;
    struct dirent *entry;
    while ((entry = readdir(folder)) != NULL) {
        if (!g_str_has_prefix(entry->d_name, CPU_BACKEND_PREFIX) || !g_str_has_suffix(entry->d_name, ".so")) continue;
        gchar *path = g_build_filename(directory, entry->d_name, NULL);
        void *module = trusted_file(path) ? dlopen(path, RTLD_NOW | RTLD_LOCAL) : NULL;
        backend_score_fn score = module != NULL ? (backend_score_fn)dlsym(module, "ggml_backend_score") : NULL;
        int value = score != NULL ? score() : 0;
        if (module != NULL) dlclose(module);
        if (value > best_score) {
            best_score = value;
            g_free(best);
            best = path;
        } else {
            g_free(path);
        }
    }
    closedir(folder);
    if (best == NULL) {
        /* A build without GGML_CPU_ALL_VARIANTS has one unscored backend. */
        gchar *single = g_build_filename(directory, "libggml-cpu.so", NULL);
        if (trusted_file(single)) return single;
        g_free(single);
    }
    return best;
}

static void describe_devices(JSTIWhisperRuntime *runtime) {
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
            if (description != NULL && description[0] != '\0') g_string_append_printf(gpus, " (%s)", description);
            gpu = TRUE;
        } else if (type == GGML_BACKEND_DEVICE_TYPE_CPU) {
            cpu = TRUE;
        }
    }
    runtime->has_gpu = gpu && runtime->allow_gpu;
    GString *text = g_string_new("whisper.cpp " EXPECTED_VERSION);
    if (gpu) g_string_append_printf(text, "; GPU: %s", gpus->str);
    g_string_append(text, cpu ? "; CPU" : "; no CPU backend");
    runtime->description = g_string_free(text, FALSE);
    g_string_free(gpus, TRUE);
}

static void release_context(JSTIWhisperRuntime *runtime) {
    if (runtime->context != NULL) runtime->api.free(runtime->context);
    runtime->context = NULL;
    g_clear_pointer(&runtime->context_path, g_free);
    g_clear_pointer(&runtime->context_sha256, g_free);
}

JSTIWhisperRuntime *jsti_whisper_runtime_open(const char *directory, int32_t allow_gpu, char *error, size_t capacity) {
    if (directory == NULL || directory[0] != '/') {
        jsti_set_error(error, capacity, "The speech runtime directory must be an absolute path.");
        return NULL;
    }
    char resolved[PATH_MAX];
    struct stat folder;
    if (realpath(directory, resolved) == NULL || stat(resolved, &folder) != 0 || !S_ISDIR(folder.st_mode)) {
        jsti_set_error(error, capacity, "The on-device speech runtime (libwhisper) is not installed beside the app.");
        return NULL;
    }
    if (folder.st_mode & S_IWOTH) {
        jsti_set_error(error, capacity, "The speech runtime directory is writable by other users, so it was not loaded.");
        return NULL;
    }
    for (size_t index = 0; index < G_N_ELEMENTS(runtime_libraries); index++) {
        gchar *path = g_build_filename(resolved, runtime_libraries[index], NULL);
        gboolean trusted = trusted_file(path);
        g_free(path);
        if (!trusted) {
            jsti_set_error(error, capacity, "The on-device speech runtime is incomplete: %s is missing, a link or "
                           "writable by other users.", runtime_libraries[index]);
            return NULL;
        }
    }
    g_mutex_lock(&open_lock);
    if (shared_runtime != NULL) {
        JSTIWhisperRuntime *existing = strcmp(shared_runtime->directory, resolved) == 0 ? shared_runtime : NULL;
        g_mutex_unlock(&open_lock);
        if (existing == NULL) jsti_set_error(error, capacity, "The speech runtime is already loaded from another directory.");
        return existing;
    }
    void *handles[G_N_ELEMENTS(runtime_libraries)] = { NULL };
    for (size_t index = 0; index < G_N_ELEMENTS(runtime_libraries); index++) {
        /* Each library's sonames resolve to the copies opened before it. */
        gchar *path = g_build_filename(resolved, runtime_libraries[index], NULL);
        handles[index] = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        g_free(path);
        if (handles[index] == NULL) {
            const char *reason = dlerror();
            jsti_set_error(error, capacity, "Loading the on-device speech runtime failed: %s", reason != NULL ? reason : "unknown error");
            g_mutex_unlock(&open_lock);
            /* Loaded libraries stay mapped: unloading ggml after partial use is unsafe. */
            return NULL;
        }
    }
    JSTIWhisperRuntime *runtime = g_new0(JSTIWhisperRuntime, 1);
    Api *api = &runtime->api;
    void *order[] = { handles[2], handles[1], handles[0] };
    size_t count = G_N_ELEMENTS(order);
    gboolean complete = resolve(order, count, "whisper_version", (void **)&api->version) &&
        resolve(order, count, "whisper_context_default_params", (void **)&api->context_defaults) &&
        resolve(order, count, "whisper_init_with_params", (void **)&api->init_with_params) &&
        resolve(order, count, "whisper_full_default_params", (void **)&api->full_defaults) &&
        resolve(order, count, "whisper_full", (void **)&api->full) &&
        resolve(order, count, "whisper_full_n_segments", (void **)&api->segment_count) &&
        resolve(order, count, "whisper_full_get_segment_text", (void **)&api->segment_text) &&
        resolve(order, count, "whisper_free", (void **)&api->free) &&
        resolve(order, count, "whisper_lang_id", (void **)&api->language_id) &&
        resolve(order, count, "whisper_log_set", (void **)&api->log_set) &&
        resolve(order, count, "ggml_backend_load", (void **)&api->load_backend) &&
        resolve(order, count, "ggml_backend_dev_count", (void **)&api->device_count) &&
        resolve(order, count, "ggml_backend_dev_get", (void **)&api->device) &&
        resolve(order, count, "ggml_backend_dev_type", (void **)&api->device_type) &&
        resolve(order, count, "ggml_backend_dev_name", (void **)&api->device_name) &&
        resolve(order, count, "ggml_backend_dev_description", (void **)&api->device_description);
    const char *version = complete ? api->version() : NULL;
    if (version == NULL || strcmp(version, EXPECTED_VERSION) != 0) {
        jsti_set_error(error, capacity, "The on-device speech runtime is whisper.cpp %s; this app needs " EXPECTED_VERSION
                       ". Reinstall the app.", version != NULL ? version : "with an incomplete API");
        g_free(runtime);
        g_mutex_unlock(&open_lock);
        return NULL;
    }
    api->log_set(log_callback, NULL);
    runtime->directory = g_strdup(resolved);
    runtime->allow_gpu = allow_gpu != 0;
    g_mutex_init(&runtime->mutex);
    /* Vulkan first, as ggml orders devices; without libvulkan.so.1 or a
     * device it does not register and the CPU runs. */
    gchar *vulkan = g_build_filename(resolved, VULKAN_BACKEND, NULL);
    if (runtime->allow_gpu && trusted_file(vulkan)) api->load_backend(vulkan);
    g_free(vulkan);
    gchar *cpu = best_cpu_backend(resolved);
    if (cpu != NULL) api->load_backend(cpu);
    g_free(cpu);
    describe_devices(runtime);
    if (strstr(runtime->description, "; CPU") == NULL) {
        gchar *detail = last_log_line();
        jsti_set_error(error, capacity, "The on-device speech runtime found no usable CPU backend. %s", detail);
        g_free(detail);
        g_free(runtime->description);
        g_free(runtime->directory);
        g_mutex_clear(&runtime->mutex);
        g_free(runtime);
        g_mutex_unlock(&open_lock);
        return NULL;
    }
    shared_runtime = runtime;
    g_mutex_unlock(&open_lock);
    return runtime;
}

int32_t jsti_whisper_runtime_describe(JSTIWhisperRuntime *runtime, char *text, size_t capacity) {
    if (runtime == NULL || text == NULL || capacity == 0) return -1;
    g_strlcpy(text, runtime->description, capacity);
    return 0;
}

int32_t jsti_whisper_runtime_uses_gpu(JSTIWhisperRuntime *runtime) { return runtime != NULL && runtime->has_gpu ? 1 : 0; }

JSTIWhisperJob *jsti_whisper_job_create(void) { return g_new0(JSTIWhisperJob, 1); }

void jsti_whisper_job_cancel(JSTIWhisperJob *job) {
    if (job != NULL) g_atomic_int_set(&job->cancelled, 1);
}

void jsti_whisper_job_destroy(JSTIWhisperJob *job) { g_free(job); }

void jsti_whisper_free_text(char *text) { free(text); }

void jsti_whisper_runtime_release_model(JSTIWhisperRuntime *runtime) {
    if (runtime == NULL) return;
    g_mutex_lock(&runtime->mutex);
    release_context(runtime);
    g_mutex_unlock(&runtime->mutex);
}

/* Checked under the lock transcribe loads under, with its path comparison, so
 * a model that replaced this one in the cache is never freed in its place. */
int32_t jsti_whisper_runtime_release_model_at(JSTIWhisperRuntime *runtime, const char *model_path) {
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

/* Hands whisper.cpp the model file's bytes through one open file and hashes
 * each byte as it is handed over, so the digest describes exactly the bytes
 * the runtime loaded, whatever happens to the file on disk meanwhile. */
typedef struct HashingReader {
    FILE *file;
    JSTISHA256 *hasher;
    gboolean failed;
} HashingReader;

static void reader_hash(HashingReader *reader, const void *bytes, size_t count) {
    char ignored[8];
    if (count > 0 && jsti_sha256_update(reader->hasher, bytes, count, ignored, sizeof ignored) != 0) {
        reader->failed = TRUE;
    }
}

static size_t loader_read(void *context, void *output, size_t size) {
    HashingReader *reader = context;
    size_t count = fread(output, 1, size, reader->file);
    reader_hash(reader, output, count);
    return count;
}
static bool loader_eof(void *context) { return feof(((HashingReader *)context)->file) != 0; }
/* whisper.cpp closes its loader when it finishes; the file stays open so any
 * bytes it did not read are hashed too. */
static void loader_close(void *context) { (void)context; }

/* Hashes what the runtime left unread, then compares the whole file's digest
 * with `expected`. Only a match returns TRUE. */
static gboolean reader_matches(HashingReader *reader, const char *expected) {
    guchar *buffer = g_malloc(1 << 16);
    size_t count;
    while ((count = fread(buffer, 1, 1 << 16, reader->file)) > 0) reader_hash(reader, buffer, count);
    g_free(buffer);
    char digest[65] = { 0 };
    char ignored[8];
    if (ferror(reader->file) || reader->failed ||
        jsti_sha256_finish(reader->hasher, digest, sizeof digest, ignored, sizeof ignored) != 0) {
        return FALSE;
    }
    return g_ascii_strcasecmp(digest, expected) == 0;
}

static gboolean is_sha256_hex(const char *text) {
    if (text == NULL || strlen(text) != 64) return FALSE;
    for (const char *cursor = text; *cursor != '\0'; cursor++) {
        if (!g_ascii_isxdigit(*cursor)) return FALSE;
    }
    return TRUE;
}

static bool abort_requested(void *data) { return g_atomic_int_get(&((JSTIWhisperJob *)data)->cancelled) != 0; }

static bool encoder_may_begin(struct whisper_context *context, struct whisper_state *state, void *data) {
    (void)context; (void)state;
    return !abort_requested(data);
}

/* Loads the model at `path` into the cache unless it already holds the bytes
 * of that path with digest `sha256`. The bytes are hashed as whisper.cpp reads
 * them, and a model whose bytes do not match is freed, never cached or used.
 * The file is closed once loaded, so a removal may delete it while cached. */
static int32_t load_model(JSTIWhisperRuntime *runtime, const char *path, const char *sha256, char *error,
                          size_t capacity) {
    if (runtime->context != NULL && g_strcmp0(runtime->context_path, path) == 0 &&
        g_ascii_strcasecmp(runtime->context_sha256, sha256) == 0) {
        return JSTI_WHISPER_OK;
    }
    release_context(runtime);
    HashingReader reader = { .file = fopen(path, "rbe"), .hasher = NULL, .failed = FALSE };
    if (reader.file == NULL) {
        jsti_set_error(error, capacity, "The downloaded model file could not be opened.");
        return JSTI_WHISPER_FAILED;
    }
    reader.hasher = jsti_sha256_create(error, capacity);
    if (reader.hasher == NULL) {
        fclose(reader.file);
        return JSTI_WHISPER_FAILED;
    }
    whisper_model_loader loader = { .context = &reader, .read = loader_read, .eof = loader_eof, .close = loader_close };
    struct whisper_context_params parameters = runtime->api.context_defaults();
    parameters.use_gpu = runtime->has_gpu;
    parameters.gpu_device = 0;
    struct whisper_context *context = runtime->api.init_with_params(&loader, parameters);
    gboolean matches = reader_matches(&reader, sha256);
    jsti_sha256_destroy(reader.hasher);
    fclose(reader.file);
    if (!matches) {
        if (context != NULL) runtime->api.free(context);
        jsti_set_error(error, capacity, "The downloaded model file does not match its pinned SHA-256.");
        return JSTI_WHISPER_MODEL_MISMATCH;
    }
    if (context == NULL) {
        gchar *detail = last_log_line();
        jsti_set_error(error, capacity, "The model could not be loaded%s%s", detail[0] != '\0' ? ": " : ".", detail);
        g_free(detail);
        return JSTI_WHISPER_FAILED;
    }
    runtime->context = context;
    runtime->context_path = g_strdup(path);
    runtime->context_sha256 = g_ascii_strdown(sha256, -1);
    return JSTI_WHISPER_OK;
}

static int32_t run_locked(JSTIWhisperRuntime *runtime, const char *model_path, const char *model_sha256,
                          const float *samples, size_t sample_count, const char *language, int32_t threads,
                          JSTIWhisperJob *job, char **text, char *error, size_t capacity) {
    if (abort_requested(job)) return JSTI_WHISPER_CANCELLED;
    int32_t loaded = load_model(runtime, model_path, model_sha256, error, capacity);
    if (loaded != JSTI_WHISPER_OK) return loaded;
    if (abort_requested(job)) return JSTI_WHISPER_CANCELLED;
    struct whisper_full_params parameters = runtime->api.full_defaults(WHISPER_SAMPLING_GREEDY);
    gint hardware = MAX(1, (gint)g_get_num_processors());
    parameters.n_threads = threads > 0 ? threads : MIN(8, hardware);
    parameters.translate = false;
    parameters.no_timestamps = true;
    parameters.single_segment = false;
    parameters.print_special = false;
    parameters.print_progress = false;
    parameters.print_realtime = false;
    parameters.print_timestamps = false;
    parameters.suppress_blank = true;
    parameters.suppress_nst = true;
    gboolean known = language != NULL && language[0] != '\0' && runtime->api.language_id(language) >= 0;
    parameters.language = known ? language : "auto";
    parameters.detect_language = false;
    parameters.abort_callback = abort_requested;
    parameters.abort_callback_user_data = job;
    parameters.encoder_begin_callback = encoder_may_begin;
    parameters.encoder_begin_callback_user_data = job;
    int status = runtime->api.full(runtime->context, parameters, samples, (int)sample_count);
    if (abort_requested(job)) return JSTI_WHISPER_CANCELLED;
    if (status != 0) {
        jsti_set_error(error, capacity, "On-device transcription failed (whisper.cpp status %d).", status);
        return JSTI_WHISPER_FAILED;
    }
    GString *result = g_string_new(NULL);
    int segments = runtime->api.segment_count(runtime->context);
    for (int index = 0; index < segments; index++) {
        const char *segment = runtime->api.segment_text(runtime->context, index);
        if (segment != NULL) g_string_append(result, segment);
    }
    /* Freed with free() by jsti_whisper_free_text, like the Windows adapter. */
    *text = strdup(result->str);
    g_string_free(result, TRUE);
    if (*text == NULL) {
        jsti_set_error(error, capacity, "Could not allocate the transcript.");
        return JSTI_WHISPER_FAILED;
    }
    return JSTI_WHISPER_OK;
}

int32_t jsti_whisper_transcribe(JSTIWhisperRuntime *runtime, const char *model_path, const char *model_sha256,
                                const float *samples, size_t sample_count, const char *language, int32_t threads,
                                JSTIWhisperJob *job, char **text, char *error, size_t capacity) {
    if (runtime == NULL || model_path == NULL || model_path[0] != '/' || !is_sha256_hex(model_sha256) || job == NULL ||
        text == NULL ||
        (sample_count > 0 && samples == NULL) || sample_count > (size_t)INT_MAX) {
        jsti_set_error(error, capacity, "Invalid on-device transcription request.");
        return JSTI_WHISPER_FAILED;
    }
    *text = NULL;
    g_mutex_lock(&runtime->mutex);
    int32_t status = run_locked(runtime, model_path, model_sha256, samples, sample_count, language, threads, job, text,
                                error, capacity);
    g_mutex_unlock(&runtime->mutex);
    return status;
}
