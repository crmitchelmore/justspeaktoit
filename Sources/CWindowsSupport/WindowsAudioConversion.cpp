#include "CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace {
constexpr uint64_t fileLimit = 25000000;
constexpr DWORD outputRate = 16000;
constexpr DWORD waveHeaderSize = 44;
struct ConversionFailure { HRESULT code; const char *operation; };
struct ConversionCancelled {};

void require(HRESULT result, const char *operation) {
    if (FAILED(result)) throw ConversionFailure{result, operation};
}

// Optional OS component: never make a missing Media Foundation DLL prevent
// launch of the recorder. Modules live for the process, including any late
// internal Media Foundation teardown work after a cancelled conversion.
struct MediaAPI {
    using Start = HRESULT (WINAPI *)(ULONG, DWORD);
    using Stop = HRESULT (WINAPI *)();
    using Attributes = HRESULT (WINAPI *)(IMFAttributes **, UINT32);
    using Type = HRESULT (WINAPI *)(IMFMediaType **);
    using ByteStream = HRESULT (WINAPI *)(IStream *, IMFByteStream **);
    using Reader = HRESULT (WINAPI *)(IMFByteStream *, IMFAttributes *, IMFSourceReader **);
    Start start = nullptr;
    Stop stop = nullptr;
    Attributes attributes = nullptr;
    Type type = nullptr;
    ByteStream byteStream = nullptr;
    Reader reader = nullptr;
    DWORD error = ERROR_MOD_NOT_FOUND;

    template<class Function> static Function load(HMODULE module, const char *name) {
        Function function = nullptr;
        const FARPROC address = module ? GetProcAddress(module, name) : nullptr;
        static_assert(sizeof(function) == sizeof(address), "Windows function pointer size");
        std::memcpy(&function, &address, sizeof(function));
        return function;
    }
    MediaAPI() {
        const HMODULE platform = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!platform) { error = GetLastError(); return; }
        const HMODULE readwrite = LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!readwrite) { error = GetLastError(); return; }
        start = load<Start>(platform, "MFStartup");
        stop = load<Stop>(platform, "MFShutdown");
        attributes = load<Attributes>(platform, "MFCreateAttributes");
        type = load<Type>(platform, "MFCreateMediaType");
        byteStream = load<ByteStream>(platform, "MFCreateMFByteStreamOnStream");
        reader = load<Reader>(readwrite, "MFCreateSourceReaderFromByteStream");
        error = start && stop && attributes && type && byteStream && reader ? ERROR_SUCCESS : ERROR_PROC_NOT_FOUND;
    }
    static MediaAPI &shared() { static MediaAPI api; return api; }
};

struct MediaPlatform {
    bool com = false, media = false;
    ~MediaPlatform() {
        if (media) MediaAPI::shared().stop();
        if (com) CoUninitialize();
    }
    void initialise() {
        auto &api = MediaAPI::shared();
        if (api.error) throw ConversionFailure{HRESULT_FROM_WIN32(api.error), "Media Foundation is unavailable"};
        require(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "Initialise audio conversion COM");
        com = true;
        require(api.start(MF_VERSION, MFSTARTUP_NOSOCKET), "Start Media Foundation audio conversion");
        media = true;
    }
};

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

