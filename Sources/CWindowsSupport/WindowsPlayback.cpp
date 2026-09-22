#include "CWindowsSupport.h"
#include "WindowsPlaybackInternal.hpp"
#include <avrt.h>
#include <cstdio>

// Native in-process History playback: the original encoded file is decoded by
// the installed Media Foundation codecs on a dedicated worker, queued through a
// fixed ring and rendered by an event-driven shared-mode WASAPI thread. The
// COM/async-reader ownership mirrors WindowsAudioConversion.cpp and the bounded
// producer/consumer split mirrors WindowsAudio.cpp, but nothing here is shared
// with capture or conversion so their behaviour cannot change.
//
// Accounting rule: the render thread submits source frames only. It never
// synthesises silence, so every frame the engine consumes is source audio and
// the heard position is exactly (submitted - queued). An underrun leaves the
// engine to render its own silence for that period; the final packet at end
// of stream is the exact remaining frame count, never padded.
namespace jsti::playback {
void require(HRESULT result, const char *operation) {
    if (FAILED(result)) throw Failure{result, operation};
}

void describe(const Failure &failure, char *buffer, size_t capacity) {
    if (!buffer || !capacity) return;
    std::snprintf(buffer, capacity, "%s (HRESULT 0x%08lX).", failure.operation ? failure.operation : "Audio playback",
                  static_cast<unsigned long>(static_cast<uint32_t>(failure.code)));
}

std::string describe(const Failure &failure) {
    char detail[512] = {};
    describe(failure, detail, sizeof(detail));
    return detail;
}

void describe(const RenderFailure &failure, char *buffer, size_t capacity) {
    if (!buffer || !capacity) return;
    switch (failure.kind) {
    case RenderFailure::Kind::none:
        std::snprintf(buffer, capacity, "%s", "Audio output stopped before playback finished.");
        return;
    case RenderFailure::Kind::output:
        if (failure.code == AUDCLNT_E_DEVICE_INVALIDATED || failure.code == AUDCLNT_E_RESOURCES_INVALIDATED) {
            std::snprintf(buffer, capacity, "%s",
                          "The audio output device disconnected or its configuration changed. Playback stopped.");
            return;
        }
        describe(Failure{failure.code, failure.operation}, buffer, capacity);
        return;
    case RenderFailure::Kind::eventTimeout:
        std::snprintf(buffer, capacity, "%s", "The audio output device stopped requesting audio. Playback stopped.");
        return;
    case RenderFailure::Kind::drainTimeout:
        std::snprintf(buffer, capacity, "%s", "The audio output device did not finish playing the queued audio.");
        return;
    case RenderFailure::Kind::decoderStopped:
        std::snprintf(buffer, capacity, "%s", "Decoding stopped before playback finished.");
        return;
    case RenderFailure::Kind::wait:
        std::snprintf(buffer, capacity, "Waiting for audio output failed (Windows error %lu).",
                      static_cast<unsigned long>(failure.code));
        return;
    case RenderFailure::Kind::cancelled:
        std::snprintf(buffer, capacity, "%s", "Audio playback cancelled.");
        return;
    }
    std::snprintf(buffer, capacity, "%s", "Audio playback failed.");
}

template<class Function> static Function loadFunction(HMODULE module, const char *name) {
    Function function = nullptr;
    const FARPROC address = module ? GetProcAddress(module, name) : nullptr;
    static_assert(sizeof(function) == sizeof(address), "Windows function pointer size");
    std::memcpy(&function, &address, sizeof(function));
    return function;
}

MediaAPI::MediaAPI() {
    const HMODULE platform = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!platform) { error = GetLastError(); return; }
    const HMODULE readwrite = LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!readwrite) { error = GetLastError(); return; }
    start = loadFunction<Start>(platform, "MFStartup");
    stop = loadFunction<Stop>(platform, "MFShutdown");
    attributes = loadFunction<Attributes>(platform, "MFCreateAttributes");
    type = loadFunction<Type>(platform, "MFCreateMediaType");
    typeFromWave = loadFunction<TypeFromWave>(platform, "MFInitMediaTypeFromWaveFormatEx");
    byteStream = loadFunction<ByteStream>(platform, "MFCreateMFByteStreamOnStream");
    reader = loadFunction<Reader>(readwrite, "MFCreateSourceReaderFromByteStream");
    error = start && stop && attributes && type && typeFromWave && byteStream && reader
        ? ERROR_SUCCESS : ERROR_PROC_NOT_FOUND;
}

MediaAPI &MediaAPI::shared() { static MediaAPI api; return api; }

MediaPlatform::~MediaPlatform() {
    if (media) MediaAPI::shared().stop();
    if (com) CoUninitialize();
}

void MediaPlatform::initialise() {
    auto &api = MediaAPI::shared();
    if (api.error) {
        throw Failure{HRESULT_FROM_WIN32(api.error),
                      "Media Foundation is unavailable, so Windows cannot decode audio for playback"};
    }
    require(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "Initialise audio playback COM");
    com = true;
    require(api.start(MF_VERSION, MFSTARTUP_NOSOCKET), "Start Media Foundation audio playback");
    media = true;
}

bool localPath(const char *text, std::wstring &path) {
    if (!jsti::wide(text, path) || path.size() > 32000) return false;
    std::replace(path.begin(), path.end(), L'/', L'\\');
    if (path.compare(0, 4, L"\\\\?\\") == 0) path.erase(0, 4);
    if (path.size() < 4 || !((path[0] >= L'A' && path[0] <= L'Z') ||
                            (path[0] >= L'a' && path[0] <= L'z')) ||
        path[1] != L':' || path[2] != L'\\' || path.find_first_of(L":\"<>|?*", 2) != std::wstring::npos) return false;
    size_t start = 3;
    while (start < path.size()) {
        const size_t end = path.find(L'\\', start);
        const auto part = path.substr(start, end == std::wstring::npos ? end : end - start);
        if (part.empty() || part == L"." || part == L".." || part.back() == L'.' || part.back() == L' ' ||
            std::any_of(part.begin(), part.end(), [](wchar_t ch) { return ch < 32; })) return false;
        if (end == std::wstring::npos) break;
        start = end + 1;
        if (start == path.size()) return false;
    }
    path.insert(0, L"\\\\?\\");
    return true;
}

