#include "CRecordingFileSupport.h"
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#include <stdlib.h>
#if defined(_MSC_VER)
#pragma comment(lib, "kernel32.lib")
#endif
#else
#include <errno.h>
#include <stdio.h>
#endif

static const char *last_separator(const char *path) {
    const char *last = NULL;
    for (; *path; ++path) {
        if (*path == '/'
#if defined(_WIN32)
            || *path == '\\'
#endif
        ) last = path;
    }
    return last;
}

static int distinct_siblings(const char *source, const char *destination) {
    if (!source || !destination || !*source || !*destination || !strcmp(source, destination)) return 0;
    const char *source_leaf = last_separator(source);
    const char *destination_leaf = last_separator(destination);
    if (!source_leaf || !destination_leaf || !source_leaf[1] || !destination_leaf[1]) return 0;
    if (!strcmp(source_leaf + 1, ".") || !strcmp(source_leaf + 1, "..") ||
        !strcmp(destination_leaf + 1, ".") || !strcmp(destination_leaf + 1, "..")) return 0;
    size_t source_parent = (size_t)(source_leaf - source) + 1;
    size_t destination_parent = (size_t)(destination_leaf - destination) + 1;
    return source_parent == destination_parent && !memcmp(source, destination, source_parent);
}

#if defined(_WIN32)
static wchar_t *wide_path(const char *path, DWORD *error) {
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!length) { *error = GetLastError(); return NULL; }
    if ((size_t)length > SIZE_MAX / sizeof(wchar_t)) {
        *error = ERROR_NOT_ENOUGH_MEMORY;
        return NULL;
    }
    wchar_t *wide = (wchar_t *)malloc((size_t)length * sizeof(wchar_t));
    if (!wide) { *error = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length)) {
        *error = GetLastError();
        free(wide);
        return NULL;
    }
    return wide;
}
#endif

uint32_t jsti_file_replace(const char *source, const char *destination) {
    if (!distinct_siblings(source, destination)) {
#if defined(_WIN32)
        return ERROR_INVALID_PARAMETER;
#else
        return EINVAL;
#endif
    }
#if defined(_WIN32)
    DWORD error = ERROR_SUCCESS;
    wchar_t *from = wide_path(source, &error);
    if (!from) return error;
    wchar_t *to = wide_path(destination, &error);
    if (!to) { free(from); return error; }
    /* No COPY_ALLOWED: a cross-volume route must fail, never copy then delete. */
    BOOL moved = MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    error = moved ? ERROR_SUCCESS : GetLastError();
    free(to);
    free(from);
    return error;
#else
    return rename(source, destination) == 0 ? 0 : (uint32_t)errno;
#endif
}