// A read-only stream over the exact validated handle, rather than asking the
// resolver to reopen a pathname. The handle denies concurrent write/delete.
class FileStream final : public IStream {
    std::atomic<ULONG> references{1};
    jsti::Handle file;
    std::mutex mutex;
    uint64_t length;
public:
    FileStream(HANDLE handle, uint64_t length) : length(length) { file.value = handle; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (id != IID_IUnknown && id != IID_ISequentialStream && id != IID_IStream) return E_NOINTERFACE;
        *result = static_cast<IStream *>(this); AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG count = --references; if (!count) delete this; return count;
    }
    HRESULT STDMETHODCALLTYPE Read(void *buffer, ULONG count, ULONG *read) override {
        if (read) *read = 0;
        if (count && !buffer) return STG_E_INVALIDPOINTER;
        std::lock_guard<std::mutex> lock(mutex);
        DWORD amount = 0;
        if (!ReadFile(file.value, buffer, count, &amount, nullptr)) return HRESULT_FROM_WIN32(GetLastError());
        if (read) *read = amount;
        return amount == count ? S_OK : S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE Write(const void *, ULONG, ULONG *written) override {
        if (written) *written = 0;
        return STG_E_ACCESSDENIED;
    }
    HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER offset, DWORD origin, ULARGE_INTEGER *position) override {
        if (origin > STREAM_SEEK_END) return STG_E_INVALIDFUNCTION;
        std::lock_guard<std::mutex> lock(mutex);
        LARGE_INTEGER result{};
        if (!SetFilePointerEx(file.value, offset, &result, origin)) return HRESULT_FROM_WIN32(GetLastError());
        if (position) position->QuadPart = static_cast<ULONGLONG>(result.QuadPart);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER) override { return STG_E_ACCESSDENIED; }
    HRESULT STDMETHODCALLTYPE CopyTo(IStream *, ULARGE_INTEGER, ULARGE_INTEGER *, ULARGE_INTEGER *) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE Commit(DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Revert() override { return STG_E_INVALIDFUNCTION; }
    HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
    HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER, DWORD) override { return STG_E_INVALIDFUNCTION; }
    HRESULT STDMETHODCALLTYPE Stat(STATSTG *result, DWORD) override {
        if (!result) return STG_E_INVALIDPOINTER;
        *result = {};
        result->type = STGTY_STREAM;
        result->cbSize.QuadPart = length;
        result->grfMode = STGM_READ | STGM_SHARE_DENY_WRITE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Clone(IStream **result) override { if (result) *result = nullptr; return E_NOTIMPL; }
};

struct ReadState {
    std::mutex mutex;
    std::condition_variable changed;
    bool pending = false, ready = false, flushed = false, closed = false;
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

struct ReaderResources {
    jsti::COM<IMFSourceReader> reader;
    const std::shared_ptr<ReadState> state;
    explicit ReaderResources(std::shared_ptr<ReadState> state) : state(std::move(state)) {}
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

void put16(uint8_t *bytes, uint16_t value) {
    bytes[0] = static_cast<uint8_t>(value); bytes[1] = static_cast<uint8_t>(value >> 8);
}
void put32(uint8_t *bytes, uint32_t value) {
    for (int index = 0; index < 4; ++index) bytes[index] = static_cast<uint8_t>(value >> (8 * index));
}
std::array<uint8_t, waveHeaderSize> waveHeader(uint32_t bytes, uint32_t rate = outputRate, uint16_t channels = 1) {
    std::array<uint8_t, waveHeaderSize> header{};
    std::memcpy(header.data(), "RIFF", 4); put32(header.data() + 4, bytes + 36);
    std::memcpy(header.data() + 8, "WAVEfmt ", 8); put32(header.data() + 16, 16);
    put16(header.data() + 20, 1); put16(header.data() + 22, channels); put32(header.data() + 24, rate);
    put32(header.data() + 28, rate * channels * 2); put16(header.data() + 32, channels * 2); put16(header.data() + 34, 16);
    std::memcpy(header.data() + 36, "data", 4); put32(header.data() + 40, bytes);
    return header;
}

void writeBytes(HANDLE file, const uint8_t *bytes, DWORD count) {
    DWORD written = 0;
    if (!WriteFile(file, bytes, count, &written, nullptr)) {
        throw ConversionFailure{HRESULT_FROM_WIN32(GetLastError()), "Write canonical audio"};
    }
    if (written != count) throw ConversionFailure{HRESULT_FROM_WIN32(ERROR_WRITE_FAULT), "Write complete canonical audio"};
}

bool discardOutput(HANDLE file, std::string &error) {
    FILE_DISPOSITION_INFO remove{TRUE};
    if (SetFileInformationByHandle(file, FileDispositionInfo, &remove, sizeof(remove))) return true;
    error += " Private partial output could not be removed (Windows error " + std::to_string(GetLastError()) + ").";
    return false;
}

void verifyFormat(IMFSourceReader *reader) {
    jsti::COM<IMFMediaType> type;
    require(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, &type.value), "Read decoded audio format");
    GUID major{}, subtype{};
    UINT32 rate = 0, channels = 0, bits = 0, align = 0;
    require(type->GetGUID(MF_MT_MAJOR_TYPE, &major), "Read decoded audio major type");
    require(type->GetGUID(MF_MT_SUBTYPE, &subtype), "Read decoded audio subtype");
    require(type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate), "Read decoded audio rate");
    require(type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels), "Read decoded audio channels");
    require(type->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bits), "Read decoded audio sample size");
    require(type->GetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, &align), "Read decoded audio alignment");
    if (major != MFMediaType_Audio || subtype != MFAudioFormat_PCM || rate != outputRate ||
        channels != 1 || bits != 16 || align != 2) {
        throw ConversionFailure{MF_E_INVALIDMEDIATYPE, "Windows decoder did not produce 16 kHz mono PCM16"};
    }
}
} // namespace