void openSource(const std::wstring &path, uint64_t limit, jsti::Handle &handle, uint64_t &size) {
    handle.value = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                               FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (handle.value == INVALID_HANDLE_VALUE) {
        handle.value = nullptr;
        throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Open local audio file for playback"};
    }
    FILE_ATTRIBUTE_TAG_INFO attributes{};
    LARGE_INTEGER length{};
    if (GetFileType(handle.value) != FILE_TYPE_DISK ||
        !GetFileInformationByHandleEx(handle.value, FileAttributeTagInfo, &attributes, sizeof(attributes)) ||
        (attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        !GetFileSizeEx(handle.value, &length)) {
        throw Failure{E_INVALIDARG, "Audio playback input must be a regular local file"};
    }
    if (length.QuadPart <= 0 || static_cast<uint64_t>(length.QuadPart) > limit) {
        throw Failure{HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE), "Audio playback input is empty or exceeds 1 GiB"};
    }
    size = static_cast<uint64_t>(length.QuadPart);
}

FormatSpec parseFormat(const WAVEFORMATEX *wave, size_t size) {
    if (!wave || size < sizeof(WAVEFORMATEX) || size < sizeof(WAVEFORMATEX) + wave->cbSize) {
        throw Failure{E_INVALIDARG, "The audio output format is incomplete"};
    }
    FormatSpec spec;
    spec.rate = wave->nSamplesPerSec;
    spec.channels = wave->nChannels;
    spec.bits = wave->wBitsPerSample;
    spec.blockAlign = wave->nBlockAlign;
    if (wave->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        if (size < sizeof(WAVEFORMATEXTENSIBLE)) {
            throw Failure{E_INVALIDARG, "The extensible audio output format is incomplete"};
        }
        const auto *extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(wave);
        spec.subtype = extensible->SubFormat;
        spec.mask = extensible->dwChannelMask;
    } else if (wave->wFormatTag == WAVE_FORMAT_PCM) {
        spec.subtype = MFAudioFormat_PCM;
    } else if (wave->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        spec.subtype = MFAudioFormat_Float;
    }
    const bool pcm = spec.subtype == MFAudioFormat_PCM;
    const bool floating = spec.subtype == MFAudioFormat_Float;
    if (!pcm && !floating) throw Failure{AUDCLNT_E_UNSUPPORTED_FORMAT, "The audio output format is not PCM or float"};
    const bool validDepth = floating ? spec.bits == 32
        : (spec.bits == 8 || spec.bits == 16 || spec.bits == 24 || spec.bits == 32);
    if (!validDepth || spec.channels < 1 || spec.channels > maximumChannels ||
        spec.rate < minimumRate || spec.rate > maximumRate || spec.blockAlign != spec.channels * spec.bits / 8) {
        throw Failure{AUDCLNT_E_UNSUPPORTED_FORMAT, "The audio output format is not supported"};
    }
    if (spec.byteRate() > maximumByteRate) {
        throw Failure{AUDCLNT_E_UNSUPPORTED_FORMAT, "The audio output format is too large to buffer"};
    }
    const auto *raw = reinterpret_cast<const uint8_t *>(wave);
    spec.bytes.assign(raw, raw + sizeof(WAVEFORMATEX) + wave->cbSize);
    return spec;
}

FormatSpec floatFormat(uint32_t rate, uint32_t channels, uint32_t mask) {
    if (channels < 1 || channels > maximumChannels || rate < minimumRate || rate > maximumRate) {
        throw Failure{MF_E_INVALIDMEDIATYPE, "The decoded audio format is not supported"};
    }
    WAVEFORMATEXTENSIBLE extensible{};
    extensible.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    extensible.Format.nChannels = static_cast<WORD>(channels);
    extensible.Format.nSamplesPerSec = rate;
    extensible.Format.wBitsPerSample = 32;
    extensible.Format.nBlockAlign = static_cast<WORD>(channels * 4);
    extensible.Format.nAvgBytesPerSec = rate * channels * 4;
    extensible.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    extensible.Samples.wValidBitsPerSample = 32;
    extensible.dwChannelMask = mask;
    extensible.SubFormat = MFAudioFormat_Float;
    return parseFormat(&extensible.Format, sizeof(extensible));
}

FormatSpec pcm16Format(uint32_t rate, uint32_t channels) {
    if (channels < 1 || channels > maximumChannels || rate < minimumRate || rate > maximumRate) {
        throw Failure{MF_E_INVALIDMEDIATYPE, "The PCM16 format is not supported"};
    }
    WAVEFORMATEX wave{};
    wave.wFormatTag = WAVE_FORMAT_PCM;
    wave.nChannels = static_cast<WORD>(channels);
    wave.nSamplesPerSec = rate;
    wave.wBitsPerSample = 16;
    wave.nBlockAlign = static_cast<WORD>(channels * 2);
    wave.nAvgBytesPerSec = rate * channels * 2;
    return parseFormat(&wave, sizeof(wave));
}

uint64_t sampleBound(const FormatSpec &format) {
    return std::min(maximumSampleBound, std::max(minimumSampleBound, format.byteRate() * sampleBoundSeconds));
}

