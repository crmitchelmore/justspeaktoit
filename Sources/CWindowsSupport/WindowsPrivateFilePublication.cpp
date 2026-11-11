// Cancellable copy of a private staging file into its published destination.
#include "WindowsFileSecurityInternal.hpp"

using namespace jsti_file_security;

namespace jsti_file_security {
bool publicationCancelled(jsti_file_publication_cancelled_fn cancelled, void *context) {
    return cancelled && cancelled(context) != 0;
}
} // namespace jsti_file_security

namespace {
int copyForPublication(HANDLE source, HANDLE output, jsti_file_publication_cancelled_fn cancelled,
                       void *context, std::string &error) {
    std::array<BYTE, 64 * 1024> buffer{};
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(source, &size) || size.QuadPart < 0) {
        error = jsti::systemError("Read private export size");
        return -1;
    }
    auto remaining = static_cast<ULONGLONG>(size.QuadPart);
    while (remaining > 0) {
        if (publicationCancelled(cancelled, context)) return 2;
        DWORD count = 0;
        const DWORD requested = static_cast<DWORD>(std::min<ULONGLONG>(remaining, buffer.size()));
        if (!ReadFile(source, buffer.data(), requested, &count, nullptr)) {
            error = jsti::systemError("Read private export source");
            return -1;
        }
        if (!count) {
            error = "The private export source changed while it was being copied.";
            return -1;
        }
        for (DWORD offset = 0; offset < count;) {
            DWORD written = 0;
            if (!WriteFile(output, buffer.data() + offset, count - offset, &written, nullptr) || !written) {
                error = jsti::systemError("Write private export staging");
                return -1;
            }
            offset += written;
        }
        remaining -= count;
    }
    if (publicationCancelled(cancelled, context)) return 2;
    if (!FlushFileBuffers(output)) {
        error = jsti::systemError("Flush private export staging");
        return -1;
    }
    return 0;
}

int publishPrivateFile(const char *sourcePath, const char *destinationPath,
                       jsti_file_publication_cancelled_fn cancelled, void *context,
                       jsti::Handle &output, std::string &error) {
    if (publicationCancelled(cancelled, context)) return 2;
    std::vector<std::wstring> sourceParts, destinationParts;
    std::vector<std::unique_ptr<jsti::Handle>> sourceParents, destinationParents;
    PrivateSecurity security;
    if (!parsePath(sourcePath, sourceParts, error) || !parsePath(destinationPath, destinationParts, error) ||
        !security.initialise(error) || !openParents(sourceParts, sourceParents, error) ||
        !openParents(destinationParts, destinationParents, error)) return -1;
    jsti::Handle source;
    if (!openRelative(sourceParents.back()->value, sourceParts.back(),
                      READ_CONTROL | FILE_READ_DATA | FILE_READ_ATTRIBUTES, FILE_OPEN, false, nullptr,
                      source, error, FILE_SHARE_READ) || !verifyPrivate(source.value, security, error)) return -1;
    FILE_ATTRIBUTE_TAG_INFO attributes{};
    if (!GetFileInformationByHandleEx(source.value, FileAttributeTagInfo, &attributes, sizeof(attributes))) {
        error = jsti::systemError("Inspect private export source");
        return -1;
    }
    if (attributes.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) {
        error = "Private export requires a regular, non-reparse source file.";
        return -1;
    }
    GUID guid{};
    wchar_t identifier[40]{};
    if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, identifier, static_cast<int>(std::size(identifier)))) {
        error = "Could not create a unique export staging name.";
        return -1;
    }
    const std::wstring name = L".jsti-export-" + std::wstring(identifier) + L".partial";
    if (!openRelative(destinationParents.back()->value, name,
                      READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_WRITE_DATA | DELETE, FILE_CREATE, false,
                      &security.descriptor, output, error, FILE_SHARE_READ) ||
        !verifyPrivate(output.value, security, error)) return -1;
    const int copied = copyForPublication(source.value, output.value, cancelled, context, error);
    if (copied != 0) return copied;
    const std::wstring &target = destinationParts.back();
    const size_t bytes = target.size() * sizeof(wchar_t);
    std::vector<BYTE> storage(std::max(sizeof(FILE_RENAME_INFO), offsetof(FILE_RENAME_INFO, FileName) + bytes), 0);
    auto *rename = reinterpret_cast<FILE_RENAME_INFO *>(storage.data());
    rename->ReplaceIfExists = FALSE;
    rename->RootDirectory = destinationParents.back()->value;
    rename->FileNameLength = static_cast<DWORD>(bytes);
    std::memcpy(rename->FileName, target.data(), bytes);
    if (publicationCancelled(cancelled, context)) return 2;
    // Preserve the held root all the way through rename. The Win32 wrapper
    // rejects this relative-name form on supported Windows hosts.
    // The user-mode SDK omits this export and NT information class 10.
    const auto setInformation = heldRootSetInformation();
    if (!setInformation) {
        error = "Windows does not provide NtSetInformationFile required for protected backup publication.";
        return -1;
    }
    IO_STATUS_BLOCK status{};
    const NTSTATUS renamed = setInformation(
        output.value, &status, rename, static_cast<ULONG>(storage.size()), heldRootRenameInformationClass);
    if (renamed < 0) {
        error = jsti::systemError("Publish private export without replacing an existing file",
                                  RtlNtStatusToDosError(renamed));
        return -1;
    }
    return 0;
}
} // namespace

int jsti_private_file_publish(const char *source, const char *destination,
                              jsti_file_publication_cancelled_fn cancelled, void *context,
                              char *error, size_t capacity) {
    jsti::Handle output;
    std::string detail;
    int result = -1;
    try {
        result = publishPrivateFile(source, destination, cancelled, context, output, detail);
    } catch (const std::exception &) {
        detail = "Private export could not allocate its publication state.";
    }
    if (result != 0 && output.value && output.value != INVALID_HANDLE_VALUE) {
        FILE_DISPOSITION_INFO disposition{TRUE};
        if (!SetFileInformationByHandle(output.value, FileDispositionInfo, &disposition, sizeof(disposition))) {
            detail += " " + jsti::systemError("Remove partial private export");
            result = -1;
        }
    }
    if (output.value && output.value != INVALID_HANDLE_VALUE) {
        const HANDLE handle = output.value;
        output.value = nullptr;
        if (!CloseHandle(handle)) {
            detail = jsti::systemError("Close private export handle");
            if (result == 0) {
                jsti::fail(detail, error, capacity);
                return 3;
            }
            result = -1;
        }
    }
    if (result < 0) return jsti::fail(detail, error, capacity);
    if (error && capacity) error[0] = 0;
    return result;
}
