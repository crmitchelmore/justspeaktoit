// Held capture files: a private recording leaf whose ancestors stay pinned until it is
// closed, discarded or published.
#include "WindowsFileSecurityInternal.hpp"

using namespace jsti_file_security;

struct JSTIOwnedCaptureFile {
    PrivateSecurity security;
    std::vector<std::unique_ptr<jsti::Handle>> anchors;
    jsti::Handle file;
    bool closed = false;
    bool removed = false;

    bool requireOpen(std::string &error) const {
        if (closed || removed || !file.value || file.value == INVALID_HANDLE_VALUE) {
            error = "The held recording file is closed or discarded.";
            return false;
        }
        return true;
    }

    bool validate(std::string &error) const {
        if (!requireOpen(error)) return false;
        for (const auto &anchor : anchors) {
            if (!checkDirectory(anchor->value, error)) return false;
        }
        if (anchors.empty() || !verifyPrivate(anchors.back()->value, security, error) ||
            !verifyPrivate(file.value, security, error)) return false;
        FILE_ATTRIBUTE_TAG_INFO attributes{};
        BY_HANDLE_FILE_INFORMATION identity{};
        if (!GetFileInformationByHandleEx(file.value, FileAttributeTagInfo, &attributes, sizeof(attributes)) ||
            !GetFileInformationByHandle(file.value, &identity)) {
            error = jsti::systemError("Inspect held recording file");
            return false;
        }
        if (GetFileType(file.value) != FILE_TYPE_DISK ||
            (attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
            identity.nNumberOfLinks != 1) {
            error = "Held recording audio must be a regular non-reparse file with exactly one link.";
            return false;
        }
        return true;
    }

    bool discard(std::string &error) {
        if (!requireOpen(error)) return false;
        // The actual exclusively created handle is deletion authority, not a
        // pathname, identity reread, or compare-and-swap receipt.
        FILE_DISPOSITION_INFO disposition{TRUE};
        if (!SetFileInformationByHandle(file.value, FileDispositionInfo, &disposition, sizeof(disposition))) {
            error = jsti::systemError("Discard held unpublished recording");
            return false;
        }
        removed = true;
        return true;
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
                error += jsti::systemError("Close held recording capability");
                success = false;
            }
        };
        release(file);
        for (auto iterator = anchors.rbegin(); iterator != anchors.rend(); ++iterator) release(**iterator);
        return success;
    }
};