FileStream::FileStream(jsti::Handle &handle, uint64_t length, HANDLE readGate, HANDLE readGateEntered)
    : length(length) {
    file.value = handle.value;
    handle.value = nullptr;
    // Media Foundation can retain a late read after the decoder owner closes.
    // Duplicate test gates so those callbacks never wait/signal a closed handle.
    for (auto entry : {std::pair<HANDLE, HANDLE *>{readGate, &this->readGate.value},
                       std::pair<HANDLE, HANDLE *>{readGateEntered, &this->readGateEntered.value}}) {
        if (entry.first && !DuplicateHandle(GetCurrentProcess(), entry.first, GetCurrentProcess(), entry.second,
                                            0, FALSE, DUPLICATE_SAME_ACCESS)) {
            throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Retain the synthetic source-read gate"};
        }
    }
}

void FileStream::close() {
    std::lock_guard<std::mutex> lock(mutex);
    if (file.value) CloseHandle(file.value);
    file.value = nullptr;
}

HRESULT STDMETHODCALLTYPE FileStream::QueryInterface(REFIID id, void **result) {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (id != IID_IUnknown && id != IID_ISequentialStream && id != IID_IStream) return E_NOINTERFACE;
    *result = static_cast<IStream *>(this); AddRef(); return S_OK;
}

HRESULT STDMETHODCALLTYPE FileStream::Read(void *buffer, ULONG count, ULONG *read) {
    if (read) *read = 0;
    if (count && !buffer) return STG_E_INVALIDPOINTER;
    if (readGate.value && WaitForSingleObject(readGate.value, 0) != WAIT_OBJECT_0) {
        if (readGateEntered.value) SetEvent(readGateEntered.value);
        const DWORD waited = WaitForSingleObject(readGate.value, readGateTimeout);
        if (waited != WAIT_OBJECT_0) return HRESULT_FROM_WIN32(waited == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError());
    }
    std::lock_guard<std::mutex> lock(mutex);
    if (!file.value) return STG_E_INVALIDHANDLE;
    DWORD amount = 0;
    if (!ReadFile(file.value, buffer, count, &amount, nullptr)) return HRESULT_FROM_WIN32(GetLastError());
    if (read) *read = amount;
    return amount == count ? S_OK : S_FALSE;
}

HRESULT STDMETHODCALLTYPE FileStream::Seek(LARGE_INTEGER offset, DWORD origin, ULARGE_INTEGER *position) {
    if (origin > STREAM_SEEK_END) return STG_E_INVALIDFUNCTION;
    std::lock_guard<std::mutex> lock(mutex);
    if (!file.value) return STG_E_INVALIDHANDLE;
    LARGE_INTEGER result{};
    if (!SetFilePointerEx(file.value, offset, &result, origin)) return HRESULT_FROM_WIN32(GetLastError());
    if (position) position->QuadPart = static_cast<ULONGLONG>(result.QuadPart);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE FileStream::Stat(STATSTG *result, DWORD) {
    if (!result) return STG_E_INVALIDPOINTER;
    *result = {};
    result->type = STGTY_STREAM;
    result->cbSize.QuadPart = length;
    result->grfMode = STGM_READ | STGM_SHARE_DENY_WRITE;
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ReaderCallback::QueryInterface(REFIID id, void **result) {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (id != IID_IUnknown && id != IID_IMFSourceReaderCallback) return E_NOINTERFACE;
    *result = static_cast<IMFSourceReaderCallback *>(this); AddRef(); return S_OK;
}

HRESULT STDMETHODCALLTYPE ReaderCallback::OnReadSample(HRESULT result, DWORD, DWORD flags, LONGLONG, IMFSample *sample) {
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

HRESULT STDMETHODCALLTYPE ReaderCallback::OnFlush(DWORD) {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->pending = false;
    state->flushed = true;
    state->changed.notify_all();
    return S_OK;
}

HRESULT STDMETHODCALLTYPE ReaderCallback::OnEvent(DWORD, IMFMediaEvent *event) {
    HRESULT result = S_OK;
    if (event) event->GetStatus(&result);
    if (FAILED(result)) {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->closed) { state->result = result; state->changed.notify_all(); }
    }
    return S_OK;
}

HRESULT ReaderResources::close() {
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

Wake awaitSample(ReadState &state, const std::atomic<bool> &cancelled, std::chrono::seconds timeout) {
    std::unique_lock<std::mutex> lock(state.mutex);
    const bool ready = state.changed.wait_for(lock, timeout, [&] {
        return state.ready || FAILED(state.result) || state.renderEnded || cancelled.load();
    });
    if (state.renderEnded) {
        state.renderEndObserved = true;
        state.changed.notify_all();
        return Wake::renderEnded;
    }
    if (cancelled.load()) throw Cancelled{};
    return ready ? Wake::ready : Wake::timeout;
}

Decoder::Decoder(const std::atomic<bool> &cancelled, std::shared_ptr<ReadState> state)
    : cancelled(cancelled), state(state), resources(state) {}

Decoder::~Decoder() {
    resources.close();
    if (file) file->close();
}

void Decoder::open(jsti::Handle &source, uint64_t size, const std::wstring &origin,
                   HANDLE readGate, HANDLE readGateEntered) {
    auto &api = MediaAPI::shared();
    file = new FileStream(source, size, readGate, readGateEntered);
    stream.value = file;
    require(api.byteStream(stream.value, &bytes.value), "Create bounded audio byte stream");
    jsti::COM<IMFAttributes> streamAttributes;
    if (SUCCEEDED(bytes->QueryInterface(IID_IMFAttributes, reinterpret_cast<void **>(&streamAttributes.value)))) {
        require(streamAttributes->SetString(MF_BYTESTREAM_ORIGIN_NAME, origin.c_str()), "Identify local audio file type");
    }
    jsti::COM<IMFSourceReaderCallback> callback;
    callback.value = new ReaderCallback(state);
    jsti::COM<IMFAttributes> options;
    require(api.attributes(&options.value, 1), "Create audio decoder options");
    require(options->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK, callback.value), "Configure cancellable decoder");
    require(api.reader(bytes.value, options.value, &resources.reader.value),
            "Windows could not decode this audio format (no installed codec accepts it)");
    require(resources.reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE), "Disable unused media streams");
    require(resources.reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE), "Select the first audio stream");
}

