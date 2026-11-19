// The immutable recording namespace (v1): registration and ownership leaves.
#include "WindowsFileSecurityInternal.hpp"

using namespace jsti_file_security;

struct JSTIRecordingRegistry {
    PrivateSecurity security;
    std::vector<std::unique_ptr<jsti::Handle>> parents;
    jsti::Handle directory;
    bool closed = false;

    bool validate(std::string &error) const {
        if (closed || !directory.value || parents.empty()) {
            error = "The immutable recording namespace is closed.";
            return false;
        }
        for (const auto &parent : parents) if (!checkDirectory(parent->value, error)) return false;
        return checkDirectory(directory.value, error) && verifyPrivate(directory.value, security, error);
    }

    bool close(std::string &error) {
        if (closed) return true;
        closed = true;
        bool success = true;
        auto release = [&](jsti::Handle &owned) {
            if (!owned.value || owned.value == INVALID_HANDLE_VALUE) return;
            const HANDLE handle = owned.value;
            owned.value = nullptr;
            if (!CloseHandle(handle)) {
                if (!error.empty()) error += " ";
                error += jsti::systemError("Close immutable recording namespace");
                success = false;
            }
        };
        release(directory);
        for (auto iterator = parents.rbegin(); iterator != parents.rend(); ++iterator) release(**iterator);
        return success;
    }
};

namespace jsti_file_security {
bool registryName(const char *value, std::wstring &name, std::string &error) {
    if (!value) { error = "A named immutable registration leaf is required."; return false; }
    const std::string text(value);
    if (text == "registry.jloc") { name = L"registry.jloc"; return true; }
    for (const std::string prefix : {"registration-", "ownership-"}) {
        if (text.size() == prefix.size() + 36 + 5 && text.compare(0, prefix.size(), prefix) == 0 &&
            text.compare(text.size() - 5, 5, ".jloc") == 0) {
            std::wstring identifier;
            if (!captureUUID(text.substr(prefix.size(), 36).c_str(), identifier, error)) return false;
            name = std::wstring(prefix.begin(), prefix.end()) + identifier + L".jloc";
            return true;
        }
    }
    error = "The immutable namespace refuses unknown or incomplete leaf names.";
    return false;
}
} // namespace jsti_file_security