struct JSTIAudioConversion {
    std::wstring input;
    std::string output;
    JSTIAudioConversionCallback callback = nullptr;
    void *context = nullptr;
    std::atomic<bool> cancelled{false};
    std::atomic<DWORD> workerID{0};
    std::mutex mutex;
    std::thread worker;
    bool started = false;
    const std::shared_ptr<ReadState> state = std::make_shared<ReadState>();

    void checkCancellation() const { if (cancelled.load()) throw ConversionCancelled{}; }

    uint64_t convert(HANDLE destination) {
        checkCancellation();
        jsti::Handle source;
        source.value = CreateFileW(input.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                    FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (source.value == INVALID_HANDLE_VALUE) {
            throw ConversionFailure{HRESULT_FROM_WIN32(GetLastError()), "Open local audio input"};
        }
        FILE_ATTRIBUTE_TAG_INFO attributes{};
        LARGE_INTEGER sourceSize{};
        if (GetFileType(source.value) != FILE_TYPE_DISK ||
            !GetFileInformationByHandleEx(source.value, FileAttributeTagInfo, &attributes, sizeof(attributes)) ||
            (attributes.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
            !GetFileSizeEx(source.value, &sourceSize)) {
            throw ConversionFailure{E_INVALIDARG, "Audio input must be a regular local file"};
        }
        if (sourceSize.QuadPart <= 0 || static_cast<uint64_t>(sourceSize.QuadPart) > fileLimit) {
            throw ConversionFailure{HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE), "Audio input is empty or exceeds 25 MB"};
        }
        MediaPlatform platform;
        platform.initialise();
        checkCancellation();
        auto &api = MediaAPI::shared();
        jsti::COM<IStream> fileStream;
        fileStream.value = new FileStream(source.value, static_cast<uint64_t>(sourceSize.QuadPart));
        source.value = nullptr;
        jsti::COM<IMFByteStream> bytes;
        require(api.byteStream(fileStream.value, &bytes.value), "Create bounded audio byte stream");
        jsti::COM<IMFAttributes> streamAttributes;
        if (SUCCEEDED(bytes->QueryInterface(IID_IMFAttributes, reinterpret_cast<void **>(&streamAttributes.value)))) {
            require(streamAttributes->SetString(MF_BYTESTREAM_ORIGIN_NAME, input.c_str()), "Identify local audio file type");
        }
        jsti::COM<IMFSourceReaderCallback> callback;
        callback.value = new ReaderCallback(state);
        jsti::COM<IMFAttributes> options;
        require(api.attributes(&options.value, 1), "Create audio decoder options");
        require(options->SetUnknown(MF_SOURCE_READER_ASYNC_CALLBACK, callback.value), "Configure cancellable decoder");
        ReaderResources resources(state);
        require(api.reader(bytes.value, options.value, &resources.reader.value), "Windows could not decode this audio format");
        try {
            checkCancellation();
            auto *reader = resources.reader.value;
            require(reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE), "Disable unused media streams");
            require(reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE), "Select the first audio stream");
            jsti::COM<IMFMediaType> target;
            require(api.type(&target.value), "Create canonical audio format");
            require(target->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), "Set canonical audio type");
            require(target->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM), "Set canonical PCM encoding");
            require(target->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1), "Set canonical mono audio");
            require(target->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, outputRate), "Set canonical audio rate");
            require(target->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16), "Set canonical sample size");
            require(target->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 2), "Set canonical sample alignment");
            require(target->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, outputRate * 2), "Set canonical byte rate");
            require(target->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE), "Set independent PCM samples");
            require(reader->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, target.value),
                    "Windows decoder cannot convert this format to 16 kHz mono PCM16");
            verifyFormat(reader);
            checkCancellation();
            const auto placeholder = waveHeader(0);
            writeBytes(destination, placeholder.data(), static_cast<DWORD>(placeholder.size()));
            uint64_t written = 0;
            unsigned emptySamples = 0;
            while (true) {
                checkCancellation();
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    require(state->result, "Windows audio decoder");
                    state->pending = true;
                    state->ready = false;
                }
                const HRESULT read = reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0,
                                                         nullptr, nullptr, nullptr, nullptr);
                if (FAILED(read)) {
                    { std::lock_guard<std::mutex> lock(state->mutex); state->pending = false; }
                    require(read, "Read decoded audio sample");
                }
                jsti::COM<IMFSample> sample;
                DWORD flags;
                {
                    std::unique_lock<std::mutex> lock(state->mutex);
                    if (!state->changed.wait_for(lock, std::chrono::seconds(30), [&] {
                        return state->ready || FAILED(state->result) || cancelled.load();
                    })) throw ConversionFailure{HRESULT_FROM_WIN32(ERROR_TIMEOUT), "Read decoded audio sample"};
                    checkCancellation();
                    require(state->result, "Windows audio decoder");
                    flags = state->flags;
                    sample.value = state->sample;
                    state->sample = nullptr;
                }
                if (flags & MF_SOURCE_READERF_ERROR) throw ConversionFailure{E_FAIL, "Windows audio decoder"};
                if (flags & (MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED | MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED)) {
                    verifyFormat(reader);
                }
                if (sample.value) {
                    DWORD size = 0;
                    require(sample->GetTotalLength(&size), "Measure decoded audio sample");
                    if (size % 2 || size > fileLimit - waveHeaderSize - written) {
                        throw ConversionFailure{HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE),
                                                 "Decoded audio is invalid or exceeds 25 MB"};
                    }
                    if (size) {
                        jsti::COM<IMFMediaBuffer> buffer;
                        require(sample->ConvertToContiguousBuffer(&buffer.value), "Access decoded audio sample");
                        BYTE *data = nullptr;
                        DWORD length = 0;
                        require(buffer->Lock(&data, nullptr, &length), "Lock decoded audio sample");
                        struct Unlock { IMFMediaBuffer *buffer; ~Unlock() { buffer->Unlock(); } } unlock{buffer.value};
                        if (length != size) throw ConversionFailure{E_UNEXPECTED, "Decoded audio size changed"};
                        for (DWORD offset = 0; offset < length;) {
                            checkCancellation();
                            const DWORD amount = std::min<DWORD>(64 * 1024, length - offset);
                            writeBytes(destination, data + offset, amount);
                            offset += amount;
                        }
                        written += size;
                        emptySamples = 0;
                    } else ++emptySamples;
                } else ++emptySamples;
                if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
                if (emptySamples > 4096) throw ConversionFailure{E_FAIL, "Windows decoder made no audio progress"};
            }
            if (!written) throw ConversionFailure{MF_E_INVALID_FILE_FORMAT, "The file contains no decoded audio samples"};
            checkCancellation();
            LARGE_INTEGER beginning{};
            if (!SetFilePointerEx(destination, beginning, nullptr, FILE_BEGIN)) {
                throw ConversionFailure{HRESULT_FROM_WIN32(GetLastError()), "Finalise canonical WAV header"};
            }
            const auto header = waveHeader(static_cast<uint32_t>(written));
            writeBytes(destination, header.data(), static_cast<DWORD>(header.size()));
            if (!FlushFileBuffers(destination)) {
                throw ConversionFailure{HRESULT_FROM_WIN32(GetLastError()), "Persist canonical WAV output"};
            }
            require(resources.close(), "Close Windows audio decoder");
            checkCancellation();
            return written / 2;
        } catch (...) {
            resources.close();
            throw;
        }
    }

    void run() noexcept {
        workerID.store(GetCurrentThreadId());
        int status = -1;
        uint64_t samples = 0;
        std::string error;
        jsti::Handle destination;
        try {
            checkCancellation();
            destination.value = jsti::createPrivateFileHandle(output.c_str(), error);
            if (destination.value != INVALID_HANDLE_VALUE) {
                samples = convert(destination.value);
                checkCancellation();
                status = 0;
            }
        } catch (const ConversionCancelled &) {
            status = 1;
            error = "Audio conversion cancelled.";
        } catch (const ConversionFailure &failure) {
            char detail[256] = {};
            std::snprintf(detail, sizeof(detail), "%s (HRESULT 0x%08lX).", failure.operation,
                          static_cast<unsigned long>(static_cast<uint32_t>(failure.code)));
            error = detail;
        } catch (const std::exception &) {
            error = "Audio conversion could not allocate its bounded state.";
        }
        if (destination.value && destination.value != INVALID_HANDLE_VALUE) {
            if (status != 0 && !discardOutput(destination.value, error)) status = -1;
            CloseHandle(destination.value);
            destination.value = nullptr;
        }
        callback(status, status == 0 ? static_cast<double>(samples) / outputRate : 0,
                  status == 0 ? samples : 0, error.c_str(), context);
        workerID.store(0);
    }
};