int64_t Decoder::durationTicks() const {
    if (!resources.reader.value) return -1;
    PROPVARIANT value;
    PropVariantInit(&value);
    const HRESULT result = resources.reader->GetPresentationAttribute(
        static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &value);
    int64_t ticks = -1;
    if (SUCCEEDED(result) && value.vt == VT_UI8 && value.uhVal.QuadPart <= static_cast<ULONGLONG>(INT64_MAX)) {
        ticks = static_cast<int64_t>(value.uhVal.QuadPart);
    }
    PropVariantClear(&value);
    return ticks;
}

bool Decoder::matches(const FormatSpec &spec) const {
    jsti::COM<IMFMediaType> type;
    if (FAILED(resources.reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, &type.value))) return false;
    GUID major{}, subtype{};
    UINT32 rate = 0, channels = 0, bits = 0, align = 0;
    return SUCCEEDED(type->GetGUID(MF_MT_MAJOR_TYPE, &major)) &&
        SUCCEEDED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) &&
        SUCCEEDED(type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate)) &&
        SUCCEEDED(type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels)) &&
        SUCCEEDED(type->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bits)) &&
        SUCCEEDED(type->GetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, &align)) &&
        major == MFMediaType_Audio && subtype == spec.subtype && rate == spec.rate &&
        channels == spec.channels && bits == spec.bits && align == spec.blockAlign;
}

HRESULT Decoder::configure(const FormatSpec &spec, uint64_t sampleLimit) {
    auto &api = MediaAPI::shared();
    jsti::COM<IMFMediaType> type;
    HRESULT result = api.type(&type.value);
    if (SUCCEEDED(result)) result = api.typeFromWave(type.value, spec.wave(), spec.size());
    if (SUCCEEDED(result)) result = type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
    if (SUCCEEDED(result)) {
        result = resources.reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, type.value);
    }
    if (FAILED(result)) return result;
    if (!matches(spec)) return MF_E_INVALIDMEDIATYPE;
    target = spec;
    bound = sampleLimit ? sampleLimit : sampleBound(spec);
    return S_OK;
}

FormatSpec Decoder::nativeFloatFormat() const {
    jsti::COM<IMFMediaType> native;
    require(resources.reader->GetNativeMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &native.value),
            "Reading the native audio format");
    UINT32 rate = 0, channels = 0, mask = 0;
    require(native->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate), "Reading the native audio rate");
    require(native->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels), "Reading the native audio channels");
    if (FAILED(native->GetUINT32(MF_MT_AUDIO_CHANNEL_MASK, &mask))) {
        mask = channels == 1 ? monoMask : channels == 2 ? stereoMask : 0;
    }
    return floatFormat(rate, channels, mask);
}

void Decoder::close() {
    require(resources.close(), "Close Windows audio decoder");
    if (file) file->close();
}
} // namespace jsti::playback

namespace {
using namespace jsti::playback;

struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~Apartment() { if (SUCCEEDED(result)) CoUninitialize(); }
    // The probe may run on an existing STA UI thread as well as a Swift worker.
    bool available() const { return SUCCEEDED(result) || result == RPC_E_CHANGED_MODE; }
};
struct Scheduling {
    DWORD index = 0;
    HANDLE handle = AvSetMmThreadCharacteristicsW(L"Audio", &index);
    ~Scheduling() { if (handle) AvRevertMmThreadCharacteristics(handle); }
};

// One shared-mode WASAPI render stream. Every call is a plain COM method on
// free-threaded objects created by the worker.
class WasapiOutput final : public RenderOutput {
    jsti::COM<IAudioClient> client;
    jsti::COM<IAudioRenderClient> renderer;
    jsti::Handle audioEvent;
    UINT32 frames = 0;
public:
    WasapiOutput(jsti::COM<IAudioClient> &owned, jsti::COM<IAudioRenderClient> &render, jsti::Handle &event, UINT32 frames)
        : frames(frames) {
        client.value = owned.value; owned.value = nullptr;
        renderer.value = render.value; render.value = nullptr;
        audioEvent.value = event.value; event.value = nullptr;
    }
    HANDLE event() const noexcept override { return audioEvent.value; }
    UINT32 bufferFrames() const noexcept override { return frames; }
    HRESULT start() noexcept override { return client->Start(); }
    HRESULT stop() noexcept override { return client->Stop(); }
    HRESULT padding(UINT32 &value) noexcept override { return client->GetCurrentPadding(&value); }
    HRESULT acquire(UINT32 count, BYTE **data) noexcept override { return renderer->GetBuffer(count, data); }
    HRESULT release(UINT32 count) noexcept override { return renderer->ReleaseBuffer(count, 0); }
    REFERENCE_TIME latency() noexcept override {
        REFERENCE_TIME value = 0;
        return SUCCEEDED(client->GetStreamLatency(&value)) ? value : 0;
    }
};

