#pragma once

// Internal surface of the native History playback engine, shared by
// WindowsPlayback.cpp (production engine and public C API) and
// WindowsPlaybackSelfTest.cpp (synthetic checks). Nothing here is public ABI.
//
// Pipeline: one pinned read-only handle streams through installed Media
// Foundation codecs on a decode worker, decoded PCM crosses a fixed
// single-producer/single-consumer byte ring, and an event-driven render thread
// copies whole frames into the output. The output is an injectable seam so the
// same render loop runs against WASAPI in production and against a synthetic
// engine in tests without an endpoint.
#include "WindowsSupportInternal.hpp"
#include <mmreg.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct JSTIAudioPlayback;
typedef void (*JSTIAudioPlaybackCallback)(int status, double played_seconds, const char *error, void *context);

namespace jsti::playback {
// Two-hour 24 kHz PCM16 history recordings are about 346 MB. The bound keeps
// headroom for longer or multichannel sources while refusing unbounded input.
constexpr uint64_t inputLimit = uint64_t{1} << 30;
constexpr uint32_t maximumChannels = 8;
constexpr uint32_t minimumRate = 8000;
constexpr uint32_t maximumRate = 384000;
// Bounds the decoded queue: two seconds of the output format, or twice the
// render buffer, whichever is larger. With the byte-rate cap and the buffer
// bound the queue never exceeds 64 MiB; 48 kHz stereo float uses 768 KiB.
constexpr uint64_t maximumByteRate = uint64_t{16} << 20;
constexpr uint64_t queueSeconds = 2;
constexpr uint32_t maximumBufferSeconds = 2;
// One decoded Media Foundation sample is coalesced into a contiguous buffer
// before it is copied into the ring. That app-owned allocation is bounded to
// four seconds of the output format, clamped between 1 MiB and 64 MiB.
constexpr uint64_t sampleBoundSeconds = 4;
constexpr uint64_t minimumSampleBound = uint64_t{1} << 20;
constexpr uint64_t maximumSampleBound = uint64_t{64} << 20;
constexpr REFERENCE_TIME renderBufferDuration = 5000000; // 500 ms shared-mode render buffer.
constexpr DWORD defaultEventTimeout = 5000;              // A started engine silent for 5 s is a failure.
constexpr DWORD pausedWaitSlice = 1000;                  // Paused waits never expire into a failure.
constexpr DWORD decodeTimeoutSeconds = 30;
constexpr ULONGLONG drainGrace = 2000;                   // Beyond the buffer duration, in milliseconds.
constexpr DWORD maximumLatencyWait = 500;                // Bounded wait for the device's own latency.
// Well-known speaker positions used when a source has no channel mask.
constexpr uint32_t monoMask = 0x4;   // SPEAKER_FRONT_CENTER
constexpr uint32_t stereoMask = 0x3; // SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT

// Snapshot states published for the host (JSTIAudioPlaybackSnapshot.state).
constexpr int statePreparing = 0;
constexpr int statePlaying = 1;
constexpr int statePaused = 2;
constexpr int stateEnded = 3;
// Output acknowledgement (JSTIAudioPlaybackSnapshot.output_state): the engine
// was never started, was started (running or paused, so it may start again),
// or has been stopped by the render thread for good.
constexpr int outputNeverStarted = 0;
constexpr int outputStarted = 1;
constexpr int outputStopped = 2;
// Bound on a test read gate so a forgotten gate can never hang a run forever.
constexpr DWORD readGateTimeout = 30000;

struct Failure { HRESULT code; const char *operation; };
struct Cancelled {};
// The render thread ended (cancelled or failed) while decoding was still
// queueing audio; its recorded outcome becomes the completion.
struct RenderStopped {};

void require(HRESULT result, const char *operation);
// "operation (HRESULT 0x........)." into a caller buffer; never allocates.
void describe(const Failure &failure, char *buffer, size_t capacity);
std::string describe(const Failure &failure);

bool localPath(const char *text, std::wstring &path);
// Pins the input: read-only, write/delete sharing denied, leaf reparse points
// refused, regular disk files of 1 byte to `limit` bytes only. Nothing beyond
// the size query is read here; Media Foundation streams what it needs later.
void openSource(const std::wstring &path, uint64_t limit, jsti::Handle &handle, uint64_t &size);

// Optional OS component: a missing Media Foundation DLL (Windows N without the
// Media Feature Pack) must never prevent the application from launching. The
// modules live for the process, like any late internal Media Foundation
// teardown work after a cancelled playback.
struct MediaAPI {
    using Start = HRESULT (WINAPI *)(ULONG, DWORD);
    using Stop = HRESULT (WINAPI *)();
    using Attributes = HRESULT (WINAPI *)(IMFAttributes **, UINT32);
    using Type = HRESULT (WINAPI *)(IMFMediaType **);
    using TypeFromWave = HRESULT (WINAPI *)(IMFMediaType *, const WAVEFORMATEX *, UINT32);
    using ByteStream = HRESULT (WINAPI *)(IStream *, IMFByteStream **);
    using Reader = HRESULT (WINAPI *)(IMFByteStream *, IMFAttributes *, IMFSourceReader **);
    Start start = nullptr;
    Stop stop = nullptr;
    Attributes attributes = nullptr;
    Type type = nullptr;
    TypeFromWave typeFromWave = nullptr;
    ByteStream byteStream = nullptr;
    Reader reader = nullptr;
    DWORD error = ERROR_MOD_NOT_FOUND;
    MediaAPI();
    static MediaAPI &shared();
};

struct MediaPlatform {
    bool com = false, media = false;
    ~MediaPlatform();
    void initialise();
};

// The exact WAVEFORMATEX bytes handed to Windows plus the fields checked
// against the decoder's actual output so fidelity at the endpoint is verified.
struct FormatSpec {
    std::vector<uint8_t> bytes;
    GUID subtype{};
    uint32_t rate = 0, channels = 0, bits = 0, blockAlign = 0, mask = 0;
    const WAVEFORMATEX *wave() const { return reinterpret_cast<const WAVEFORMATEX *>(bytes.data()); }
    UINT32 size() const { return static_cast<UINT32>(bytes.size()); }
    uint64_t byteRate() const { return uint64_t{rate} * blockAlign; }
};
FormatSpec parseFormat(const WAVEFORMATEX *wave, size_t size);
FormatSpec floatFormat(uint32_t rate, uint32_t channels, uint32_t mask);
FormatSpec pcm16Format(uint32_t rate, uint32_t channels);
// The decoded-sample coalescing bound for a format (see sampleBoundSeconds).
uint64_t sampleBound(const FormatSpec &format);

// Single producer (decode worker) and single consumer (render thread) byte
// queue over one fixed allocation. Writes accept any byte count so a decoded
// sample larger than the free space is copied in pieces; reads only ever hand
// out whole frames. No allocation, mutex or file I/O on either side.
class PCMByteRing {
    std::vector<uint8_t> bytes;
    const size_t capacity;
    const size_t frame;
    alignas(64) std::atomic<uint64_t> written{0};
    alignas(64) std::atomic<uint64_t> consumed{0};
public:
    static_assert(std::atomic<uint64_t>::is_always_lock_free, "Playback queue indices must be lock-free.");
    PCMByteRing(size_t capacity, size_t frame) : bytes(capacity), capacity(capacity), frame(frame) {}
    size_t size() const noexcept { return capacity; }
    size_t writable() const noexcept {
        return capacity - static_cast<size_t>(written.load(std::memory_order_relaxed) -
                                              consumed.load(std::memory_order_acquire));
    }
    size_t write(const uint8_t *source, size_t count) noexcept {
        const uint64_t write = written.load(std::memory_order_relaxed);
        count = std::min(count, capacity - static_cast<size_t>(write - consumed.load(std::memory_order_acquire)));
        if (!count) return 0;
        const size_t offset = static_cast<size_t>(write % capacity);
        const size_t first = std::min(count, capacity - offset);
        std::memcpy(bytes.data() + offset, source, first);
        if (count > first) std::memcpy(bytes.data(), source + first, count - first);
        written.store(write + count, std::memory_order_release);
        return count;
    }
    size_t readable() const noexcept {
        const size_t available = static_cast<size_t>(written.load(std::memory_order_acquire) -
                                                     consumed.load(std::memory_order_relaxed));
        return available - available % frame;
    }
    // Hands out whole frames only, even when the request is not frame aligned.
    size_t read(uint8_t *destination, size_t count) noexcept {
        const uint64_t read = consumed.load(std::memory_order_relaxed);
        count = std::min(count - count % frame, readable());
        if (!count) return 0;
        const size_t offset = static_cast<size_t>(read % capacity);
        const size_t first = std::min(count, capacity - offset);
        std::memcpy(destination, bytes.data() + offset, first);
        if (count > first) std::memcpy(destination + first, bytes.data(), count - first);
        consumed.store(read + count, std::memory_order_release);
        return count;
    }
};

// A read-only stream over the exact pinned handle rather than a pathname the
// resolver could reopen. close() releases the handle deterministically even if
// Media Foundation keeps a reference during late teardown; later reads fail.
class FileStream final : public IStream {
    std::atomic<ULONG> references{1};
    jsti::Handle file;
    std::mutex mutex;
    const uint64_t length;
    // Test seam only: every read first waits for this manual-reset event, so
    // a self-test can stall the codec exactly where a slow disk would.
    jsti::Handle readGate;
    jsti::Handle readGateEntered;
public:
    FileStream(jsti::Handle &handle, uint64_t length, HANDLE readGate = nullptr, HANDLE readGateEntered = nullptr);
    void close();
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **result) override;
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG count = --references; if (!count) delete this; return count;
    }
    HRESULT STDMETHODCALLTYPE Read(void *buffer, ULONG count, ULONG *read) override;
    HRESULT STDMETHODCALLTYPE Write(const void *, ULONG, ULONG *written) override {
        if (written) *written = 0;
        return STG_E_ACCESSDENIED;
    }
    HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER offset, DWORD origin, ULARGE_INTEGER *position) override;
    HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER) override { return STG_E_ACCESSDENIED; }
    HRESULT STDMETHODCALLTYPE CopyTo(IStream *, ULARGE_INTEGER, ULARGE_INTEGER *, ULARGE_INTEGER *) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE Commit(DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Revert() override { return STG_E_INVALIDFUNCTION; }
    HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
    HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
    HRESULT STDMETHODCALLTYPE Stat(STATSTG *result, DWORD) override;
    HRESULT STDMETHODCALLTYPE Clone(IStream **result) override { if (result) *result = nullptr; return E_NOTIMPL; }
};

