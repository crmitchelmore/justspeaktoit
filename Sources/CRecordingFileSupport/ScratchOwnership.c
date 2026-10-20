#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include "CRecordingFileSupport.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static int scratch_run(const char *name) {
    if (!name || strlen(name) != 36) return 0;
    for (int i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (name[i] != '-') return 0;
        } else if (!((name[i] >= '0' && name[i] <= '9') || (name[i] >= 'A' && name[i] <= 'F'))) {
            return 0;
        }
    }
    return 1;
}

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

struct jsti_scratch_owner { HANDLE directory; };

static DWORD scratch_directory(HANDLE directory) {
    FILE_ATTRIBUTE_TAG_INFO value;
    if (!GetFileInformationByHandleEx(directory, FileAttributeTagInfo, &value, sizeof(value)))
        return GetLastError();
    if (!(value.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (value.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) return ERROR_ACCESS_DENIED;
    return ERROR_SUCCESS;
}

static DWORD scratch_path(jsti_scratch_owner *owner, const char *run, wchar_t **path) {
    *path = NULL;
    if (!owner || !scratch_run(run)) return ERROR_INVALID_PARAMETER;
    DWORD error = scratch_directory(owner->directory);
    if (error) return error;
    DWORD count = GetFinalPathNameByHandleW(owner->directory, NULL, 0, FILE_NAME_NORMALIZED);
    if (!count) return GetLastError();
    wchar_t *value = calloc((size_t)count + 64, sizeof(wchar_t));
    if (!value) return ERROR_NOT_ENOUGH_MEMORY;
    DWORD actual = GetFinalPathNameByHandleW(owner->directory, value, count, FILE_NAME_NORMALIZED);
    if (!actual || actual >= count) {
        error = actual ? ERROR_BUFFER_OVERFLOW : GetLastError();
        free(value);
        return error;
    }
    value[actual++] = L'\\';
    for (int i = 0; i < 36; ++i) value[actual++] = (wchar_t)run[i];
    value[actual] = 0;
    *path = value;
    return ERROR_SUCCESS;
}

uint32_t jsti_scratch_open(const char *root, jsti_scratch_owner **owner) {
    if (!owner) return ERROR_INVALID_PARAMETER;
    *owner = NULL;
    if (!root) return ERROR_INVALID_PARAMETER;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, root, -1, NULL, 0);
    if (!count) return GetLastError();
    wchar_t *path = calloc((size_t)count, sizeof(wchar_t));
    if (!path) return ERROR_NOT_ENOUGH_MEMORY;
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, root, -1, path, count)) {
        DWORD error = GetLastError();
        free(path);
        return error;
    }
    /* Write admission with no WRITE sharing excludes a competing owner.
     * Read-only parent traversal remains possible; DELETE sharing is denied. */
    HANDLE directory = CreateFileW(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | FILE_ADD_FILE,
        FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    DWORD error = directory == INVALID_HANDLE_VALUE ? GetLastError() : scratch_directory(directory);
    free(path);
    if (error) {
        if (directory != INVALID_HANDLE_VALUE) CloseHandle(directory);
        return error;
    }
    jsti_scratch_owner *value = calloc(1, sizeof(*value));
    if (!value) { CloseHandle(directory); return ERROR_NOT_ENOUGH_MEMORY; }
    value->directory = directory;
    *owner = value;
    return ERROR_SUCCESS;
}

uint32_t jsti_scratch_create(jsti_scratch_owner *owner, const char *run) {
    wchar_t *path = NULL;
    DWORD error = scratch_path(owner, run, &path);
    if (error) return error;
    if (!CreateDirectoryW(path, NULL)) error = GetLastError();
    free(path);
    return error;
}