JSTIAudioConversion *jsti_audio_conversion_create(const char *input, const char *output,
                                                  JSTIAudioConversionCallback callback, void *context,
                                                  char *error, size_t capacity) {
    try {
        std::wstring inputPath, outputPath;
        if (!callback || !localPath(input, inputPath) || !localPath(output, outputPath) ||
            _wcsicmp(inputPath.c_str(), outputPath.c_str()) == 0) {
            jsti::fail("Audio conversion requires different absolute local input/output paths and a callback.", error, capacity);
            return nullptr;
        }
        auto conversion = std::make_unique<JSTIAudioConversion>();
        conversion->input = std::move(inputPath);
        conversion->output = jsti::utf8(outputPath);
        conversion->callback = callback;
        conversion->context = context;
        if (error && capacity) error[0] = 0;
        return conversion.release();
    } catch (const std::exception &) {
        jsti::fail("Could not allocate native audio conversion state.", error, capacity);
        return nullptr;
    }
}

int jsti_audio_conversion_start(JSTIAudioConversion *conversion, char *error, size_t capacity) {
    if (!conversion) return jsti::fail("No audio conversion supplied.", error, capacity);
    try {
        std::lock_guard<std::mutex> lock(conversion->mutex);
        if (conversion->started || conversion->cancelled.load()) {
            return jsti::fail("Audio conversion was already started or cancelled.", error, capacity);
        }
        conversion->worker = std::thread([conversion] { conversion->run(); });
        conversion->started = true;
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Could not start native audio conversion worker.", error, capacity);
    }
}