// Shared between the asynchronous source reader callback and the decode
// worker. Owned by the playback object so cancellation can wake any wait.
struct ReadState {
    std::mutex mutex;
    std::condition_variable changed;
    bool pending = false, ready = false, flushed = false, closed = false;
    // Set by the render thread once it has ended for any reason, after it
    // published its result, so a reader stalled on the codec wakes at once
    // and reports the render outcome instead of waiting for the decode timeout.
    bool renderEnded = false;
    bool renderEndObserved = false; // Internal regression witness: the pending read woke for the render result.
    HRESULT result = S_OK;
    DWORD flags = 0;
    IMFSample *sample = nullptr;
    ~ReadState() { if (sample) sample->Release(); }
};

class ReaderCallback final : public IMFSourceReaderCallback {
    std::atomic<ULONG> references{1};
    const std::shared_ptr<ReadState> state;
public:
    explicit ReaderCallback(std::shared_ptr<ReadState> state) : state(std::move(state)) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **result) override;
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override { const ULONG count = --references; if (!count) delete this; return count; }
    HRESULT STDMETHODCALLTYPE OnReadSample(HRESULT result, DWORD, DWORD flags, LONGLONG, IMFSample *sample) override;
    HRESULT STDMETHODCALLTYPE OnFlush(DWORD) override;
    HRESULT STDMETHODCALLTYPE OnEvent(DWORD, IMFMediaEvent *event) override;
};

