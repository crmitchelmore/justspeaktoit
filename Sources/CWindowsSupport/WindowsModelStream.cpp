#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <io.h>
#include <mutex>
#include <system_error>
#include <thread>
#include <vector>

// A model file read on a thread of its own into a few chunk buffers. The
// loader waits only on these buffers and gives up whenever its job is
// cancelled; a reader left blocked in a read keeps only its thread, file and
// buffers, and frees them once that read returns.
namespace jsti {
namespace {
constexpr size_t slotCount = 4;
constexpr auto pollInterval = std::chrono::milliseconds(50);
}

struct ModelStreamState {
    mutable std::mutex lock;
    std::condition_variable changed;
    std::wstring path;
    std::vector<unsigned char> slots[slotCount];
    size_t lengths[slotCount] = {};
    size_t first = 0;    // The oldest filled slot.
    size_t filled = 0;   // Filled slots, from first.
    size_t offset = 0;   // Bytes already taken from the oldest slot.
    size_t buffered = 0; // Bytes filled and not yet taken.
    bool ended = false;
    bool failed = false;
    bool closed = false; // The loader is done with the stream.
    ModelStreamFailure why = ModelStreamFailure::none;
};

namespace {
// Admits a file on disk or a pipe, whose bytes end when its writer closes. A
// character device (NUL, a console, a serial port), which may never end, is
// refused before any read.
FILE *openModel(const std::wstring &path, ModelStreamFailure &why) {
    why = ModelStreamFailure::unopened;
    FILE *file = nullptr;
    if (_wfopen_s(&file, path.c_str(), L"rb") != 0 || !file) return nullptr;
    const auto handle = reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(file)));
    const DWORD type = handle == INVALID_HANDLE_VALUE ? FILE_TYPE_UNKNOWN : GetFileType(handle);
    if (type != FILE_TYPE_DISK && type != FILE_TYPE_PIPE) {
        std::fclose(file);
        why = ModelStreamFailure::notAFile;
        return nullptr;
    }
    why = ModelStreamFailure::none;
    return file;
}

void readModel(std::shared_ptr<ModelStreamState> state) {
    ModelStreamFailure why = ModelStreamFailure::none;
    FILE *file = openModel(state->path, why);
    std::unique_lock<std::mutex> lock(state->lock);
    state->failed = !file;
    state->why = why;
    state->changed.notify_all();
    while (file && !state->closed && !state->ended && !state->failed) {
        if (state->filled == slotCount) {
            state->changed.wait(lock);
            continue;
        }
        // The slot after the filled ones is the reader's alone until published.
        const size_t slot = (state->first + state->filled) % slotCount;
        unsigned char *buffer = state->slots[slot].data();
        lock.unlock();
        const size_t count = std::fread(buffer, 1, modelStreamChunk, file);
        const bool error = count < modelStreamChunk && std::ferror(file) != 0;
        lock.lock();
        if (count > 0) {
            state->lengths[slot] = count;
            state->filled++;
            state->buffered += count;
        }
        if (count < modelStreamChunk) {
            state->ended = !error;
            state->failed = error;
            if (error) state->why = ModelStreamFailure::readError;
        }
        state->changed.notify_all();
    }
    lock.unlock();
    if (file) std::fclose(file);
}
}

ModelStream::~ModelStream() {
    if (!state) return;
    std::lock_guard<std::mutex> guard(state->lock);
    state->closed = true;
    state->changed.notify_all();
}

bool ModelStream::open(const std::wstring &path, std::string &error) {
    auto created = std::make_shared<ModelStreamState>();
    created->path = path;
    for (auto &slot : created->slots) slot.resize(modelStreamChunk);
    try {
        std::thread(readModel, created).detach();
    } catch (const std::system_error &failure) {
        error = std::string("Could not start reading the model: ") + failure.what();
        return false;
    }
    state = std::move(created);
    return true;
}

bool ModelStream::wait(size_t bytes, Cancelled cancelled, void *data) {
    std::unique_lock<std::mutex> lock(state->lock);
    while (true) {
        if (state->buffered >= bytes || state->ended || state->failed) return true;
        if (cancelled(data)) return false;
        state->changed.wait_for(lock, pollInterval);
    }
}

size_t ModelStream::take(void *output, size_t size, Cancelled cancelled, void *data, bool &wasCancelled) {
    auto *bytes = static_cast<unsigned char *>(output);
    size_t done = 0;
    wasCancelled = false;
    std::unique_lock<std::mutex> lock(state->lock);
    while (done < size) {
        if (state->filled > 0) {
            const size_t slot = state->first;
            const size_t count = (std::min)(size - done, state->lengths[slot] - state->offset);
            std::memcpy(bytes + done, state->slots[slot].data() + state->offset, count);
            done += count;
            state->offset += count;
            state->buffered -= count;
            if (state->offset == state->lengths[slot]) {
                state->first = (slot + 1) % slotCount;
                state->filled--;
                state->offset = 0;
                state->changed.notify_all();
            }
        } else if (state->ended || state->failed) {
            break;
        } else if (cancelled(data)) {
            wasCancelled = true;
            break;
        } else {
            state->changed.wait_for(lock, pollInterval);
        }
    }
    return done;
}

ModelStreamFailure ModelStream::failure() const {
    std::lock_guard<std::mutex> guard(state->lock);
    return state->why;
}
}