// Opens the default multimedia render endpoint and prefers its shared-mode
// mix format so Media Foundation performs the one conversion. If the decoder
// cannot reach that format it decodes float at the source's own rate and the
// audio engine's converter finishes the job. No active endpoint, a disabled
// device or an unsupported mix format are explicit failures.
class WasapiFactory final : public OutputFactory {
public:
    std::unique_ptr<RenderOutput> open(Decoder &decoder, FormatSpec &format) override {
        jsti::COM<IMMDeviceEnumerator> enumerator;
        require(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                 reinterpret_cast<void **>(&enumerator.value)), "Finding audio output devices");
        jsti::COM<IMMDevice> device;
        const HRESULT found = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device.value);
        if (found == HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) throw Failure{found, "No active audio output device is available"};
        require(found, "Opening the default audio output device");
        DWORD state = 0;
        if (FAILED(device->GetState(&state)) || !(state & DEVICE_STATE_ACTIVE)) {
            throw Failure{AUDCLNT_E_DEVICE_INVALIDATED, "The default audio output device is disabled or disconnected"};
        }
        jsti::COM<IAudioClient> client;
        require(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void **>(&client.value)),
                "Activating the audio output device");
        WAVEFORMATEX *mix = nullptr;
        require(client->GetMixFormat(&mix), "Reading the audio output format");
        struct MixFormat { WAVEFORMATEX *value; ~MixFormat() { CoTaskMemFree(value); } } owned{mix};
        const FormatSpec mixFormat = parseFormat(mix, sizeof(WAVEFORMATEX) + mix->cbSize);
        DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
        if (SUCCEEDED(decoder.configure(mixFormat))) {
            format = mixFormat;
        } else {
            const FormatSpec native = decoder.nativeFloatFormat();
            require(decoder.configure(native), "Windows decoder cannot produce PCM audio from this file");
            format = native;
            flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        }
        require(client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, renderBufferDuration, 0, format.wave(), nullptr),
                "Configuring shared-mode audio output");
        jsti::Handle event;
        event.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event.value) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Creating the audio output event"};
        require(client->SetEventHandle(event.value), "Registering the audio output event");
        UINT32 frames = 0;
        require(client->GetBufferSize(&frames), "Reading the audio output buffer size");
        if (!frames || frames > format.rate * maximumBufferSeconds) {
            throw Failure{AUDCLNT_E_BUFFER_ERROR, "The audio output driver returned an invalid or excessive buffer"};
        }
        jsti::COM<IAudioRenderClient> renderer;
        require(client->GetService(__uuidof(IAudioRenderClient), reinterpret_cast<void **>(&renderer.value)),
                "Opening the audio output stream");
        return std::make_unique<WasapiOutput>(client, renderer, event, frames);
    }
};
} // namespace

struct JSTIAudioPlayback {
    std::wstring input;
    jsti::Handle source; // Pinned at creation; ownership moves into the decoder on start.
    uint64_t sourceSize = 0;
    JSTIAudioPlaybackCallback callback = nullptr;
    void *context = nullptr;
    std::unique_ptr<OutputFactory> factory;
    EngineOptions options;
    std::atomic<bool> cancelled{false};
    std::atomic<bool> pauseRequested{false};
    std::atomic<DWORD> workerID{0};
    std::mutex mutex;
    std::thread worker;
    bool started = false;
    jsti::Handle cancelEvent;  // Manual reset; wakes the render thread and queue waits.
    jsti::Handle commandEvent; // Auto reset; pause/resume requests for the render thread.
    const std::shared_ptr<ReadState> state = std::make_shared<ReadState>();
    // Cheap snapshot for hosts: written by the engine threads, read anywhere.
    // Sequentially consistent with cancelled: reserve a possible Start before
    // checking cancellation. After cancel returns, a snapshot of neverStarted
    // proves that a future reservation will see cancelled and cannot Start.
    std::atomic<int> outputState{outputNeverStarted};
    std::atomic<int> displayState{statePreparing};
    std::atomic<uint64_t> heardFrames{0};
    std::atomic<uint32_t> rate{0};
    std::atomic<int64_t> durationTicks{-1};
    // Written by the render thread before it exits, read by the worker after joining it.
    RenderResult render;

    void checkCancellation() const { if (cancelled.load()) throw Cancelled{}; }
    void run() noexcept;
};

namespace {
class Session {
    JSTIAudioPlayback &owner;
    MediaPlatform platform;
    std::unique_ptr<RenderOutput> output;
    jsti::Handle spaceEvent, stopEvent;
    Decoder decoder;
    FormatSpec format;
    std::unique_ptr<PCMByteRing> ring;
    std::atomic<bool> decodeEnded{false};
    std::atomic<bool> renderStopped{false};
    std::thread render;

    void ensureRenderStarted() {
        if (render.joinable()) return;
        owner.checkCancellation();
        render = std::thread([this] { renderLoop(); });
    }

    // Blocks the decode worker until the render thread frees queue space,
    // cancellation is requested or the render thread has exited. A paused
    // render thread frees nothing, so the producer stays bounded by the ring.
    void waitForSpace() {
        HANDLE events[] = {owner.cancelEvent.value, spaceEvent.value};
        while (!ring->writable()) {
            owner.checkCancellation();
            if (renderStopped.load(std::memory_order_acquire)) throw RenderStopped{};
            if (WaitForMultipleObjects(2, events, FALSE, 1000) == WAIT_FAILED) {
                throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Waiting for audio output space"};
            }
        }
    }

    void enqueue(const uint8_t *data, size_t length) {
        size_t offset = 0;
        while (offset < length) {
            offset += ring->write(data + offset, length - offset);
            if (offset < length) { ensureRenderStarted(); waitForSpace(); }
        }
    }

    void abortRender() noexcept {
        if (!render.joinable()) return;
        if (stopEvent.value) SetEvent(stopEvent.value);
        // Session exists only on the decode worker; its private render thread
        // never owns or destroys it. Join must complete before any referenced
        // state can unwind. An invariant-breaking join exception terminates;
        // it must never be swallowed to free a still-running Session.
        render.join();
    }