struct ReaderResources {
    jsti::COM<IMFSourceReader> reader;
    const std::shared_ptr<ReadState> state;
    explicit ReaderResources(std::shared_ptr<ReadState> state) : state(std::move(state)) {}
    ~ReaderResources() { close(); }
    HRESULT close();
};

// Waits for the pending asynchronous read. Cancellation and the end of the
// render thread are part of the predicate and both notify this condition
// under its mutex, so a stalled codec never delays either until the decode
// timeout expires. Throws Cancelled; renderEnded keeps the render outcome.
enum class Wake { ready, timeout, renderEnded };
Wake awaitSample(ReadState &state, const std::atomic<bool> &cancelled, std::chrono::seconds timeout);

// Media Foundation source reader over the pinned handle, configured to one
// verified output format. Cancellation is honoured between samples and while a
// sample is queued; pending reads are flushed on close.
class Decoder {
    const std::atomic<bool> &cancelled;
    const std::shared_ptr<ReadState> state;
    FileStream *file = nullptr;
    jsti::COM<IStream> stream;
    jsti::COM<IMFByteStream> bytes;
    ReaderResources resources;
    FormatSpec target;
    uint64_t bound = maximumSampleBound;
    unsigned emptySamples = 0;
    uint64_t decoded = 0;

    void checkCancellation() const { if (cancelled.load()) throw Cancelled{}; }
public:
    Decoder(const std::atomic<bool> &cancelled, std::shared_ptr<ReadState> state);
    ~Decoder();
    uint64_t bytesDecoded() const noexcept { return decoded; }
    const FormatSpec &format() const noexcept { return target; }
    uint64_t sampleBytesBound() const noexcept { return bound; }