namespace {
bool registryFile(HANDLE file, const PrivateSecurity &security, bool immutable, std::string &error) {
    FILE_ATTRIBUTE_TAG_INFO attributes{};
    BY_HANDLE_FILE_INFORMATION information{};
    if (!verifyPrivate(file, security, error)) return false;
    if (!GetFileInformationByHandleEx(file, FileAttributeTagInfo, &attributes, sizeof(attributes)) ||
        !GetFileInformationByHandle(file, &information)) {
        error = jsti::systemError("Inspect immutable registration file");
        return false;
    }
    if (GetFileType(file) != FILE_TYPE_DISK || information.nNumberOfLinks != 1 ||
        (attributes.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
        (immutable && !(attributes.FileAttributes & FILE_ATTRIBUTE_READONLY))) {
        error = "Registration records must be private immutable regular non-reparse single-link files.";
        return false;
    }
    return true;
}

bool registryRename(HANDLE file, const std::wstring &name, std::string &error) {
    // FILE_RENAME_INFORMATION: a simple name and NULL root rename within the
    // source handle's directory, without reopening our DELETE-held namespace.
    // https://learn.microsoft.com/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information
    const size_t bytes = name.size() * sizeof(wchar_t);
    std::vector<BYTE> storage(std::max(sizeof(FILE_RENAME_INFO), offsetof(FILE_RENAME_INFO, FileName) + bytes), 0);
    auto *rename = reinterpret_cast<FILE_RENAME_INFO *>(storage.data());
    rename->ReplaceIfExists = FALSE;
    rename->RootDirectory = nullptr;
    rename->FileNameLength = static_cast<DWORD>(bytes);
    std::memcpy(rename->FileName, name.data(), bytes);
    const auto setInformation = heldRootSetInformation();
    if (!setInformation) { error = "Held-root immutable publication is unavailable."; return false; }
    IO_STATUS_BLOCK status{};
    const NTSTATUS code = setInformation(
        file, &status, rename, static_cast<ULONG>(storage.size()), heldRootRenameInformationClass);
    if (code < 0) {
        error = jsti::systemError("Publish immutable registration without replacement", RtlNtStatusToDosError(code));
        return false;
    }
    return true;
}

bool registryReadOnly(HANDLE file, bool readOnly, std::string &error) {
    FILE_BASIC_INFO attributes{};
    if (!GetFileInformationByHandleEx(file, FileBasicInfo, &attributes, sizeof(attributes))) {
        error = jsti::systemError("Inspect registration attributes");
        return false;
    }
    if (readOnly) attributes.FileAttributes |= FILE_ATTRIBUTE_READONLY;
    else attributes.FileAttributes &= ~FILE_ATTRIBUTE_READONLY;
    if (!SetFileInformationByHandle(file, FileBasicInfo, &attributes, sizeof(attributes))) {
        error = jsti::systemError("Set registration immutability");
        return false;
    }
    return true;
}

bool registryRejectedSourceFixtures(const std::wstring &history, const std::wstring &root, std::string &error) {
    char detail[1024]{};
    JSTIRecordingRegistry *opened = nullptr;
    const std::wstring alias = history + L".junction";
    if (!createTestJunction(alias, history, error)) return false;
    const int ancestry = jsti_recording_registry_open(jsti::utf8(alias).c_str(), 0, &opened, detail, sizeof(detail));
    jsti_recording_registry_destroy(opened);
    if (!RemoveDirectoryW(alias.c_str()) || ancestry != -1) {
        error = "Native immutable registration followed a reparse ancestor.";
        return false;
    }
    const std::wstring saved = root + L".saved";
    if (!MoveFileW(root.c_str(), saved.c_str()) || !createTestJunction(root, saved, error)) {
        error = "Could not prepare the synthetic namespace replacement fixture.";
        return false;
    }
    const int leaf = jsti_recording_registry_open(jsti::utf8(history).c_str(), 0, &opened, detail, sizeof(detail));
    jsti_recording_registry_destroy(opened);
    if (!RemoveDirectoryW(root.c_str()) || !MoveFileW(saved.c_str(), root.c_str()) || leaf != -1) {
        error = "Native immutable registration accepted a reparse namespace.";
        return false;
    }
    PrivateSecurity security;
    if (!security.initialise(error)) return false;
    jsti::Handle directory;
    directory.value = CreateFileW(root.c_str(), READ_CONTROL | WRITE_DAC, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                   nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                                   nullptr);
    BYTE everyone[SECURITY_MAX_SID_SIZE]{};
    DWORD sidSize = sizeof(everyone);
    if (directory.value == INVALID_HANDLE_VALUE ||
        !CreateWellKnownSid(WinWorldSid, nullptr, everyone, &sidSize)) {
        error = "Could not prepare the synthetic namespace ACL fixture.";
        return false;
    }
    EXPLICIT_ACCESSW entry{};
    entry.grfAccessPermissions = FILE_ALL_ACCESS;
    entry.grfAccessMode = GRANT_ACCESS;
    BuildTrusteeWithSidW(&entry.Trustee, everyone);
    PACL permissive = nullptr;
    const DWORD aclCode = SetEntriesInAclW(1, &entry, static_cast<PACL>(security.acl.value), &permissive);
    LocalMemory memory;
    memory.value = permissive;
    if (aclCode != ERROR_SUCCESS ||
        SetSecurityInfo(directory.value, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                        nullptr, nullptr, permissive, nullptr) != ERROR_SUCCESS) {
        error = "Could not weaken only the synthetic namespace ACL.";
        return false;
    }
    const HANDLE ownedDirectory = directory.value;
    directory.value = nullptr;
    if (!CloseHandle(ownedDirectory)) {
        error = "Could not close the synthetic namespace ACL writer.";
        return false;
    }
    const int acl = jsti_recording_registry_open(jsti::utf8(history).c_str(), 0, &opened, detail, sizeof(detail));
    jsti_recording_registry_destroy(opened);
    directory.value = CreateFileW(root.c_str(), READ_CONTROL | WRITE_DAC, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                   OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (directory.value == INVALID_HANDLE_VALUE) {
        error = jsti::systemError("Reopen synthetic namespace ACL fixture");
        return false;
    }
    const DWORD restored = SetSecurityInfo(
        directory.value, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
        nullptr, nullptr, static_cast<PACL>(security.acl.value), nullptr);
    if (restored != ERROR_SUCCESS) {
        error = jsti::systemError("Restore synthetic namespace ACL fixture", restored);
        return false;
    }
    if (acl != -1) {
        error = "Native immutable registration accepted an insecure namespace ACL.";
        return false;
    }
    return true;
}
} // namespace

int jsti_recording_registry_open(const char *history, int initialize, JSTIRecordingRegistry **result,
                                 char *error, size_t capacity) {
    if (result) *result = nullptr;
    try {
        if (!result || (initialize != 0 && initialize != 1)) {
            return jsti::fail("A valid immutable namespace open mode and result are required.", error, capacity);
        }
        auto registry = std::make_unique<JSTIRecordingRegistry>();
        std::vector<std::wstring> parts;
        std::string detail;
        if (!parsePath(history, parts, detail) || !registry->security.initialise(detail)) {
            return jsti::fail(detail, error, capacity);
        }
        parts.push_back(L".recording-locations");
        if (!openParents(parts, registry->parents, detail) ||
            !verifyOwner(registry->parents.back()->value, registry->security, detail) ||
            !openRelative(registry->parents.back()->value, parts.back(),
                          READ_CONTROL | DELETE | FILE_LIST_DIRECTORY | FILE_ADD_FILE |
                              FILE_TRAVERSE | FILE_READ_ATTRIBUTES,
                          initialize ? FILE_CREATE : FILE_OPEN, true,
                          initialize ? &registry->security.descriptor : nullptr,
                          registry->directory, detail) || !registry->validate(detail)) {
            return jsti::fail(detail, error, capacity);
        }
        *result = registry.release();
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Immutable namespace allocation failed.", error, capacity);
    }
}

int jsti_recording_registry_identity(JSTIRecordingRegistry *registry, uint64_t *historyVolume,
                                     uint8_t *historyID, uint64_t *namespaceVolume, uint8_t *namespaceID,
                                     char *error, size_t capacity) {
    std::string detail;
    if (!registry || !historyVolume || !historyID || !namespaceVolume || !namespaceID ||
        !registry->validate(detail)) return jsti::fail("Native recording identity is unavailable.", error, capacity);
    FILE_ID_INFO history{}, directory{};
    if (!GetFileInformationByHandleEx(registry->parents.back()->value, FileIdInfo, &history, sizeof(history)) ||
        !GetFileInformationByHandleEx(registry->directory.value, FileIdInfo, &directory, sizeof(directory))) {
        return jsti::fail(jsti::systemError("Read native 128-bit registration identity"), error, capacity);
    }
    if (std::all_of(std::begin(history.FileId.Identifier), std::end(history.FileId.Identifier),
                    [](BYTE byte) { return byte == 0; }) ||
        std::all_of(std::begin(directory.FileId.Identifier), std::end(directory.FileId.Identifier),
                    [](BYTE byte) { return byte == 0; })) {
        return jsti::fail("The native filesystem did not provide sufficient registration identity.", error, capacity);
    }
    *historyVolume = history.VolumeSerialNumber;
    *namespaceVolume = directory.VolumeSerialNumber;
    std::memcpy(historyID, history.FileId.Identifier, 16);
    std::memcpy(namespaceID, directory.FileId.Identifier, 16);
    if (error && capacity) error[0] = 0;
    return 0;
}

int jsti_recording_registry_names(JSTIRecordingRegistry *registry, char *names, size_t namesCapacity,
                                  size_t *written, uint32_t *count, char *error, size_t capacity) {
    if (written) *written = 0;
    if (count) *count = 0;
    try {
        std::string detail;
        if (!registry || !names || !written || !count || namesCapacity > 256 * 1024 ||
            !registry->validate(detail)) return jsti::fail("Invalid bounded namespace enumeration.", error, capacity);
        alignas(FILE_ID_BOTH_DIR_INFO) std::array<BYTE, 16 * 1024> buffer{};
        bool first = true;
        size_t used = 0;
        uint32_t entries = 0;
        while (true) {
            if (!GetFileInformationByHandleEx(registry->directory.value,
                                             first ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo,
                                             buffer.data(), static_cast<DWORD>(buffer.size()))) {
                if (GetLastError() == ERROR_NO_MORE_FILES) break;
                return jsti::fail(jsti::systemError("Enumerate held private registration namespace"), error, capacity);
            }
            first = false;
            size_t offset = 0;
            while (true) {
                if (offset > buffer.size() - offsetof(FILE_ID_BOTH_DIR_INFO, FileName)) {
                    return jsti::fail("Malformed native registration directory entry.", error, capacity);
                }
                auto *entry = reinterpret_cast<FILE_ID_BOTH_DIR_INFO *>(buffer.data() + offset);
                if (entry->FileNameLength % sizeof(wchar_t) ||
                    entry->FileNameLength > buffer.size() - offset - offsetof(FILE_ID_BOTH_DIR_INFO, FileName)) {
                    return jsti::fail("Oversized native registration directory entry.", error, capacity);
                }
                const std::wstring name(entry->FileName, entry->FileNameLength / sizeof(wchar_t));
                if (name != L"." && name != L"..") {
                    const std::string encoded = jsti::utf8(name);
                    std::wstring verified;
                    if (!registryName(encoded.c_str(), verified, detail) ||
                        (entry->FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
                        ++entries > 4096 || encoded.size() + 1 > namesCapacity - used) {
                        return jsti::fail("Unknown, linked, incomplete or over-budget registration leaf.", error, capacity);
                    }
                    std::memcpy(names + used, encoded.c_str(), encoded.size() + 1);
                    used += encoded.size() + 1;
                }
                if (!entry->NextEntryOffset) break;
                if (entry->NextEntryOffset < offsetof(FILE_ID_BOTH_DIR_INFO, FileName) ||
                    entry->NextEntryOffset > buffer.size() - offset) {
                    return jsti::fail("Invalid native registration directory cursor.", error, capacity);
                }
                offset += entry->NextEntryOffset;
            }
        }
        if (!registry->validate(detail)) return jsti::fail(detail, error, capacity);
        *written = used;
        *count = entries;
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Bounded namespace enumeration allocation failed.", error, capacity);
    }
}

int jsti_recording_registry_read(JSTIRecordingRegistry *registry, const char *name,
                                 uint8_t *bytes, size_t bytesCapacity, size_t *written,
                                 char *error, size_t capacity) {
    if (written) *written = 0;
    try {
        std::string detail;
        std::wstring leaf;
        jsti::Handle file;
        if (!registry || !bytes || !written || bytesCapacity > 16384 || !registry->validate(detail) ||
            !registryName(name, leaf, detail) ||
            !openRelative(registry->directory.value, leaf, FILE_READ_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL,
                          FILE_OPEN, false, nullptr, file, detail, FILE_SHARE_READ) ||
            !registryFile(file.value, registry->security, true, detail)) {
            return jsti::fail(detail.empty() ? "Invalid bounded registration read." : detail, error, capacity);
        }
        LARGE_INTEGER size{};
        if (!GetFileSizeEx(file.value, &size) || size.QuadPart <= 0 ||
            static_cast<ULONGLONG>(size.QuadPart) > bytesCapacity) {
            return jsti::fail("Immutable registration size exceeds its read budget.", error, capacity);
        }
        size_t offset = 0;
        while (offset < static_cast<size_t>(size.QuadPart)) {
            DWORD received = 0;
            if (!ReadFile(file.value, bytes + offset, static_cast<DWORD>(size.QuadPart - offset), &received, nullptr) ||
                !received) return jsti::fail("Immutable registration read failed.", error, capacity);
            offset += received;
        }
        if (!registryFile(file.value, registry->security, true, detail) || !registry->validate(detail)) {
            return jsti::fail(detail, error, capacity);
        }
        const HANDLE owned = file.value;
        file.value = nullptr;
        if (!CloseHandle(owned)) {
            return jsti::fail(jsti::systemError("Close immutable registration reader"), error, capacity);
        }
        *written = offset;
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Bounded registration reader allocation failed.", error, capacity);
    }
}

int jsti_recording_registry_append(JSTIRecordingRegistry *registry, const char *name,
                                   const uint8_t *bytes, size_t count,
                                   jsti_file_publication_cancelled_fn cancelled, void *context, int *published,
                                   char *error, size_t capacity) {
    if (published) *published = 0;
    jsti::Handle file;
    std::string detail;
    int result = -1;
    try {
        std::wstring leaf;
        if (!registry || !published || !bytes || !count || count > 16384 ||
            !registry->validate(detail) || !registryName(name, leaf, detail)) {
            return jsti::fail(detail.empty() ? "Invalid immutable registration append." : detail, error, capacity);
        }
        if (publicationCancelled(cancelled, context)) return 2;
        GUID guid{};
        wchar_t identifier[40]{};
        if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, identifier, 40)) {
            return jsti::fail("Could not allocate a fresh registration staging name.", error, capacity);
        }
        const std::wstring pending = L".pending-" + std::wstring(identifier + 1, 36);
        if (!openRelative(registry->directory.value, pending,
                          FILE_WRITE_DATA | FILE_WRITE_ATTRIBUTES | FILE_READ_ATTRIBUTES | READ_CONTROL | DELETE,
                          FILE_CREATE, false, &registry->security.descriptor, file, detail, FILE_SHARE_READ) ||
            !registryFile(file.value, registry->security, false, detail)) {
            result = -1;
        } else {
            result = 0;
            for (size_t offset = 0; offset < count;) {
                if (publicationCancelled(cancelled, context)) { result = 2; break; }
                DWORD written = 0;
                if (!WriteFile(file.value, bytes + offset, static_cast<DWORD>(count - offset), &written, nullptr) ||
                    !written) {
                    detail = jsti::systemError("Write held immutable registration");
                    result = -1;
                    break;
                }
                offset += written;
            }
            if (result == 0 && (!registryReadOnly(file.value, true, detail) || !FlushFileBuffers(file.value) ||
                                !registryFile(file.value, registry->security, true, detail) ||
                                !registry->validate(detail))) {
                if (detail.empty()) detail = jsti::systemError("Flush held immutable registration");
                result = -1;
            }
            if (result == 0 && publicationCancelled(cancelled, context)) result = 2;
            if (result == 0) {
                if (registryRename(file.value, leaf, detail)) *published = 1;
                else result = -1;
            }
            if (*published && publicationCancelled(cancelled, context)) result = 2;
            if (*published && !registry->validate(detail)) result = -1;
        }
    } catch (const std::exception &) {
        detail = "Immutable registration publication allocation failed.";
        result = -1;
    }
    if (file.value && file.value != INVALID_HANDLE_VALUE) {
        if (published && !*published) {
            FILE_DISPOSITION_INFO disposition{TRUE};
            std::string cleanup;
            if (!registryReadOnly(file.value, false, cleanup) ||
                !SetFileInformationByHandle(file.value, FileDispositionInfo, &disposition, sizeof(disposition))) {
                detail += " Unpublished registration cleanup failed.";
                result = -1;
            }
        }
        const HANDLE owned = file.value;
        file.value = nullptr;
        if (!CloseHandle(owned)) {
            detail += " " + jsti::systemError("Close held registration writer");
            result = -1;
        }
    }
    if (result < 0) return jsti::fail(detail, error, capacity);
    if (error && capacity) error[0] = 0;
    return result;
}

int jsti_recording_registry_close(JSTIRecordingRegistry *registry, char *error, size_t capacity) {
    if (!registry) return jsti::fail("An immutable namespace capability is required.", error, capacity);
    std::string detail;
    if (!registry->close(detail)) return jsti::fail(detail, error, capacity);
    if (error && capacity) error[0] = 0;
    return 0;
}

void jsti_recording_registry_destroy(JSTIRecordingRegistry *registry) {
    if (!registry) return;
    std::string ignored;
    registry->close(ignored);
    delete registry;
}

int jsti_recording_registry_self_test(const char *history, char *error, size_t capacity) {
    try {
        char detail[1024]{};
        if (jsti_private_directory_create(history, detail, sizeof(detail))) return jsti::fail(detail, error, capacity);
        JSTIRecordingRegistry *raw = nullptr;
        if (jsti_recording_registry_open(history, 1, &raw, detail, sizeof(detail))) {
            return jsti::fail(detail, error, capacity);
        }
        auto deleter = [](JSTIRecordingRegistry *value) { jsti_recording_registry_destroy(value); };
        std::unique_ptr<JSTIRecordingRegistry, decltype(deleter)> registry(raw, deleter);
        JSTIRecordingRegistry *competing = nullptr;
        if (jsti_recording_registry_open(history, 0, &competing, detail, sizeof(detail)) != -1 || competing) {
            jsti_recording_registry_destroy(competing);
            return jsti::fail("A competing native namespace capability bypassed its held sharing lock.", error, capacity);
        }
        const std::array<uint8_t, 8> payload{'J', 'S', 'T', 'I', 'R', 'E', 'G', 1};
        int effect = -1;
        if (jsti_recording_registry_append(raw, "registry.jloc", payload.data(), payload.size(),
                                           nullptr, nullptr, &effect, detail, sizeof(detail)) || effect != 1) {
            return jsti::fail(detail, error, capacity);
        }
        if (jsti_recording_registry_append(raw, "registry.jloc", payload.data(), payload.size(),
                                           nullptr, nullptr, &effect, detail, sizeof(detail)) != -1 || effect != 0) {
            return jsti::fail("Immutable native append replaced an existing leaf.", error, capacity);
        }
        uint64_t historyVolume = 0, namespaceVolume = 0;
        uint8_t historyID[16]{}, namespaceID[16]{};
        if (jsti_recording_registry_identity(raw, &historyVolume, historyID, &namespaceVolume, namespaceID,
                                             detail, sizeof(detail))) return jsti::fail(detail, error, capacity);
        std::vector<char> names(256 * 1024);
        size_t written = 0;
        uint32_t count = 0;
        if (jsti_recording_registry_names(raw, names.data(), names.size(), &written, &count, detail, sizeof(detail)) ||
            count != 1 || std::string(names.data()) != "registry.jloc") {
            return jsti::fail("Native immutable enumeration lost its only owned leaf.", error, capacity);
        }
        std::wstring historyPath;
        if (!jsti::wide(history, historyPath)) return jsti::fail("Invalid fixture path.", error, capacity);
        const std::wstring root = historyPath + L"\\.recording-locations";
        if (MoveFileW(root.c_str(), (root + L".replaced").c_str())) {
            return jsti::fail("Held native namespace allowed replacement.", error, capacity);
        }
        if (MoveFileW(historyPath.c_str(), (historyPath + L".replaced").c_str())) {
            return jsti::fail("Held native History ancestry allowed replacement.", error, capacity);
        }
        struct Cancellation { int calls = 0; int target; };
        const auto cancel = [](void *context) -> int {
            auto *value = static_cast<Cancellation *>(context);
            return ++value->calls == value->target;
        };
        const char *leaves[] = {"registration-AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA.jloc",
                                "registration-BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB.jloc"};
        for (int index = 0; index < 2; ++index) {
            Cancellation cancellation{0, index == 0 ? 3 : 4};
            if (jsti_recording_registry_append(raw, leaves[index], payload.data(), payload.size(),
                                               cancel, &cancellation, &effect, detail, sizeof(detail)) != 2 ||
                effect != index) {
                return jsti::fail("Native registration cancellation lost its publication effect.", error, capacity);
            }
        }
        if (jsti_recording_registry_close(raw, detail, sizeof(detail)) ||
            jsti_recording_registry_close(raw, detail, sizeof(detail))) return jsti::fail(detail, error, capacity);
        registry.reset();
        if (jsti_recording_registry_open(history, 0, &raw, detail, sizeof(detail))) {
            return jsti::fail(detail, error, capacity);
        }
        registry.reset(raw);
        std::array<uint8_t, 16384> bytes{};
        if (jsti_recording_registry_read(raw, "registry.jloc", bytes.data(), bytes.size(), &written,
                                         detail, sizeof(detail)) || written != payload.size() ||
            !std::equal(payload.begin(), payload.end(), bytes.begin())) {
            return jsti::fail("Native closed-writer reload did not preserve immutable bytes.", error, capacity);
        }
        if (jsti_recording_registry_names(raw, names.data(), names.size(), &written, &count, detail, sizeof(detail)) ||
            count != 2) return jsti::fail("Native cancellation left an unexpected pending leaf.", error, capacity);
        if (jsti_recording_registry_read(raw, leaves[0], bytes.data(), bytes.size(), &written,
                                         detail, sizeof(detail)) != -1) {
            return jsti::fail("Cancelled unpublished leaf became readable.", error, capacity);
        }
        if (jsti_recording_registry_close(raw, detail, sizeof(detail))) return jsti::fail(detail, error, capacity);
        registry.reset();
        std::string sourceError;
        if (!registryRejectedSourceFixtures(historyPath, root, sourceError)) {
            return jsti::fail(sourceError, error, capacity);
        }
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Native immutable recording fixture allocation failed.", error, capacity);
    }
}
