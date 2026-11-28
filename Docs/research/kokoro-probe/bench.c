#include "c-api.h"
#include "input.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
static double now(void) {
    LARGE_INTEGER ticks, frequency;
    QueryPerformanceCounter(&ticks);
    QueryPerformanceFrequency(&frequency);
    return (double)ticks.QuadPart / frequency.QuadPart;
}
static double memory_mb(int peak) {
    PROCESS_MEMORY_COUNTERS info;
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &info, sizeof(info))) exit(2);
    return (peak ? info.PeakWorkingSetSize : info.WorkingSetSize) / 1e6;
}
#else
#include <time.h>
#include <mach/mach.h>
#include <sys/resource.h>
static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
static double memory_mb(int peak) {
    if (peak) {
        struct rusage usage;
        if (getrusage(RUSAGE_SELF, &usage)) exit(2);
        return usage.ru_maxrss / 1e6;
    }
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) exit(2);
    return info.resident_size / 1e6;
}
#endif

static double first;
static int callbacks;
static int32_t callback(const float *samples, int32_t n, float progress, void *arg) {
    if (samples && n > 0 && callbacks++ == 0) first = now();
    return 1;
}
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    int threads = atoi(argv[1]);
    int split = strcmp(argv[2], "split") == 0;
    int sentences = strcmp(argv[2], "short") == 0 ? 1 : 10;
    SherpaOnnxOfflineTtsConfig config = {0};
    config.model.kokoro.model = "model.int8.onnx";
    config.model.kokoro.voices = "voices.bin";
    config.model.kokoro.tokens = "tokens.txt";
    config.model.kokoro.lexicon = argv[3];
    config.model.num_threads = threads;
    config.model.provider = "cpu";
    config.max_num_sentences = 1;
    config.silence_scale = 0.2f;
    double start = now();
    const SherpaOnnxOfflineTts *tts = SherpaOnnxCreateOfflineTts(&config);
    if (!tts) return 3;
    double load = now() - start, rss = memory_mb(0);
    int offset = 0, samples = 0;
    start = now();
    for (int i = 0; i < sentences; i += split ? 1 : sentences) {
        SherpaOnnxGenerationConfig gen = {0};
        gen.speed = 1;
        gen.silence_scale = 0.2f;
        gen.phoneme_codepoints = points + offset;
        gen.phoneme_codepoints_lens = lengths + i;
        gen.phoneme_codepoints_num_sentences = split ? 1 : sentences;
        const SherpaOnnxGeneratedAudio *audio = SherpaOnnxOfflineTtsGenerateWithConfig(tts, "", &gen, callback, NULL);
        if (!audio || audio->n <= 0 || audio->sample_rate != 24000) return 4;
        samples += audio->n;
        offset += lengths[i];
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
    }
    double elapsed = now() - start;
    if (!callbacks) return 5;
    printf("%d,%s,%.4f,%.2f,%.2f,%.4f,%.4f,%.4f,%d,%s\n", threads, argv[2], load, rss, memory_mb(1),
           first-start, elapsed, samples/24000.0, callbacks, SherpaOnnxGetVersionStr());
    SherpaOnnxDestroyOfflineTts(tts);
    return 0;
}