    // Real-time path: only memcpy from the fixed queue into the engine buffer,
    // and only whole source frames. Pause stops the engine and freezes its
    // queue; resume starts it again from the same frames. Decoder failures,
    // device loss, an engine that stops signalling while started, and
    // cancellation end the loop; every failure is a fixed-size record.
    void renderLoop() noexcept {
        RenderResult result;
        result.ran = true;
        Apartment apartment;
        Scheduling scheduling;
        const size_t frameBytes = format.blockAlign;
        const UINT32 bufferFrames = output->bufferFrames();
        const ULONGLONG bufferMilliseconds = static_cast<ULONGLONG>(bufferFrames) * 1000 / format.rate;
        uint64_t written = 0; // Source frames submitted to the engine.
        bool engineRunning = false, draining = false, finished = false;
        ULONGLONG drainDeadline = 0;
        int outcome = -1;
        auto fail = [&](RenderFailure::Kind kind, const char *operation, HRESULT code) {
            if (result.failure.kind == RenderFailure::Kind::none) result.failure = {kind, operation, code};
        };
        auto refreshDrain = [&] { drainDeadline = GetTickCount64() + bufferMilliseconds + drainGrace; };
        auto publishHeard = [&](UINT32 padding) { owner.heardFrames.store(written - padding, std::memory_order_release); };
        // Submits whole source frames while the engine has room. Returns false
        // when the loop must end because of a failure or because every frame
        // has been consumed after end of stream.
        auto fill = [&]() -> bool {
            UINT32 padding = 0;
            HRESULT code = output->padding(padding);
            if (FAILED(code)) { fail(RenderFailure::Kind::output, "Reading the audio output buffer state", code); return false; }
            if (padding > bufferFrames || padding > written) {
                fail(RenderFailure::Kind::output, "Validating the audio output buffer state", AUDCLNT_E_BUFFER_ERROR);
                return false;
            }
            publishHeard(padding);
            if (draining) { finished = padding == 0; return !finished; }
            const UINT32 available = bufferFrames - padding;
            if (!available) return true;
            // Read the end flag before the queue: the worker publishes its last
            // bytes before the flag, so an empty queue after a true flag is final.
            const bool ended = decodeEnded.load(std::memory_order_acquire);
            const size_t queuedFrames = ring->readable() / frameBytes;
            if (!queuedFrames) {
                if (!ended) { ++result.underruns; return true; }
                draining = true;
                refreshDrain();
                finished = padding == 0;
                return !finished;
            }
            const UINT32 frames = static_cast<UINT32>(std::min<size_t>(available, queuedFrames));
            BYTE *data = nullptr;
            code = output->acquire(frames, &data);
            if (FAILED(code) || !data) {
                fail(RenderFailure::Kind::output, "Requesting the audio output buffer", FAILED(code) ? code : E_POINTER);
                return false;
            }
            const size_t wanted = static_cast<size_t>(frames) * frameBytes;
            if (ring->read(data, wanted) != wanted) {
                output->release(0); // Zero is the documented way to hand back an unused request.
                fail(RenderFailure::Kind::output, "Copying queued audio", E_UNEXPECTED);
                return false;
            }
            code = output->release(frames);
            if (FAILED(code)) { fail(RenderFailure::Kind::output, "Submitting audio output", code); return false; }
            written += frames;
            SetEvent(spaceEvent.value);
            return true;
        };
        bool running = true;
        if (FAILED(apartment.result)) {
            fail(RenderFailure::Kind::output, "Initialising audio output COM", apartment.result);
            running = false;
        }
        if (running) running = fill(); // Pre-roll from the queue before the engine starts.
        HANDLE events[] = {owner.cancelEvent.value, stopEvent.value, owner.commandEvent.value, output->event()};
        while (running && !finished) {
            if (owner.cancelled.load()) { outcome = 1; break; }
            const bool wantPause = owner.pauseRequested.load();
            if (wantPause && engineRunning) {
                const HRESULT code = output->stop();
                if (FAILED(code)) { fail(RenderFailure::Kind::output, "Pausing audio output", code); break; }
                engineRunning = false;
                UINT32 padding = 0;
                if (SUCCEEDED(output->padding(padding)) && padding <= written) publishHeard(padding);
                owner.displayState.store(statePaused);
            } else if (!wantPause && !engineRunning) {
                // Reserve before reading cancellation. Together with cancel's
                // flag-then-snapshot order, seq_cst prevents both sides from
                // observing the old state and falsely acknowledging silence.
                owner.outputState.store(outputStarted);
                if (owner.cancelled.load()) { outcome = 1; break; }
                const HRESULT code = output->start();
                if (FAILED(code)) { fail(RenderFailure::Kind::output, "Starting audio output", code); break; }
                engineRunning = true;
                if (draining) refreshDrain();
                owner.displayState.store(statePlaying);
            } else if (wantPause && owner.displayState.load() != statePaused) {
                owner.displayState.store(statePaused); // Paused before the engine ever started.
            }
            if (!engineRunning) {
                const DWORD wait = WaitForMultipleObjects(3, events, FALSE, pausedWaitSlice);
                if (wait == WAIT_OBJECT_0) { outcome = 1; break; }
                if (wait == WAIT_OBJECT_0 + 1) { fail(RenderFailure::Kind::decoderStopped, nullptr, S_OK); break; }
                if (wait == WAIT_FAILED) { fail(RenderFailure::Kind::wait, nullptr, static_cast<HRESULT>(GetLastError())); break; }
                continue; // A command or an expired slice re-evaluates the pause request.
            }
            const DWORD wait = WaitForMultipleObjects(4, events, FALSE, owner.options.eventTimeout);
            if (wait == WAIT_OBJECT_0) { outcome = 1; break; }
            if (wait == WAIT_OBJECT_0 + 1) { fail(RenderFailure::Kind::decoderStopped, nullptr, S_OK); break; }
            if (wait == WAIT_OBJECT_0 + 2) continue;
            if (wait == WAIT_OBJECT_0 + 3) {
                if (draining && GetTickCount64() > drainDeadline) { fail(RenderFailure::Kind::drainTimeout, nullptr, S_OK); break; }
                running = fill();
                continue;
            }
            if (wait == WAIT_TIMEOUT) { fail(RenderFailure::Kind::eventTimeout, nullptr, S_OK); break; }
            fail(RenderFailure::Kind::wait, nullptr, static_cast<HRESULT>(GetLastError()));
            break;
        }
        if (finished) {
            outcome = 0;
            // The engine consumed every frame; let the device's own latency
            // elapse so the tail is audible before the stream stops.
            const REFERENCE_TIME latency = output->latency();
            if (latency > 0) {
                const REFERENCE_TIME bounded = std::min<REFERENCE_TIME>(latency, REFERENCE_TIME{maximumLatencyWait} * 10000);
                const auto milliseconds = static_cast<DWORD>((bounded + 9999) / 10000);
                output->waitForLatency(owner.cancelEvent.value, milliseconds);
            }
        }
        bool outputQuiet = !engineRunning;
        if (engineRunning) {
            const HRESULT stopped = output->stop();
            outputQuiet = SUCCEEDED(stopped);
            if (!outputQuiet) {
                fail(RenderFailure::Kind::output, "Stopping audio output", stopped);
                outcome = -1;
            }
        }
        if (outputQuiet) owner.outputState.store(outputStopped);
        uint64_t played = written;
        if (outcome != 0) {
            UINT32 padding = 0;
            if (SUCCEEDED(output->padding(padding)) && padding <= written) played = written - padding;
            else played = written > bufferFrames ? written - bufferFrames : 0; // Lower bound: the engine never holds more.
        }
        owner.heardFrames.store(played, std::memory_order_release);
        result.playedFrames = played;
        result.outcome = outcome;
        owner.render = result;
        renderStopped.store(true, std::memory_order_release);
        // Publish the render outcome before waking the actual decoder wait.
        // This is distinct from cancellation, so device failure stays failure.
        {
            std::lock_guard<std::mutex> lock(owner.state->mutex);
            owner.state->renderEnded = true;
        }
        owner.state->changed.notify_all();
        SetEvent(spaceEvent.value);
    }
public:
    explicit Session(JSTIAudioPlayback &owner) : owner(owner), decoder(owner.cancelled, owner.state) {}
    ~Session() { abortRender(); }