namespace jsti_file_security {
bool captureUUID(const char *value, std::wstring &result, std::string &error) {
    if (!value || std::strlen(value) != 36) {
        error = "Held capture identifiers must be UUID strings.";
        return false;
    }
    for (size_t index = 0; index < 36; ++index) {
        const char ch = value[index];
        const bool separator = index == 8 || index == 13 || index == 18 || index == 23;
        if (separator ? ch != '-' : !((ch >= '0' && ch <= '9') ||
                                      (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F'))) {
            error = "Held capture identifiers contain an unsafe component.";
            return false;
        }
    }
    return jsti::wide(value, result);
}
} // namespace jsti_file_security

namespace {
int captureResult(bool success, const std::string &detail, char *error, size_t capacity) {
    if (!success) return jsti::fail(detail, error, capacity);
    if (error && capacity) error[0] = 0;
    return 0;
}

template<class Work>
int captureOperation(JSTIOwnedCaptureFile *file, char *error, size_t capacity, Work work) {
    if (!file) return jsti::fail("Missing held recording file.", error, capacity);
    try {
        std::string detail;
        const bool success = work(*file, detail);
        return captureResult(success, detail, error, capacity);
    } catch (const std::exception &) {
        return jsti::fail("The held recording operation could not allocate its state.", error, capacity);
    }
}

int failedCaptureAllocation(std::unique_ptr<JSTIOwnedCaptureFile> &capture, std::string detail,
                            char *error, size_t capacity) {
    if (capture) {
        std::string cleanup;
        if (capture->file.value && capture->file.value != INVALID_HANDLE_VALUE && !capture->removed) {
            if (!capture->discard(cleanup)) detail += " " + cleanup;
        }
        cleanup.clear();
        if (!capture->close(cleanup)) detail += " " + cleanup;
    }
    return jsti::fail(detail, error, capacity);
}
} // namespace

int jsti_owned_capture_file_create(const char *root, const char *directoryID, const char *recordingID,
                                   JSTIOwnedCaptureFile **result, char *error, size_t capacity) {
    if (!result) return jsti::fail("A held capture output pointer is required.", error, capacity);
    *result = nullptr;
    std::unique_ptr<JSTIOwnedCaptureFile> capture;
    try {
        capture = std::make_unique<JSTIOwnedCaptureFile>();
        std::string detail;
        std::wstring directory, recording;
        std::vector<std::wstring> components;
        if (!captureUUID(directoryID, directory, detail) || !captureUUID(recordingID, recording, detail) ||
            !parsePath(root, components, detail) || !capture->security.initialise(detail) ||
            !openParents(components, capture->anchors, detail)) {
            return failedCaptureAllocation(capture, detail, error, capacity);
        }
        auto selected = std::make_unique<jsti::Handle>();
        if (!openRelative(capture->anchors.back()->value, components.back(),
                          FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL | FILE_ADD_SUBDIRECTORY,
                          FILE_OPEN, true, nullptr, *selected, detail)) {
            return failedCaptureAllocation(capture, detail, error, capacity);
        }
        capture->anchors.push_back(std::move(selected));
        auto leaf = std::make_unique<jsti::Handle>();
        if (!openRelative(capture->anchors.back()->value, directory,
                          FILE_TRAVERSE | FILE_ADD_FILE | FILE_READ_ATTRIBUTES | READ_CONTROL,
                          FILE_CREATE, true, &capture->security.descriptor, *leaf, detail) ||
            !verifyPrivate(leaf->value, capture->security, detail)) {
            return failedCaptureAllocation(capture, detail, error, capacity);
        }
        capture->anchors.push_back(std::move(leaf));
        if (!openRelative(capture->anchors.back()->value, recording + L".wav",
                          READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_READ_DATA | FILE_WRITE_DATA | DELETE,
                          FILE_CREATE, false, &capture->security.descriptor, capture->file, detail, FILE_SHARE_READ) ||
            !capture->validate(detail)) {
            return failedCaptureAllocation(capture, detail, error, capacity);
        }
        *result = capture.release();
        return captureResult(true, "", error, capacity);
    } catch (const std::exception &) {
        return failedCaptureAllocation(capture, "Could not allocate held recording state.", error, capacity);
    }
}

int jsti_owned_capture_file_write(JSTIOwnedCaptureFile *file, const uint8_t *bytes, size_t count,
                                  char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [&](auto &owned, auto &detail) {
        if (!owned.requireOpen(detail)) return false;
        if (!bytes && count) { detail = "Missing recording bytes."; return false; }
        for (size_t offset = 0; offset < count;) {
            DWORD written = 0;
            const DWORD requested = static_cast<DWORD>(std::min<size_t>(count - offset, 64 * 1024));
            if (!WriteFile(owned.file.value, bytes + offset, requested, &written, nullptr)) {
                detail = jsti::systemError("Write held recording");
                return false;
            }
            if (!written) { detail = "The held recording writer made no progress."; return false; }
            offset += written;
        }
        return true;
    });
}

int jsti_owned_capture_file_seek(JSTIOwnedCaptureFile *file, uint64_t offset, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [&](auto &owned, auto &detail) {
        if (!owned.requireOpen(detail)) return false;
        if (offset > static_cast<uint64_t>((std::numeric_limits<LONGLONG>::max)())) {
            detail = "Held recording offset is out of range.";
            return false;
        }
        LARGE_INTEGER position{};
        position.QuadPart = static_cast<LONGLONG>(offset);
        if (!SetFilePointerEx(owned.file.value, position, nullptr, FILE_BEGIN)) {
            detail = jsti::systemError("Seek held recording");
            return false;
        }
        return true;
    });
}

int jsti_owned_capture_file_flush(JSTIOwnedCaptureFile *file, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [](auto &owned, auto &detail) {
        if (!owned.requireOpen(detail)) return false;
        if (!FlushFileBuffers(owned.file.value)) {
            detail = jsti::systemError("Flush held recording");
            return false;
        }
        return true;
    });
}

int jsti_owned_capture_file_validate(JSTIOwnedCaptureFile *file, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [](auto &owned, auto &detail) { return owned.validate(detail); });
}

int jsti_owned_capture_file_discard(JSTIOwnedCaptureFile *file, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [](auto &owned, auto &detail) { return owned.discard(detail); });
}

int jsti_owned_capture_file_close(JSTIOwnedCaptureFile *file, char *error, size_t capacity) {
    return captureOperation(file, error, capacity, [](auto &owned, auto &detail) { return owned.close(detail); });
}