void jsti_audio_conversion_cancel(JSTIAudioConversion *conversion) {
    if (!conversion) return;
    conversion->cancelled.store(true);
    conversion->state->changed.notify_all();
}

int jsti_audio_conversion_destroy(JSTIAudioConversion *conversion, char *error, size_t capacity) {
    if (!conversion) return 0;
    if (conversion->workerID.load() == GetCurrentThreadId()) {
        return jsti::fail("Destroy audio conversion outside its completion callback.", error, capacity);
    }
    jsti_audio_conversion_cancel(conversion);
    if (conversion->worker.joinable()) conversion->worker.join();
    delete conversion;
    if (error && capacity) error[0] = 0;
    return 0;
}

namespace {
struct ConversionTestFiles {
    std::wstring root;
    std::vector<std::wstring> files;
    ~ConversionTestFiles() {
        for (const auto &path : files) DeleteFileW(path.c_str());
        if (!root.empty()) RemoveDirectoryW(root.c_str());
    }
    std::wstring path(const wchar_t *name) {
        auto value = root + L"\\" + name;
        files.push_back(value);
        return value;
    }
};

void createWaveFixture(const std::wstring &path, DWORD rate, WORD channels, DWORD frames, bool silent = false) {
    std::string error;
    jsti::Handle file;
    file.value = jsti::createPrivateFileHandle(jsti::utf8(path).c_str(), error);
    if (file.value == INVALID_HANDLE_VALUE) throw ConversionFailure{E_ACCESSDENIED, "Create synthetic WAV fixture"};
    const DWORD size = frames * channels * 2;
    const auto header = waveHeader(size, rate, channels);
    writeBytes(file.value, header.data(), static_cast<DWORD>(header.size()));
    if (silent) {
        LARGE_INTEGER length{};
        length.QuadPart = static_cast<LONGLONG>(waveHeaderSize) + size;
        if (!SetFilePointerEx(file.value, length, nullptr, FILE_BEGIN) || !SetEndOfFile(file.value)) {
            throw ConversionFailure{HRESULT_FROM_WIN32(GetLastError()), "Extend bounded synthetic WAV fixture"};
        }
        return;
    }
    std::array<uint8_t, 4096> buffer{};
    DWORD offset = 0;
    while (offset < frames) {
        const DWORD count = std::min<DWORD>(static_cast<DWORD>(buffer.size()) / (channels * 2), frames - offset);
        for (DWORD frame = 0; frame < count; ++frame) {
            const int16_t sample = ((offset + frame) / std::max<DWORD>(1, rate / 400)) % 2 ? 4096 : -4096;
            for (WORD channel = 0; channel < channels; ++channel) {
                put16(buffer.data() + (frame * channels + channel) * 2, static_cast<uint16_t>(sample));
            }
        }
        writeBytes(file.value, buffer.data(), count * channels * 2);
        offset += count;
    }
}

struct ConversionTestResult {
    std::mutex mutex;
    std::condition_variable changed;
    JSTIAudioConversion *job = nullptr;
    int callbacks = 0, status = -2;
    double duration = 0;
    uint64_t samples = 0;
    bool selfDestroyRejected = false;
    std::string error;
};

bool convertFixture(const std::wstring &input, const std::wstring &output,
                    ConversionTestResult &result, std::string &error) {
    char nativeError[1024] = {};
    auto callback = [](int status, double duration, uint64_t samples, const char *message, void *context) {
        auto &result = *static_cast<ConversionTestResult *>(context);
        char selfJoinError[256] = {};
        const bool rejected = jsti_audio_conversion_destroy(result.job, selfJoinError, sizeof(selfJoinError)) == -1 &&
            selfJoinError[0];
        std::lock_guard<std::mutex> lock(result.mutex);
        ++result.callbacks;
        result.status = status;
        result.duration = duration;
        result.samples = samples;
        result.selfDestroyRejected = rejected;
        result.error = message ? message : "";
        result.changed.notify_all();
    };
    result.job = jsti_audio_conversion_create(jsti::utf8(input).c_str(), jsti::utf8(output).c_str(),
                                               callback, &result, nativeError, sizeof(nativeError));
    if (!result.job) { error = nativeError; return false; }
    if (jsti_audio_conversion_start(result.job, nativeError, sizeof(nativeError)) != 0) {
        error = nativeError;
        jsti_audio_conversion_destroy(result.job, nullptr, 0);
        return false;
    }
    if (jsti_audio_conversion_start(result.job, nativeError, sizeof(nativeError)) != -1) {
        error = "Audio conversion admitted a second start.";
        jsti_audio_conversion_destroy(result.job, nullptr, 0);
        return false;
    }
    bool ready;
    {
        std::unique_lock<std::mutex> lock(result.mutex);
        ready = result.changed.wait_for(lock, std::chrono::seconds(60), [&] { return result.callbacks != 0; });
    }
    if (jsti_audio_conversion_destroy(result.job, nativeError, sizeof(nativeError)) != 0) {
        error = nativeError;
        return false;
    }
    result.job = nullptr;
    if (!ready || result.callbacks != 1 || !result.selfDestroyRejected) {
        error = "Audio conversion completion/lifetime self-test failed.";
        return false;
    }
    return true;
}

bool absent(const std::wstring &path) {
    if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) return false;
    const DWORD code = GetLastError();
    return code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND;
}