    // Takes ownership of the pinned handle. origin only identifies the
    // container type by extension; Windows never reopens the path. readGate is
    // the self-test stall seam described on FileStream (null in production).
    void open(jsti::Handle &source, uint64_t size, const std::wstring &origin,
              HANDLE readGate = nullptr, HANDLE readGateEntered = nullptr);
    // Container duration in 100 ns units, or -1 when the source does not say.
    int64_t durationTicks() const;
    bool matches(const FormatSpec &spec) const;
    // Asks Windows to decode (and, through its own resampler, convert) to
    // spec. Returns the failure instead of throwing so a caller can fall back.
    // sampleLimit 0 derives the coalescing bound from the format.
    HRESULT configure(const FormatSpec &spec, uint64_t sampleLimit = 0);
    // Float at the source's own rate and channel layout, for the Windows audio
    // engine to convert when the decoder cannot reach the endpoint format.
    FormatSpec nativeFloatFormat() const;
    void close();

    // Delivers the next decoded sample's bytes to sink(data, length) while the
    // Media Foundation buffer stays locked; returns false at end of stream.
    template<class Sink> bool next(Sink &&sink) {
        checkCancellation();
        auto *reader = resources.reader.value;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            require(state->result, "Windows audio decoder");
            state->pending = true;
            state->ready = false;
        }
        const HRESULT read = reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, nullptr, nullptr, nullptr, nullptr);
        if (FAILED(read)) {
            { std::lock_guard<std::mutex> lock(state->mutex); state->pending = false; }
            require(read, "Read decoded audio sample");
        }
        switch (awaitSample(*state, cancelled, std::chrono::seconds(decodeTimeoutSeconds))) {
        case Wake::ready: break;
        case Wake::timeout: throw Failure{HRESULT_FROM_WIN32(ERROR_TIMEOUT), "Read decoded audio sample"};
        case Wake::renderEnded: throw RenderStopped{}; // The owner reports the render thread's own outcome.
        }
        jsti::COM<IMFSample> sample;
        DWORD flags;
        {
            std::lock_guard<std::mutex> lock(state->mutex);
            require(state->result, "Windows audio decoder");
            flags = state->flags;
            sample.value = state->sample;
            state->sample = nullptr;
        }
        if (flags & MF_SOURCE_READERF_ERROR) throw Failure{E_FAIL, "Windows audio decoder"};
        if ((flags & (MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED | MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED)) &&
            !matches(target)) {
            throw Failure{MF_E_INVALIDMEDIATYPE, "The decoded audio format changed during playback"};
        }
        bool progressed = false;
        if (sample.value) {
            DWORD size = 0;
            require(sample->GetTotalLength(&size), "Measure decoded audio sample");
            // Bound the app-owned contiguous copy before Windows allocates it.
            if (size > bound) {
                throw Failure{HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE), "Decoded audio sample exceeds the playback sample bound"};
            }
            if (size % target.blockAlign) throw Failure{E_UNEXPECTED, "Decoded audio is not frame aligned"};
            if (size) {
                jsti::COM<IMFMediaBuffer> buffer;
                require(sample->ConvertToContiguousBuffer(&buffer.value), "Access decoded audio sample");
                BYTE *data = nullptr;
                DWORD length = 0;
                require(buffer->Lock(&data, nullptr, &length), "Lock decoded audio sample");
                struct Unlock { IMFMediaBuffer *buffer; ~Unlock() { buffer->Unlock(); } } unlock{buffer.value};
                if (length != size || !data) throw Failure{E_UNEXPECTED, "Decoded audio size changed"};
                sink(static_cast<const uint8_t *>(data), static_cast<size_t>(length));
                decoded += length;
                progressed = true;
            }
        }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) return false;
        emptySamples = progressed ? 0 : emptySamples + 1;
        if (emptySamples > 4096) throw Failure{E_FAIL, "Windows decoder made no audio progress"};
        return true;
    }
};