    void setup() {
        platform.initialise();
        owner.checkCancellation();
        decoder.open(owner.source, owner.sourceSize, owner.input, owner.options.readGate, owner.options.readGateEntered);
        owner.durationTicks.store(decoder.durationTicks());
        owner.checkCancellation();
        output = owner.factory->open(decoder, format);
        if (!output || format.rate == 0 || format.blockAlign == 0 || !output->event() || !output->bufferFrames()) {
            throw Failure{E_UNEXPECTED, "The audio output was not configured"};
        }
        owner.rate.store(format.rate);
        owner.checkCancellation();
        spaceEvent.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        stopEvent.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!spaceEvent.value || !stopEvent.value) {
            throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Creating audio playback events"};
        }
        const uint64_t queueBytes = std::max<uint64_t>(format.byteRate() * queueSeconds,
                                                       uint64_t{output->bufferFrames()} * format.blockAlign * 2);
        ring = std::make_unique<PCMByteRing>(static_cast<size_t>(queueBytes), format.blockAlign);
    }

    // Decodes everything into the queue, starting the render thread once the
    // queue first fills (or at end of stream for short files), then waits for
    // the render thread to drain the engine buffer or stop.
    void decodeAll() {
        while (true) {
            if (renderStopped.load(std::memory_order_acquire)) throw RenderStopped{};
            if (!decoder.next([this](const uint8_t *data, size_t length) { enqueue(data, length); })) break;
        }
        if (!decoder.bytesDecoded()) throw Failure{MF_E_INVALID_FILE_FORMAT, "The file contains no decoded audio samples"};
        decodeEnded.store(true, std::memory_order_release);
        ensureRenderStarted();
        render.join();
        decoder.close();
    }
};
} // namespace

void JSTIAudioPlayback::run() noexcept {
    workerID.store(GetCurrentThreadId());
    int status = -1;
    // Fixed storage: the completion path never allocates, so it cannot throw.
    char message[512] = {};
    auto text = [&](const char *value) { std::snprintf(message, sizeof(message), "%s", value); };
    try {
        checkCancellation();
        Session session(*this);
        session.setup();
        session.decodeAll();
        status = render.outcome;
        if (status == 1) text("Audio playback cancelled.");
        else if (status != 0) describe(render.failure, message, sizeof(message));
    } catch (const Cancelled &) {
        status = 1;
        text("Audio playback cancelled.");
    } catch (const RenderStopped &) {
        status = render.outcome == 1 ? 1 : -1;
        if (status == 1) text("Audio playback cancelled.");
        else describe(render.failure, message, sizeof(message));
    } catch (const Failure &failure) {
        describe(failure, message, sizeof(message));
    } catch (const std::exception &) {
        text("Audio playback could not allocate its bounded state.");
    }
    // Session destruction released every endpoint reference. Even if Stop
    // itself failed, no future Start or audible output remains possible now.
    outputState.store(outputStopped);
    const double played = rate.load() ? static_cast<double>(render.playedFrames) / rate.load() : 0;
    displayState.store(stateEnded);
    callback(status, played, message, context);
    workerID.store(0);
}

