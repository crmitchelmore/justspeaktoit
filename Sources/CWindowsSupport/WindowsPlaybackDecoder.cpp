#include "CWindowsSupport.h"
#include "WindowsPlaybackInternal.hpp"
#include <cstdio>

// History playback's source side (WindowsPlayback.cpp renders it): failure
// text, the Media Foundation platform, local source files, format parsing, the
// bounded file stream and the asynchronous decoder that feeds the ring.
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

void openSource(const std::wstring &path, uint64_t limit, jsti::Handle &handle, uint64_t &size) {
    if (handle.value) throw Failure{E_INVALIDARG, "Audio playback input handle is already owned"};
    // Validation can throw after CreateFile succeeds. Retain the candidate
    // locally so a refused input cannot leave a pin in the caller's output,
    // which might then be reused for a later open.
    jsti::Handle candidate;
    candidate.value = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                               FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (candidate.value == INVALID_HANDLE_VALUE) {
        candidate.value = nullptr;
        throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Open local audio file for playback"};
    }
    FILE_ATTRIBUTE_TAG_INFO attributes{};
    LARGE_INTEGER length{};
    if (GetFileType(candidate.value) != FILE_TYPE_DISK ||
        !GetFileInformationByHandleEx(candidate.value, FileAttributeTagInfo, &attributes, sizeof(attributes)) ||
        (attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        !GetFileSizeEx(candidate.value, &length)) {
        throw Failure{E_INVALIDARG, "Audio playback input must be a regular local file"};
    }
    if (length.QuadPart <= 0 || static_cast<uint64_t>(length.QuadPart) > limit) {
        throw Failure{HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE), "Audio playback input is empty or exceeds 1 GiB"};
    }
    size = static_cast<uint64_t>(length.QuadPart);
    handle.value = candidate.value;
    candidate.value = nullptr;
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

Decoder::Decoder(const std::atomic<bool> &cancelled, std::shared_ptr<ReadState> state, DWORD readTimeout)
    : cancelled(cancelled), state(state), resources(state), readTimeout(readTimeout) {}

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