// The rendering seam. Production wraps one shared-mode WASAPI stream; the
// self-test drives a synthetic engine. Every method is called on the render
// thread only, must not throw, and follows the IAudioClient/IAudioRenderClient
// contract: release() is called with the frame count passed to acquire().
class RenderOutput {
public:
    virtual ~RenderOutput() = default;
    // Auto-reset event signalled whenever the engine has consumed audio.
    virtual HANDLE event() const noexcept = 0;
    virtual UINT32 bufferFrames() const noexcept = 0;
    virtual HRESULT start() noexcept = 0;
    virtual HRESULT stop() noexcept = 0;
    virtual HRESULT padding(UINT32 &frames) noexcept = 0;
    virtual HRESULT acquire(UINT32 frames, BYTE **data) noexcept = 0;
    virtual HRESULT release(UINT32 frames) noexcept = 0;
    // Device latency in 100 ns units, or 0 when unknown.
    virtual REFERENCE_TIME latency() noexcept = 0;
    // The synthetic output records this requested delay without sleeping; the
    // production endpoint waits only its own explicitly reported latency.
    virtual DWORD waitForLatency(HANDLE cancelled, DWORD milliseconds) noexcept {
        return WaitForSingleObject(cancelled, milliseconds);
    }
};

// Opens the output for an opened decoder and settles the decode format
// (production negotiates the endpoint mix format). Runs on the decode worker
// inside its COM/Media Foundation session; throws Failure.
class OutputFactory {
public:
    virtual ~OutputFactory() = default;
    virtual std::unique_ptr<RenderOutput> open(Decoder &decoder, FormatSpec &format) = 0;
};

struct EngineOptions {
    DWORD eventTimeout = defaultEventTimeout;
    // Self-test stall seam: a manual-reset event every source read waits for
    // (bounded by readGateTimeout). Null in production.
    HANDLE readGate = nullptr;
    HANDLE readGateEntered = nullptr;
};

// Fixed-size failure record written on the render thread; the worker formats
// it after the join, so no string is built on the real-time path.
struct RenderFailure {
    enum class Kind { none, output, eventTimeout, drainTimeout, decoderStopped, wait, cancelled };
    Kind kind = Kind::none;
    const char *operation = nullptr;
    HRESULT code = S_OK;
};

struct RenderResult {
    bool ran = false;
    int outcome = -1; // 0 finished, 1 cancelled, -1 failed.
    RenderFailure failure;
    uint64_t playedFrames = 0;
    uint32_t underruns = 0;
};
void describe(const RenderFailure &failure, char *buffer, size_t capacity);

// Creation with an injected output; the public C API supplies the WASAPI
// factory. Returns null with a descriptive error, exactly like the C API.
JSTIAudioPlayback *createPlayback(const char *input, JSTIAudioPlaybackCallback callback, void *context,
                                  std::unique_ptr<OutputFactory> factory, const EngineOptions &options,
                                  char *error, size_t capacity);
// Internal observation for the stalled-reader regression; not public C ABI.
std::shared_ptr<ReadState> playbackReadState(JSTIAudioPlayback *playback);
} // namespace jsti::playback