bool verifyWaveFixture(const std::wstring &path, uint64_t samples, bool exactTone) {
    jsti::Handle file;
    file.value = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file.value == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file.value, &size) || static_cast<uint64_t>(size.QuadPart) != waveHeaderSize + samples * 2) return false;
    const auto expected = waveHeader(static_cast<uint32_t>(samples * 2));
    std::array<uint8_t, waveHeaderSize> actual{};
    DWORD read = 0;
    if (!ReadFile(file.value, actual.data(), static_cast<DWORD>(actual.size()), &read, nullptr) ||
        read != actual.size() || actual != expected) return false;
    std::array<uint8_t, 4096> buffer{};
    uint64_t offset = 0;
    bool audible = false;
    while (offset < samples) {
        const DWORD count = static_cast<DWORD>(std::min<uint64_t>(buffer.size() / 2, samples - offset));
        if (!ReadFile(file.value, buffer.data(), count * 2, &read, nullptr) || read != count * 2) return false;
        for (DWORD frame = 0; frame < count; ++frame) {
            const uint16_t value = static_cast<uint16_t>(buffer[frame * 2]) |
                (static_cast<uint16_t>(buffer[frame * 2 + 1]) << 8);
            if (value) audible = true;
            if (exactTone && value != static_cast<uint16_t>(((offset + frame) / (outputRate / 400)) % 2 ? 4096 : -4096)) {
                return false;
            }
        }
        offset += count;
    }
    return audible;
}
} // namespace

