// The asynchronous Media Foundation source reader shared by audio conversion
// (WindowsAudioConversion.cpp) and playback (WindowsPlaybackDecoder.cpp): the
// local-path check for its input, the state one pending ReadSample reports
// into, its callback and its bounded close. Not public ABI.
#pragma once

#include "WindowsSupportInternal.hpp"
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <utility>

namespace jsti::media {

// A local drive path ("C:\..." without device, stream or reserved parts),
// returned with the \\?\ prefix. False for anything else.
bool localPath(const char *text, std::wstring &path);

// What one pending ReadSample reports, guarded by `mutex`. Once `closed`, late
// callbacks change nothing.
struct ReadState {
    std::mutex mutex;
    std::condition_variable changed;
    bool pending = false, ready = false, flushed = false, closed = false;
    HRESULT result = S_OK;
    DWORD flags = 0;
    IMFSample *sample = nullptr;
    ~ReadState() { if (sample) sample->Release(); }
};

// Publishes the reader's samples, flushes and errors into `State` (a ReadState).
template<typename State>
class ReaderCallback final : public IMFSourceReaderCallback {
    std::atomic<ULONG> references{1};
    const std::shared_ptr<State> state;
public:
    explicit ReaderCallback(std::shared_ptr<State> state) : state(std::move(state)) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (id != IID_IUnknown && id != IID_IMFSourceReaderCallback) return E_NOINTERFACE;
        *result = static_cast<IMFSourceReaderCallback *>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override { const ULONG count = --references; if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE OnReadSample(HRESULT result, DWORD, DWORD flags, LONGLONG, IMFSample *sample) override {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->closed || !state->pending) return S_OK;
        state->pending = false;
        state->ready = true;
        if (SUCCEEDED(state->result)) state->result = result;
        state->flags = flags;
        if (state->sample) state->sample->Release();
        state->sample = sample;
        if (sample) sample->AddRef();
        state->changed.notify_all();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnFlush(DWORD) override {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->pending = false;
        state->flushed = true;
        state->changed.notify_all();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnEvent(DWORD, IMFMediaEvent *event) override {
        HRESULT result = S_OK;
        if (event) event->GetStatus(&result);
        if (FAILED(result)) {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->closed) { state->result = result; state->changed.notify_all(); }
        }
        return S_OK;
    }
};

// Owns the reader. Closing flushes a pending read (waiting at most five
// seconds for OnFlush), marks the state closed so late callbacks are ignored,
// drops any sample it holds and releases the reader. A closed state is not reused.
template<typename State>
struct ReaderResources {
    jsti::COM<IMFSourceReader> reader;
    const std::shared_ptr<State> state;
    explicit ReaderResources(std::shared_ptr<State> state) : state(std::move(state)) {}
    ~ReaderResources() { close(); }
    HRESULT close() {
        if (!reader.value) return S_OK;
        bool pending;
        { std::lock_guard<std::mutex> lock(state->mutex); pending = state->pending; state->flushed = false; }
        HRESULT result = S_OK;
        if (pending) {
            result = reader->Flush(MF_SOURCE_READER_ALL_STREAMS);
            if (SUCCEEDED(result)) {
                std::unique_lock<std::mutex> lock(state->mutex);
                if (!state->changed.wait_for(lock, std::chrono::seconds(5), [&] { return state->flushed; })) {
                    result = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
                }
            }
        }
        IMFSample *sample = nullptr;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->closed = true;
            sample = state->sample;
            state->sample = nullptr;
        }
        if (sample) sample->Release();
        reader.value->Release();
        reader.value = nullptr;
        return result;
    }
};

} // namespace jsti::media