uint32_t jsti_scratch_remove(jsti_scratch_owner *owner, const char *run) {
    wchar_t *path = NULL;
    DWORD error = scratch_path(owner, run, &path);
    if (error) return error;
    HANDLE directory = CreateFileW(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE,
        FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (directory == INVALID_HANDLE_VALUE) { error = GetLastError(); free(path); return error; }
    error = scratch_directory(directory);
    HANDLE file = INVALID_HANDLE_VALUE;
    HANDLE search = INVALID_HANDLE_VALUE;
    size_t length = wcslen(path);
    wcscpy(path + length, L"\\*");
    WIN32_FIND_DATAW entry;
    int has_audio = 0;
    if (!error) {
        search = FindFirstFileW(path, &entry);
        if (search == INVALID_HANDLE_VALUE) error = GetLastError();
        else {
            do {
                if (!wcscmp(entry.cFileName, L".") || !wcscmp(entry.cFileName, L"..")) continue;
                if (wcscmp(entry.cFileName, L"instruction.wav") ||
                    (entry.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
                    error = ERROR_ACCESS_DENIED;
                    break;
                }
                has_audio = 1;
            } while (FindNextFileW(search, &entry));
            if (!error && GetLastError() != ERROR_NO_MORE_FILES) error = GetLastError();
        }
    }
    if (search != INVALID_HANDLE_VALUE && !FindClose(search) && !error) error = GetLastError();
    if (!error && has_audio) {
        wcscpy(path + length, L"\\instruction.wav");
        file = CreateFileW(path, FILE_READ_ATTRIBUTES | DELETE, FILE_SHARE_READ, NULL, OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        if (file == INVALID_HANDLE_VALUE) error = GetLastError();
        else {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(file, &info)) error = GetLastError();
            else if ((info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
                     info.nNumberOfLinks != 1) error = ERROR_ACCESS_DENIED;
            else {
                FILE_DISPOSITION_INFO disposition = {TRUE};
                if (!SetFileInformationByHandle(file, FileDispositionInfo, &disposition, sizeof(disposition)))
                    error = GetLastError();
            }
        }
    }
    if (file != INVALID_HANDLE_VALUE && !CloseHandle(file) && !error) error = GetLastError();
    if (!error) {
        FILE_DISPOSITION_INFO disposition = {TRUE};
        if (!SetFileInformationByHandle(directory, FileDispositionInfo, &disposition, sizeof(disposition)))
            error = GetLastError();
    }
    if (!CloseHandle(directory) && !error) error = GetLastError();
    free(path);
    return error;
}

uint32_t jsti_scratch_close(jsti_scratch_owner *owner) {
    if (!owner) return ERROR_INVALID_PARAMETER;
    DWORD error = CloseHandle(owner->directory) ? ERROR_SUCCESS : GetLastError();
    free(owner);
    return error;
}
#else
#include <dirent.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

struct jsti_scratch_owner { int directory; };

static int scratch_directory(int directory) {
    struct stat info;
    if (fstat(directory, &info)) return errno;
    return S_ISDIR(info.st_mode) && info.st_uid == geteuid() && !(info.st_mode & 0077) ? 0 : EACCES;
}

uint32_t jsti_scratch_open(const char *root, jsti_scratch_owner **owner) {
    if (!owner) return EINVAL;
    *owner = NULL;
    if (!root) return EINVAL;
    int directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return errno;
    int error = scratch_directory(directory);
    if (!error && flock(directory, LOCK_EX | LOCK_NB)) error = errno;
    if (error) { close(directory); return error; }
    jsti_scratch_owner *value = calloc(1, sizeof(*value));
    if (!value) { close(directory); return ENOMEM; }
    value->directory = directory;
    *owner = value;
    return 0;
}

uint32_t jsti_scratch_create(jsti_scratch_owner *owner, const char *run) {
    if (!owner || !scratch_run(run)) return EINVAL;
    if (mkdirat(owner->directory, run, 0700)) return errno;
    return 0;
}

uint32_t jsti_scratch_remove(jsti_scratch_owner *owner, const char *run) {
    if (!owner || !scratch_run(run)) return EINVAL;
    int directory = openat(owner->directory, run, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return errno;
    int error = scratch_directory(directory);
    int file = -1;
    int has_audio = 0;
    DIR *entries = NULL;
    if (!error) {
        int scan = dup(directory);
        if (scan < 0) error = errno;
        else {
            entries = fdopendir(scan);
            if (!entries) { error = errno; close(scan); }
        }
    }
    if (entries) {
        struct dirent *entry;
        errno = 0;
        while ((entry = readdir(entries))) {
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            if (strcmp(entry->d_name, "instruction.wav")) { error = EACCES; break; }
            has_audio = 1;
        }
        if (!error && errno) error = errno;
        if (closedir(entries) && !error) error = errno;
    }
    if (!error && has_audio) {
        file = openat(directory, "instruction.wav", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        if (file < 0) error = errno;
        else {
            struct stat info;
            if (fstat(file, &info)) error = errno;
            else if (!S_ISREG(info.st_mode) || info.st_uid != geteuid() || info.st_nlink != 1) error = EACCES;
            else if (unlinkat(directory, "instruction.wav", 0)) error = errno;
        }
    }
    if (file >= 0 && close(file) && !error) error = errno;
    if (!error && unlinkat(owner->directory, run, AT_REMOVEDIR)) error = errno;
    if (close(directory) && !error) error = errno;
    return (uint32_t)error;
}

uint32_t jsti_scratch_close(jsti_scratch_owner *owner) {
    if (!owner) return EINVAL;
    int error = close(owner->directory) ? errno : 0;
    free(owner);
    return (uint32_t)error;
}
#endif