int jsti_audio_conversion_self_test(char *error, size_t capacity) {
    try {
        wchar_t temporary[32768] = {};
        const DWORD count = GetTempPathW(static_cast<DWORD>(std::size(temporary)), temporary);
        GUID guid{};
        wchar_t identifier[40] = {};
        if (!count || count >= std::size(temporary) || FAILED(CoCreateGuid(&guid)) ||
            !StringFromGUID2(guid, identifier, static_cast<int>(std::size(identifier)))) {
            return jsti::fail("Could not create unique conversion test paths.", error, capacity);
        }
        const std::wstring root = std::wstring(temporary) + L"JustSpeakToIt-conversion-test-" + identifier;
        if (!absent(root)) return jsti::fail("Conversion test path already exists.", error, capacity);
        char detail[1024] = {};
        if (jsti_private_directory_prepare(jsti::utf8(root).c_str(), detail, sizeof(detail)) != 0) {
            return jsti::fail(detail, error, capacity);
        }
        ConversionTestFiles files;
        files.root = root;
        const auto canonical = files.path(L"canonical.wav");
        const auto canonicalOutput = files.path(L"canonical-output.wav");
        createWaveFixture(canonical, outputRate, 1, 1600);
        std::string failure;
        ConversionTestResult first;
        if (!convertFixture(canonical, canonicalOutput, first, failure) || first.status != 0) {
            return jsti::fail(failure.empty() ? first.error : failure, error, capacity);
        }
        if (first.samples != 1600 || first.duration != 0.1 ||
            !verifyWaveFixture(canonicalOutput, 1600, true) || !verifyWaveFixture(canonical, 1600, true)) {
            return jsti::fail("Canonical PCM conversion changed sample bytes, metadata or its original.", error, capacity);
        }
        ConversionTestResult collision;
        if (!convertFixture(canonical, canonicalOutput, collision, failure) || collision.status != -1 ||
            collision.error.empty() || !verifyWaveFixture(canonicalOutput, 1600, true)) {
            return jsti::fail("Audio conversion did not preserve an existing output.", error, capacity);
        }
        const auto stereo = files.path(L"stereo-48khz.wav");
        const auto stereoOutput = files.path(L"stereo-output.wav");
        createWaveFixture(stereo, 48000, 2, 14400);
        ConversionTestResult resampled;
        if (!convertFixture(stereo, stereoOutput, resampled, failure) || resampled.status != 0) {
            return jsti::fail(failure.empty() ? resampled.error : failure, error, capacity);
        }
        if (resampled.samples < 4640 || resampled.samples > 4960 ||
            resampled.duration != static_cast<double>(resampled.samples) / outputRate ||
            !verifyWaveFixture(stereoOutput, resampled.samples, false)) {
            return jsti::fail("Stereo 48 kHz conversion did not produce bounded canonical mono audio.", error, capacity);
        }
        const auto corrupt = files.path(L"corrupt.wav");
        const auto corruptOutput = files.path(L"corrupt-output.wav");
        {
            jsti::Handle file;
            file.value = jsti::createPrivateFileHandle(jsti::utf8(corrupt).c_str(), failure);
            if (file.value == INVALID_HANDLE_VALUE) return jsti::fail(failure, error, capacity);
            const uint8_t junk[] = {1, 2, 3, 4, 5, 6};
            writeBytes(file.value, junk, sizeof(junk));
        }
        ConversionTestResult invalid;
        if (!convertFixture(corrupt, corruptOutput, invalid, failure) || invalid.status != -1 ||
            invalid.error.empty() || !absent(corruptOutput)) {
            return jsti::fail("Invalid audio left a partial conversion output.", error, capacity);
        }
        const auto oversized = files.path(L"oversized.wav");
        const auto oversizedOutput = files.path(L"oversized-output.wav");
        createWaveFixture(oversized, outputRate, 1, static_cast<DWORD>(fileLimit / 2), true);
        ConversionTestResult largeInput;
        if (!convertFixture(oversized, oversizedOutput, largeInput, failure) || largeInput.status != -1 ||
            largeInput.error.find("exceeds 25 MB") == std::string::npos || !absent(oversizedOutput)) {
            return jsti::fail("Audio conversion did not enforce the input byte limit.", error, capacity);
        }
        const auto expansion = files.path(L"expanding-8khz.wav");
        const auto expansionOutput = files.path(L"expansion-output.wav");
        createWaveFixture(expansion, 8000, 1, 6300000, true);
        ConversionTestResult largeOutput;
        if (!convertFixture(expansion, expansionOutput, largeOutput, failure) || largeOutput.status != -1 ||
            largeOutput.error.find("exceeds 25 MB") == std::string::npos || !absent(expansionOutput)) {
            return jsti::fail("Audio conversion did not enforce the output byte limit or remove its partial file.", error, capacity);
        }
        const auto cancelledOutput = files.path(L"cancelled-output.wav");
        auto unexpected = [](int, double, uint64_t, const char *, void *context) { *static_cast<bool *>(context) = true; };
        bool called = false;
        auto *cancelled = jsti_audio_conversion_create(jsti::utf8(canonical).c_str(), jsti::utf8(cancelledOutput).c_str(),
                                                       unexpected, &called, detail, sizeof(detail));
        if (!cancelled) return jsti::fail(detail, error, capacity);
        jsti_audio_conversion_cancel(cancelled);
        const int start = jsti_audio_conversion_start(cancelled, detail, sizeof(detail));
        const int destroyed = jsti_audio_conversion_destroy(cancelled, detail, sizeof(detail));
        if (start != -1 || destroyed != 0 || called || !absent(cancelledOutput)) {
            return jsti::fail("Cancelled-before-start audio conversion accessed its output or callback.", error, capacity);
        }
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const ConversionFailure &failure) {
        char detail[256] = {};
        std::snprintf(detail, sizeof(detail), "%s (HRESULT 0x%08lX).", failure.operation,
                      static_cast<unsigned long>(static_cast<uint32_t>(failure.code)));
        return jsti::fail(detail, error, capacity);
    } catch (const std::exception &) {
        return jsti::fail("Audio conversion self-test could not allocate its state.", error, capacity);
    }
}