JSTIAudioPlayback *jsti::playback::createPlayback(const char *input, JSTIAudioPlaybackCallback callback, void *context,
                                                  std::unique_ptr<OutputFactory> factory, const EngineOptions &options,
                                                  char *error, size_t capacity) {
    try {
        std::wstring path;
        if (!callback || !factory || !localPath(input, path)) {
            jsti::fail("Audio playback requires an absolute local input path and a callback.", error, capacity);
            return nullptr;
        }
        auto playback = std::make_unique<JSTIAudioPlayback>();
        playback->input = std::move(path);
        openSource(playback->input, inputLimit, playback->source, playback->sourceSize);
        playback->cancelEvent.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        playback->commandEvent.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!playback->cancelEvent.value || !playback->commandEvent.value) {
            throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Create playback control events"};
        }
        playback->callback = callback;
        playback->context = context;
        playback->factory = std::move(factory);
        playback->options = options;
        if (error && capacity) error[0] = 0;
        return playback.release();
    } catch (const Failure &failure) {
        jsti::fail(describe(failure), error, capacity);
        return nullptr;
    } catch (const std::exception &) {
        jsti::fail("Could not allocate native audio playback state.", error, capacity);
        return nullptr;
    }
}

JSTIAudioPlayback *jsti_audio_playback_create(const char *input, JSTIAudioPlaybackCallback callback, void *context,
                                              char *error, size_t capacity) {
    try {
        return createPlayback(input, callback, context, std::make_unique<WasapiFactory>(), EngineOptions{}, error, capacity);
    } catch (const std::exception &) {
        jsti::fail("Could not allocate native audio playback state.", error, capacity);
        return nullptr;
    }
}

std::shared_ptr<ReadState> jsti::playback::playbackReadState(JSTIAudioPlayback *playback) {
    return playback ? playback->state : nullptr;
}

int jsti_audio_playback_start(JSTIAudioPlayback *playback, char *error, size_t capacity) {
    if (!playback) return jsti::fail("No audio playback supplied.", error, capacity);
    try {
        std::lock_guard<std::mutex> lock(playback->mutex);
        if (playback->started || playback->cancelled.load()) {
            return jsti::fail("Audio playback was already started or cancelled.", error, capacity);
        }
        playback->worker = std::thread([playback] { playback->run(); });
        playback->started = true;
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Could not start the native audio playback worker.", error, capacity);
    }
}

namespace {
int requestPause(JSTIAudioPlayback *playback, bool paused) {
    if (!playback) return -1;
    if (playback->displayState.load() == stateEnded) return 1;
    playback->pauseRequested.store(paused);
    if (playback->commandEvent.value) SetEvent(playback->commandEvent.value);
    return 0;
}
} // namespace

int jsti_audio_playback_pause(JSTIAudioPlayback *playback) { return requestPause(playback, true); }

int jsti_audio_playback_resume(JSTIAudioPlayback *playback) { return requestPause(playback, false); }

int jsti_audio_playback_snapshot(const JSTIAudioPlayback *playback, JSTIAudioPlaybackSnapshot *snapshot) {
    if (!snapshot) return -1;
    *snapshot = {};
    snapshot->duration_seconds = -1;
    if (!playback) return -1;
    snapshot->state = playback->displayState.load();
    snapshot->output_state = playback->outputState.load();
    const uint32_t rate = playback->rate.load();
    snapshot->position_seconds = rate ? static_cast<double>(playback->heardFrames.load(std::memory_order_acquire)) / rate : 0;
    const int64_t ticks = playback->durationTicks.load();
    if (ticks >= 0) snapshot->duration_seconds = static_cast<double>(ticks) / 10000000.0;
    return 0;
}

void jsti_audio_playback_cancel(JSTIAudioPlayback *playback) {
    if (!playback) return;
    playback->cancelled.store(true);
    if (playback->cancelEvent.value) SetEvent(playback->cancelEvent.value);
    // Taking the reader lock orders the flag before any predicate re-check, so
    // a decoder wait cannot miss this wake-up and stall until its timeout.
    { std::lock_guard<std::mutex> lock(playback->state->mutex); }
    playback->state->changed.notify_all();
}

int jsti_audio_playback_destroy(JSTIAudioPlayback *playback, char *error, size_t capacity) {
    if (!playback) return 0;
    if (playback->workerID.load() == GetCurrentThreadId()) {
        return jsti::fail("Destroy audio playback outside its completion callback.", error, capacity);
    }
    jsti_audio_playback_cancel(playback);
    std::thread worker;
    try {
        // A start still publishing its worker holds the same mutex, so a
        // completion racing start's return can never leave a thread unjoined.
        { std::lock_guard<std::mutex> lock(playback->mutex); worker.swap(playback->worker); }
        if (worker.joinable()) worker.join();
    } catch (const std::exception &) {
        // Keep the job alive and reachable: the caller retries outside the
        // worker instead of freeing state a live thread still uses.
        std::lock_guard<std::mutex> lock(playback->mutex);
        if (worker.joinable()) playback->worker.swap(worker);
        return jsti::fail("Could not join the audio playback worker; retry outside its threads.", error, capacity);
    }
    delete playback;
    if (error && capacity) error[0] = 0;
    return 0;
}

int jsti_audio_playback_endpoint_available(char *error, size_t capacity) {
    Apartment apartment;
    if (!apartment.available()) {
        return jsti::fail(jsti::systemError("Initializing audio output discovery", static_cast<DWORD>(apartment.result)),
                          error, capacity);
    }
    jsti::COM<IMMDeviceEnumerator> enumerator;
    HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                      reinterpret_cast<void **>(&enumerator.value));
    if (FAILED(result)) return jsti::fail(jsti::systemError("Finding audio output devices", static_cast<DWORD>(result)), error, capacity);
    jsti::COM<IMMDevice> device;
    result = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device.value);
    if (result == HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) {
        if (error && capacity) error[0] = 0;
        return 0;
    }
    if (FAILED(result)) return jsti::fail(jsti::systemError("Finding the default audio output device", static_cast<DWORD>(result)), error, capacity);
    DWORD state = 0;
    result = device->GetState(&state);
    if (FAILED(result)) return jsti::fail(jsti::systemError("Reading the audio output device state", static_cast<DWORD>(result)), error, capacity);
    if (error && capacity) error[0] = 0;
    return (state & DEVICE_STATE_ACTIVE) ? 1 : 0;
}