void jsti_owned_capture_file_destroy(JSTIOwnedCaptureFile *file) { delete file; }

int jsti_owned_capture_file_self_test(const char *root, char *error, size_t capacity) {
    try {
        std::wstring base;
        std::string detail;
        std::vector<std::wstring> rootParts;
        GUID guid{};
        wchar_t identifier[40]{};
        if (!parsePath(root, rootParts, detail) || FAILED(CoCreateGuid(&guid)) ||
            !StringFromGUID2(guid, identifier, static_cast<int>(std::size(identifier)))) {
            return jsti::fail("Could not allocate a held-capture test identity.", error, capacity);
        }
        base = rootParts.front();
        for (size_t index = 1; index < rootParts.size(); ++index) {
            if (base.back() != L'\\') base += L'\\';
            base += rootParts[index];
        }
        const std::wstring directoryID(identifier + 1, 36);
        const std::string directory = jsti::utf8(directoryID);
        const char *recording = "00000000-0000-4000-8000-000000000002";
        const std::wstring selected = base + L"\\selected-" + directoryID;
        const std::wstring folder = selected + L"\\" + directoryID;
        const std::wstring audio = folder + L"\\00000000-0000-4000-8000-000000000002.wav";
        const std::wstring target = base + L"\\target-" + directoryID;
        const std::wstring junction = base + L"\\junction-" + directoryID;
        char local[2048]{};
        auto fail = [&](const std::string &message) { return jsti::fail(message, error, capacity); };
        if (jsti_private_directory_create(jsti::utf8(selected).c_str(), local, sizeof(local)) != 0 ||
            jsti_private_directory_create(jsti::utf8(target).c_str(), local, sizeof(local)) != 0 ||
            jsti_private_directory_create(jsti::utf8(target + L"\\child").c_str(), local, sizeof(local)) != 0) {
            return fail(local);
        }
        for (const char *invalid : {"..", "relative\\name", "00000000-0000-4000-8000-00000000000:"}) {
            JSTIOwnedCaptureFile *unexpected = nullptr;
            if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), invalid, recording,
                                               &unexpected, local, sizeof(local)) == 0 || unexpected || !local[0]) {
                std::unique_ptr<JSTIOwnedCaptureFile> owner(unexpected);
                return fail("Held capture accepted a non-UUID ownership component.");
            }
        }
        JSTIOwnedCaptureFile *raw = nullptr;
        if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), directory.c_str(), recording,
                                           &raw, local, sizeof(local)) != 0) return fail(local);
        std::unique_ptr<JSTIOwnedCaptureFile> capture(raw);
        const uint8_t pcm[] = {1, 2, 3, 4};
        const uint8_t patch[] = {9, 8};
        if (jsti_owned_capture_file_write(raw, pcm, sizeof(pcm), local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_seek(raw, 0, local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_write(raw, patch, sizeof(patch), local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_flush(raw, local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_validate(raw, local, sizeof(local)) != 0) return fail(local);
        {
            jsti::Handle permissions;
            permissions.value = CreateFileW(folder.c_str(), WRITE_DAC | READ_CONTROL,
                                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                                              FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            if (permissions.value == INVALID_HANDLE_VALUE ||
                SetSecurityInfo(permissions.value, SE_FILE_OBJECT,
                                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                                nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS) {
                return fail(jsti::systemError("Set synthetic non-private capture ACL"));
            }
            const bool rejected = jsti_owned_capture_file_validate(raw, local, sizeof(local)) != 0 && local[0];
            const DWORD restored = SetSecurityInfo(
                permissions.value, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                nullptr, nullptr, static_cast<PACL>(capture->security.acl.value), nullptr);
            if (restored != ERROR_SUCCESS || !rejected ||
                jsti_owned_capture_file_validate(raw, local, sizeof(local)) != 0) {
                return fail("Held capture did not reject and recover from a synthetic insecure private-leaf ACL.");
            }
        }
        jsti::Handle competing;
        competing.value = CreateFileW(audio.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE |
                                      FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
        if (competing.value != INVALID_HANDLE_VALUE) return fail("Held audio admitted a competing writer.");
        for (const auto &path : {selected, folder, audio}) {
            if (MoveFileW(path.c_str(), (path + L".replacement").c_str())) {
                return fail("A held root, private directory or audio file was renamed.");
            }
        }
        JSTIOwnedCaptureFile *collision = nullptr;
        if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), directory.c_str(), recording,
                                           &collision, local, sizeof(local)) == 0 || collision) {
            std::unique_ptr<JSTIOwnedCaptureFile> unexpected(collision);
            return fail("Held capture did not create its UUID directory exclusively.");
        }
        const std::wstring junctionTarget = target.substr(4);
        if (!createTestJunction(junction, junctionTarget, detail)) return fail(detail);
        for (const auto &path : {junction, junction + L"\\child"}) {
            JSTIOwnedCaptureFile *linked = nullptr;
            if (jsti_owned_capture_file_create(jsti::utf8(path).c_str(), directory.c_str(), recording,
                                               &linked, local, sizeof(local)) == 0 || linked) {
                std::unique_ptr<JSTIOwnedCaptureFile> unexpected(linked);
                return fail("Held capture traversed a junction in its root or ancestry.");
            }
        }
        const std::wstring linkedID = L"00000000-0000-4000-8000-000000000004";
        if (!createTestJunction(selected + L"\\" + linkedID, junctionTarget, detail)) return fail(detail);
        JSTIOwnedCaptureFile *linkedLeaf = nullptr;
        if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), jsti::utf8(linkedID).c_str(), recording,
                                           &linkedLeaf, local, sizeof(local)) == 0 || linkedLeaf) {
            std::unique_ptr<JSTIOwnedCaptureFile> unexpected(linkedLeaf);
            return fail("An existing UUID junction was treated as a new owned leaf.");
        }
        // Close releases the pins, but retains bytes. Prove the rename failures
        // above were held-handle exclusion, not missing user permissions.
        if (jsti_owned_capture_file_close(raw, local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_close(raw, local, sizeof(local)) != 0) return fail(local);
        for (const auto &path : {audio, folder, selected}) {
            const std::wstring moved = path + L".replacement";
            if (!MoveFileW(path.c_str(), moved.c_str()) || !MoveFileW(moved.c_str(), path.c_str())) {
                return fail(jsti::systemError("Rename released capture fixture"));
            }
        }
        if (jsti_owned_capture_file_write(raw, pcm, sizeof(pcm), local, sizeof(local)) == 0 ||
            jsti_owned_capture_file_seek(raw, 0, local, sizeof(local)) == 0 ||
            jsti_owned_capture_file_flush(raw, local, sizeof(local)) == 0 ||
            jsti_owned_capture_file_validate(raw, local, sizeof(local)) == 0 ||
            jsti_owned_capture_file_discard(raw, local, sizeof(local)) == 0) {
            return fail("A closed capture capability admitted mutation.");
        }
        jsti::Handle reader;
        reader.value = CreateFileW(audio.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE |
                                   FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
        uint8_t bytes[4]{};
        DWORD count = 0;
        if (reader.value == INVALID_HANDLE_VALUE || !ReadFile(reader.value, bytes, 4, &count, nullptr) ||
            count != 4 || bytes[0] != 9 || bytes[1] != 8 || bytes[2] != 3 || bytes[3] != 4) {
            return fail("Held write/seek/flush/close did not preserve the expected bytes.");
        }
        const char *cancelID = "00000000-0000-4000-8000-000000000003";
        JSTIOwnedCaptureFile *cancelled = nullptr;
        if (jsti_owned_capture_file_create(jsti::utf8(selected).c_str(), cancelID, recording,
                                           &cancelled, local, sizeof(local)) != 0) return fail(local);
        std::unique_ptr<JSTIOwnedCaptureFile> cancelOwner(cancelled);
        if (jsti_owned_capture_file_write(cancelled, pcm, sizeof(pcm), local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_discard(cancelled, local, sizeof(local)) != 0 ||
            jsti_owned_capture_file_close(cancelled, local, sizeof(local)) != 0) return fail(local);
        const std::wstring cancelDirectory = selected + L"\\00000000-0000-4000-8000-000000000003";
        const DWORD cancelAttributes = GetFileAttributesW(cancelDirectory.c_str());
        if (GetFileAttributesW((cancelDirectory + L"\\00000000-0000-4000-8000-000000000002.wav").c_str())
                != INVALID_FILE_ATTRIBUTES ||
            cancelAttributes == INVALID_FILE_ATTRIBUTES || !(cancelAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
            GetFileAttributesW(audio.c_str()) == INVALID_FILE_ATTRIBUTES) {
            return fail("Discard removed an unrelated file or failed to keep the empty private directory.");
        }
        return captureResult(true, "", error, capacity);
    } catch (const std::exception &) {
        return jsti::fail("Could not allocate the held-capture native fixture.", error, capacity);
    }
}

