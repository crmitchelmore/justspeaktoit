#include "include/VoiceAudioCodec.h"
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wrl/client.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <vector>

using Microsoft::WRL::ComPtr;
namespace {
constexpr size_t pcmLimit = 64u * 1024u * 1024u;
constexpr size_t containerLimit = pcmLimit + 4096;
struct Failure { HRESULT code; const char *operation; };
struct Cancelled {};
void require(HRESULT code, const char *operation) { if (FAILED(code)) throw Failure{code, operation}; }

// Keep Media Foundation optional, as in the existing native decoder/playback.
// Modules stay loaded through any internal codec teardown.
struct API {
    decltype(&MFStartup) start = nullptr;
    decltype(&MFShutdown) stop = nullptr;
    decltype(&MFCreateAttributes) attributes = nullptr;
    decltype(&MFCreateMediaType) type = nullptr;
    decltype(&MFCreateSample) sample = nullptr;
    decltype(&MFCreateMemoryBuffer) buffer = nullptr;
    decltype(&MFCreateMFByteStreamOnStream) stream = nullptr;
    decltype(&MFCreateSinkWriterFromURL) writer = nullptr;
    decltype(&MFCreateSourceReaderFromByteStream) reader = nullptr;
    decltype(&MFTranscodeGetAudioOutputAvailableTypes) types = nullptr;
    decltype(&MFTEnumEx) enumerate = nullptr;
    template<class Function> static Function load(HMODULE module, const char *name) {
        Function result = nullptr;
        FARPROC address = module ? GetProcAddress(module, name) : nullptr;
        static_assert(sizeof(result) == sizeof(address), "Windows function pointer size");
        std::memcpy(&result, &address, sizeof(result)); return result;
    }
    API() {
        HMODULE platform = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        HMODULE readwrite = LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        HMODULE media = LoadLibraryExW(L"mf.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        start = load<decltype(start)>(platform, "MFStartup");
        stop = load<decltype(stop)>(platform, "MFShutdown");
        attributes = load<decltype(attributes)>(platform, "MFCreateAttributes");
        type = load<decltype(type)>(platform, "MFCreateMediaType");
        sample = load<decltype(sample)>(platform, "MFCreateSample");
        buffer = load<decltype(buffer)>(platform, "MFCreateMemoryBuffer");
        stream = load<decltype(stream)>(platform, "MFCreateMFByteStreamOnStream");
        writer = load<decltype(writer)>(readwrite, "MFCreateSinkWriterFromURL");
        reader = load<decltype(reader)>(readwrite, "MFCreateSourceReaderFromByteStream");
        types = load<decltype(types)>(media, "MFTranscodeGetAudioOutputAvailableTypes");
        enumerate = load<decltype(enumerate)>(platform, "MFTEnumEx");
    }
    static API &shared() { static API instance; return instance; }
    void validate() {
        if (!start || !stop || !attributes || !type || !sample || !buffer || !stream ||
            !writer || !reader || !types || !enumerate)
            throw Failure{HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND),
                "Media Foundation voice encoding is unavailable; choose WAV"};
    }
};
struct Platform {
    bool com = false, media = false;
    Platform() {
        API::shared().validate();
        require(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "Initialise native voice codec COM"); com = true;
        HRESULT result = API::shared().start(MF_VERSION, MFSTARTUP_NOSOCKET);
        if (FAILED(result)) { CoUninitialize(); com = false; require(result, "Start native voice codecs"); }
        media = true;
    }
    ~Platform() { if (media) API::shared().stop(); if (com) CoUninitialize(); }
};

// Seekable memory only, with a hard cap even while the muxer patches its headers.
class MemoryStream final : public IStream {
    std::atomic<ULONG> references{1};
    std::mutex mutex;
    std::vector<uint8_t> bytes;
    uint64_t position = 0;
public:
    explicit MemoryStream(std::vector<uint8_t> initial = {}) : bytes(std::move(initial)) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **value) override {
        if (!value) return E_POINTER;
        *value = nullptr;
        if (id != IID_IUnknown && id != IID_ISequentialStream && id != IID_IStream) return E_NOINTERFACE;
        *value = static_cast<IStream *>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG remaining = --references; if (!remaining) delete this; return remaining;
    }
    HRESULT STDMETHODCALLTYPE Read(void *output, ULONG count, ULONG *read) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (!output && count) return STG_E_INVALIDPOINTER;
        size_t amount = position < bytes.size() ? std::min<size_t>(count, bytes.size() - position) : 0;
        if (amount) std::memcpy(output, bytes.data() + position, amount);
        position += amount; if (read) *read = static_cast<ULONG>(amount);
        return amount == count ? S_OK : S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE Write(const void *input, ULONG count, ULONG *written) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (written) *written = 0;
        if ((!input && count) || position > containerLimit || count > containerLimit - position)
            return STG_E_MEDIUMFULL;
        try { if (position + count > bytes.size()) bytes.resize(static_cast<size_t>(position + count)); }
        catch (const std::bad_alloc &) { return E_OUTOFMEMORY; }
        if (count) std::memcpy(bytes.data() + position, input, count);
        position += count; if (written) *written = count; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER movement, DWORD origin, ULARGE_INTEGER *next) override {
        std::lock_guard<std::mutex> lock(mutex);
        int64_t base = origin == STREAM_SEEK_SET ? 0 : origin == STREAM_SEEK_CUR
            ? static_cast<int64_t>(position) : origin == STREAM_SEEK_END ? static_cast<int64_t>(bytes.size()) : -1;
        if (base < 0 || movement.QuadPart < -base ||
            movement.QuadPart > static_cast<int64_t>(containerLimit) - base) return STG_E_INVALIDFUNCTION;
        position = static_cast<uint64_t>(base + movement.QuadPart);
        if (next) next->QuadPart = position; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER size) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (size.QuadPart > containerLimit) return STG_E_MEDIUMFULL;
        try { bytes.resize(static_cast<size_t>(size.QuadPart)); } catch (const std::bad_alloc &) { return E_OUTOFMEMORY; }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Stat(STATSTG *stat, DWORD) override {
        if (!stat) return E_POINTER;
        std::lock_guard<std::mutex> lock(mutex); *stat = {};
        stat->type = STGTY_STREAM; stat->grfMode = STGM_READWRITE; stat->cbSize.QuadPart = bytes.size(); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Commit(DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Revert() override { return STG_E_INVALIDFUNCTION; }
    HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
    HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
    HRESULT STDMETHODCALLTYPE Clone(IStream **) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE CopyTo(IStream *, ULARGE_INTEGER, ULARGE_INTEGER *, ULARGE_INTEGER *) override {
        return E_NOTIMPL;
    }
    std::vector<uint8_t> snapshot() { std::lock_guard<std::mutex> lock(mutex); return bytes; }
};

GUID subtype(const char *format) {
    if (format && std::strcmp(format, "mp3") == 0) return MFAudioFormat_MP3;
    if (format && std::strcmp(format, "m4a") == 0) return MFAudioFormat_AAC;
    throw Failure{E_INVALIDARG, "Choose a known compressed voice format"};
}
ComPtr<IMFMediaType> pcmType(uint32_t rate) {
    ComPtr<IMFMediaType> type; require(API::shared().type(&type), "Create PCM type");
    require(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), "Set PCM major type");
    require(type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM), "Set PCM subtype");
    require(type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1), "Set mono PCM");
    require(type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate), "Set captured PCM sample rate");
    require(type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16), "Set PCM16");
    require(type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 2), "Set PCM alignment");
    require(type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * 2), "Set PCM byte rate");
    require(type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE), "Set independent PCM samples"); return type;
}
ComPtr<IMFMediaType> encodedType(const char *format, uint32_t rate) {
    if (rate != 16000 && rate != 24000 && rate != 48000)
        throw Failure{E_INVALIDARG, "Unsupported captured voice sample rate"};
    GUID codec = subtype(format);
    ComPtr<IMFCollection> types;
    require(API::shared().types(codec, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, nullptr, &types),
        "No installed compatible Media Foundation voice encoder; choose WAV");
    DWORD count = 0; require(types->GetElementCount(&count), "List native encoder formats");
    for (DWORD index = 0; index < count; ++index) {
        ComPtr<IUnknown> element; ComPtr<IMFMediaType> type;
        require(types->GetElement(index, &element), "Read encoder format");
        require(element.As(&type), "Read encoder media type");
        UINT32 channels = 0, sampleRate = 0;
        if (SUCCEEDED(type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels)) && channels == 1 &&
            SUCCEEDED(type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &sampleRate)) && sampleRate == rate) return type;
    }
    throw Failure{MF_E_INVALIDMEDIATYPE, "Installed encoder cannot preserve this mono source rate; choose WAV"};
}
void requireDecoder(const char *format) {
    MFT_REGISTER_TYPE_INFO input{MFMediaType_Audio, subtype(format)};
    IMFActivate **decoders = nullptr; UINT32 count = 0;
    require(API::shared().enumerate(MFT_CATEGORY_AUDIO_DECODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, &input, nullptr, &decoders, &count),
        "Query native voice decoder");
    bool available = false;
    for (UINT32 index = 0; index < count; ++index) {
        ComPtr<IMFTransform> decoder;
        if (SUCCEEDED(decoders[index]->ActivateObject(IID_PPV_ARGS(&decoder)))) available = true;
        decoders[index]->ShutdownObject(); decoders[index]->Release();
    }
    CoTaskMemFree(decoders);
    if (!available) throw Failure{MF_E_TOPO_CODEC_NOT_FOUND, "No installed native voice decoder; choose WAV"};
}
ComPtr<IMFSinkWriter> makeWriter(const char *format, uint32_t rate, IMFByteStream *stream, DWORD &track) {
    ComPtr<IMFAttributes> attributes; require(API::shared().attributes(&attributes, 2), "Create writer attributes");
    require(attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, std::strcmp(format, "mp3") == 0
        ? MFTranscodeContainerType_MP3 : MFTranscodeContainerType_MPEG4), "Set real audio container");
    require(attributes->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE), "Disable real-time encoding throttle");
    ComPtr<IMFSinkWriter> writer;
    require(API::shared().writer(nullptr, stream, attributes.Get(), &writer), "Create native audio container writer");
    auto output = encodedType(format, rate);
    require(writer->AddStream(output.Get(), &track), "Add native encoded audio track");
    auto input = pcmType(rate);
    require(writer->SetInputMediaType(track, input.Get(), nullptr), "Configure captured PCM input"); return writer;
}
void check(const JSTIVoiceCodecRequest &request, std::chrono::steady_clock::time_point deadline) {
    if (request.cancelled(request.context)) throw Cancelled{};
    if (std::chrono::steady_clock::now() >= deadline)
        throw Failure{HRESULT_FROM_WIN32(WAIT_TIMEOUT), "Native voice codec exceeded its 120-second budget"};
}
void encode(const JSTIVoiceCodecRequest &request, MemoryStream *memory) {
    ComPtr<IMFByteStream> stream; require(API::shared().stream(memory, &stream), "Create bounded native byte stream");
    DWORD track = 0; auto writer = makeWriter(request.format, request.sample_rate, stream.Get(), track);
    require(writer->BeginWriting(), "Begin native audio encoding");
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(120);
    for (size_t offset = 0; offset < request.pcm_bytes;) {
        check(request, deadline);
        DWORD count = static_cast<DWORD>(std::min<size_t>(8192, request.pcm_bytes - offset));
        ComPtr<IMFMediaBuffer> buffer; require(API::shared().buffer(count, &buffer), "Allocate codec PCM buffer");
        BYTE *bytes = nullptr; require(buffer->Lock(&bytes, nullptr, nullptr), "Lock codec PCM buffer");
        std::memcpy(bytes, request.pcm + offset, count);
        require(buffer->Unlock(), "Unlock codec PCM buffer");
        require(buffer->SetCurrentLength(count), "Set codec PCM buffer length");
        ComPtr<IMFSample> sample; require(API::shared().sample(&sample), "Create codec sample");
        require(sample->AddBuffer(buffer.Get()), "Attach PCM sample");
        LONGLONG start = static_cast<LONGLONG>(offset / 2) * 10000000 / request.sample_rate;
        LONGLONG end = static_cast<LONGLONG>((offset + count) / 2) * 10000000 / request.sample_rate;
        require(sample->SetSampleTime(start), "Set audio sample time");
        require(sample->SetSampleDuration(end - start), "Set audio sample duration");
        require(writer->WriteSample(track, sample.Get()), "Encode native voice sample"); offset += count;
    }
    check(request, deadline); require(writer->Finalize(), "Finalize native audio container"); check(request, deadline);
}
void requireAudioAttribute(IMFMediaType *type, REFGUID key, UINT32 expected, const char *operation) {
    UINT32 actual = 0; require(type->GetUINT32(key, &actual), operation);
    if (actual != expected) throw Failure{MF_E_INVALIDMEDIATYPE, operation};
}
void verifyAudioType(IMFMediaType *type, REFGUID codec, uint32_t rate, bool decoded) {
    GUID major{}, actual{};
    require(type->GetGUID(MF_MT_MAJOR_TYPE, &major), "Read retained voice major type");
    require(type->GetGUID(MF_MT_SUBTYPE, &actual), "Read retained voice subtype");
    if (major != MFMediaType_Audio || actual != codec)
        throw Failure{MF_E_INVALIDMEDIATYPE, "Retained voice audio has an unexpected codec; choose WAV"};
    requireAudioAttribute(type, MF_MT_AUDIO_NUM_CHANNELS, 1, "Voice audio must remain mono; choose WAV");
    requireAudioAttribute(type, MF_MT_AUDIO_SAMPLES_PER_SECOND, rate,
        "Voice audio must preserve the captured sample rate; choose WAV");
    if (decoded) {
        requireAudioAttribute(type, MF_MT_AUDIO_BITS_PER_SAMPLE, 16, "Decoded voice audio must remain PCM16");
        requireAudioAttribute(type, MF_MT_AUDIO_BLOCK_ALIGNMENT, 2, "Decoded voice audio has invalid PCM alignment");
        requireAudioAttribute(type, MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * 2,
            "Decoded voice audio has an invalid PCM byte rate");
    }
}
void verifyNativeType(IMFSourceReader *reader, const JSTIVoiceCodecRequest &request) {
    ComPtr<IMFMediaType> type;
    require(reader->GetNativeMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &type),
        "Read retained voice track format");
    verifyAudioType(type.Get(), subtype(request.format), request.sample_rate, false);
}
void decode(const JSTIVoiceCodecRequest &request, const std::vector<uint8_t> &encoded) {
    ComPtr<MemoryStream> memory; memory.Attach(new MemoryStream(encoded));
    ComPtr<IMFByteStream> stream; require(API::shared().stream(memory.Get(), &stream), "Open encoded voice stream");
    ComPtr<IMFSourceReader> reader;
    require(API::shared().reader(stream.Get(), nullptr, &reader), "Open native encoded voice decoder");
    require(reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE), "Disable unrelated streams");
    require(reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE), "Select encoded voice track");
    verifyNativeType(reader.Get(), request);
    auto type = pcmType(request.sample_rate);
    require(reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, type.Get()), "Decode mono PCM16");
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(120);
    size_t total = 0;
    for (;;) {
        check(request, deadline);
        DWORD flags = 0; ComPtr<IMFSample> sample;
        require(reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, nullptr, &flags, nullptr, &sample),
            "Decode retained voice audio");
        if (flags & MF_SOURCE_READERF_ERROR)
            throw Failure{MF_E_INVALIDMEDIATYPE, "Encoded voice audio decoder reported an error"};
        if (flags & MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED) verifyNativeType(reader.Get(), request);
        // A decoder can announce new attributes without changing the required PCM layout.
        if (sample || (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)) {
            ComPtr<IMFMediaType> current;
            require(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, &current),
                "Read actual decoded voice format");
            verifyAudioType(current.Get(), MFAudioFormat_PCM, request.sample_rate, true);
        }
        if (sample) {
            ComPtr<IMFMediaBuffer> buffer; require(sample->ConvertToContiguousBuffer(&buffer), "Read decoded audio");
            BYTE *bytes = nullptr; DWORD count = 0;
            require(buffer->Lock(&bytes, nullptr, &count), "Lock decoded voice audio");
            bool valid = count % 2 == 0 && count <= pcmLimit - total;
            int32_t accepted = valid ? request.output(1, bytes, count, request.context) : -1;
            HRESULT unlocked = buffer->Unlock(); require(unlocked, "Unlock decoded voice audio");
            if (!valid || accepted != 0) throw Failure{E_OUTOFMEMORY, "Decoded voice audio exceeded its byte bound"};
            total += count;
        }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    if (!total) throw Failure{MF_E_INVALID_FILE_FORMAT, "Native decoder returned empty voice audio"};
}
template<class Work> int32_t perform(Work work, char *error, size_t capacity) {
    try { Platform platform; work(); return 0; }
    catch (const Cancelled &) { return 1; }
    catch (const Failure &failure) {
        if (error && capacity) std::snprintf(error, capacity, "%s (0x%08lX).", failure.operation,
            static_cast<unsigned long>(failure.code)); return -1;
    } catch (const std::bad_alloc &) {
        if (error && capacity) std::snprintf(error, capacity, "Native voice codec ran out of bounded memory."); return -1;
    }
}
} // namespace

int32_t jsti_voice_codec_available(const char *format, uint32_t rate, char *error, size_t capacity) {
    return perform([&] {
        requireDecoder(format);
        // Writer setup alone does not prove muxing or the decoder's final negotiated output.
        encodedType(format, rate);
        std::vector<uint8_t> pcm(static_cast<size_t>(rate) * 2);
        for (size_t index = 0; index < rate; ++index) {
            uint16_t sample = index % 64 < 32 ? 6000 : static_cast<uint16_t>(-6000);
            pcm[index * 2] = static_cast<uint8_t>(sample & 255);
            pcm[index * 2 + 1] = static_cast<uint8_t>(sample >> 8);
        }
        JSTIVoiceCodecRequest probe{format, rate, pcm.data(), pcm.size(),
            [](int32_t, const uint8_t *, size_t, void *) -> int32_t { return 0; },
            [](void *) -> int32_t { return 0; }, nullptr};
        ComPtr<MemoryStream> memory; memory.Attach(new MemoryStream());
        encode(probe, memory.Get());
        auto encoded = memory->snapshot();
        if (encoded.empty()) throw Failure{MF_E_INVALID_FILE_FORMAT, "Native codec probe returned empty audio"};
        decode(probe, encoded);
    }, error, capacity);
}
int32_t jsti_voice_codec_encode(const JSTIVoiceCodecRequest *request, char *error, size_t capacity) {
    return perform([&] {
        if (!request || !request->pcm || !request->pcm_bytes || request->pcm_bytes > pcmLimit ||
            request->pcm_bytes % 2 || !request->cancelled || !request->output)
            throw Failure{E_INVALIDARG, "Invalid native voice conversion input"};
        if (request->cancelled(request->context)) throw Cancelled{};
        requireDecoder(request->format);
        ComPtr<MemoryStream> memory; memory.Attach(new MemoryStream());
        encode(*request, memory.Get());
        auto encoded = memory->snapshot();
        if (encoded.empty()) throw Failure{MF_E_INVALID_FILE_FORMAT, "Native voice encoder returned empty audio"};
        decode(*request, encoded);
        if (request->cancelled(request->context)) throw Cancelled{};
        if (request->output(0, encoded.data(), encoded.size(), request->context) != 0)
            throw Failure{E_OUTOFMEMORY, "Encoded voice audio exceeded its retained byte bound"};
    }, error, capacity);
}
