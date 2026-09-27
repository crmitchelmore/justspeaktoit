// One-shot local post-processing runner for Just Speak to It.
//
// The Windows app runs downloaded GGUF cleanup models through this executable,
// built from the pinned llama.cpp commit by build-llama-runtime.py. It runs in
// its own process beside its own ggml DLLs, so llama.cpp's ggml never shares a
// process with the whisper.cpp runtime's ggml (the two are different builds
// with the same DLL names). The macOS app also runs llama.cpp out of process.
//
// Protocol (all UTF-8, stdin and stdout in binary mode):
//   stdin:  "<system prompt byte count>\n<system prompt><user message>" to EOF
//   stdout: the generated assistant text only
//   stderr: diagnostics; "JSTI_TRUNCATED" on its own line when the output
//           reached --max-tokens
// Exit codes: 0 success, 2 usage, 3 model load, 4 prompt too long, 5 decode,
//             6 chat template.
//
// Arguments: --model <path> [--threads n] [--temperature t] [--max-tokens n]
//            [--gpu 0|1] [--seed n]; --version prints the pinned build.

#include "llama.h"

#include <algorithm>
#include <clocale>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#endif

#ifndef JSTI_LLAMA_BUILD
#define JSTI_LLAMA_BUILD "unknown"
#endif

namespace {
enum Exit { ok = 0, usage = 2, loadFailure = 3, promptTooLong = 4, decodeFailure = 5, templateFailure = 6 };

struct Options {
    std::string model;
    int threads = 0;
    float temperature = 0.2f;
    int maxTokens = 1024;
    bool gpu = true;
    uint32_t seed = 42;
    bool version = false;
};

bool parse(const std::vector<std::string> &arguments, Options &options) {
    for (size_t index = 1; index < arguments.size(); ++index) {
        const std::string &name = arguments[index];
        if (name == "--version") { options.version = true; continue; }
        if (index + 1 >= arguments.size()) return false;
        const std::string &value = arguments[++index];
        try {
            if (name == "--model") options.model = value;
            else if (name == "--threads") options.threads = std::stoi(value);
            else if (name == "--temperature") options.temperature = std::stof(value);
            else if (name == "--max-tokens") options.maxTokens = std::stoi(value);
            else if (name == "--gpu") options.gpu = value != "0";
            else if (name == "--seed") options.seed = static_cast<uint32_t>(std::stoul(value));
            else return false;
        } catch (...) { return false; }
    }
    return options.version || (!options.model.empty() && options.maxTokens > 0 && options.maxTokens <= 16384 &&
                               options.temperature >= 0 && options.temperature <= 2 && options.threads >= 0);
}

bool readRequest(std::string &system, std::string &user) {
    std::string input((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
    const size_t newline = input.find('\n');
    if (newline == std::string::npos || newline == 0 || newline > 10) return false;
    size_t length = 0;
    for (size_t index = 0; index < newline; ++index) {
        if (input[index] < '0' || input[index] > '9') return false;
        length = length * 10 + static_cast<size_t>(input[index] - '0');
    }
    if (input.size() - newline - 1 < length) return false;
    system = input.substr(newline + 1, length);
    user = input.substr(newline + 1 + length);
    return true;
}

// The directory holding this executable: ggml's backends load from there only.
std::string executableDirectory(const std::string &argument0) {
#ifdef _WIN32
    std::wstring path(32768, L'\0');
    const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0 || length >= path.size()) return ".";
    path.resize(length);
    const size_t slash = path.find_last_of(L"\\/");
    if (slash != std::wstring::npos) path.resize(slash);
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1, nullptr, 0, nullptr, nullptr);
    std::string utf8(static_cast<size_t>(bytes > 0 ? bytes : 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1, utf8.data(), bytes, nullptr, nullptr);
    utf8.resize(std::strlen(utf8.c_str()));
    return utf8;
#else
    const size_t slash = argument0.find_last_of('/');
    return slash == std::string::npos ? "." : argument0.substr(0, slash);
#endif
}

void logErrors(enum ggml_log_level level, const char *text, void *) {
    if (level >= GGML_LOG_LEVEL_ERROR && text) std::fputs(text, stderr);
}

int run(const std::vector<std::string> &arguments) {
    std::setlocale(LC_NUMERIC, "C");
    Options options;
    if (!parse(arguments, options)) {
        std::fputs("usage: jsti-llama-runner --model <gguf> [--threads n] [--temperature t] [--max-tokens n] "
                   "[--gpu 0|1] [--seed n] | --version\n", stderr);
        return usage;
    }
    if (options.version) {
        std::fputs("llama.cpp " JSTI_LLAMA_BUILD "\n", stdout);
        return ok;
    }
    std::string system, user;
    if (!readRequest(system, user)) {
        std::fputs("The request on standard input is malformed.\n", stderr);
        return usage;
    }

    llama_log_set(logErrors, nullptr);
    ggml_backend_load_all_from_path(executableDirectory(arguments.empty() ? "" : arguments[0]).c_str());
    llama_backend_init();

    llama_model_params modelParameters = llama_model_default_params();
    modelParameters.n_gpu_layers = options.gpu ? 999 : 0;
    // The default callback prints loading dots to stderr.
    modelParameters.progress_callback = [](float, void *) { return true; };
    llama_model *model = llama_model_load_from_file(options.model.c_str(), modelParameters);
    if (!model) {
        std::fputs("The model could not be loaded.\n", stderr);
        return loadFailure;
    }
    const llama_vocab *vocab = llama_model_get_vocab(model);

    const char *chatTemplate = llama_model_chat_template(model, nullptr);
    std::vector<llama_chat_message> messages;
    if (!system.empty()) messages.push_back({"system", system.c_str()});
    messages.push_back({"user", user.c_str()});
    std::vector<char> formatted(system.size() + user.size() + 1024);
    int length = llama_chat_apply_template(chatTemplate, messages.data(), messages.size(), true, formatted.data(),
                                           static_cast<int32_t>(formatted.size()));
    if (length > static_cast<int>(formatted.size())) {
        formatted.resize(static_cast<size_t>(length));
        length = llama_chat_apply_template(chatTemplate, messages.data(), messages.size(), true, formatted.data(),
                                           static_cast<int32_t>(formatted.size()));
    }
    if (length < 0) {
        std::fputs("The model's chat template is not supported.\n", stderr);
        llama_model_free(model);
        return templateFailure;
    }
    std::string prompt(formatted.begin(), formatted.begin() + length);
    // Hybrid reasoning models (Qwen3) skip thinking when the assistant turn
    // opens with an empty think block, as their own templates do when
    // thinking is disabled. Cleanup never needs reasoning.
    if (chatTemplate && std::strstr(chatTemplate, "<think>")) prompt += "<think>\n\n</think>\n\n";

    const int promptTokens = -llama_tokenize(vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()), nullptr, 0,
                                             true, true);
    std::vector<llama_token> tokens(static_cast<size_t>(std::max(promptTokens, 0)));
    if (promptTokens <= 0 ||
        llama_tokenize(vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()), tokens.data(),
                       static_cast<int32_t>(tokens.size()), true, true) < 0) {
        std::fputs("The prompt could not be tokenised.\n", stderr);
        llama_model_free(model);
        return decodeFailure;
    }
    const int trained = llama_model_n_ctx_train(model);
    const int contextSize = std::min(promptTokens + options.maxTokens + 8, trained > 0 ? trained : 32768);
    if (promptTokens + 8 >= contextSize) {
        std::fputs("The transcript is too long for this model's context window.\n", stderr);
        llama_model_free(model);
        return promptTooLong;
    }

    llama_context_params contextParameters = llama_context_default_params();
    contextParameters.n_ctx = static_cast<uint32_t>(contextSize);
    contextParameters.n_batch = static_cast<uint32_t>(std::min(contextSize, 2048));
    const unsigned hardware = std::max(1u, std::thread::hardware_concurrency());
    const int threads = options.threads > 0 ? options.threads : static_cast<int>(std::min(8u, hardware));
    contextParameters.n_threads = threads;
    contextParameters.n_threads_batch = threads;
    llama_context *context = llama_init_from_model(model, contextParameters);
    if (!context) {
        std::fputs("The model context could not be created.\n", stderr);
        llama_model_free(model);
        return loadFailure;
    }

    llama_sampler *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (options.temperature <= 0) {
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05f, 1));
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(options.temperature));
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(options.seed));
    }

    int status = ok;
    std::string response;
    bool truncated = true;
    // Prompts larger than one batch are decoded in batch-sized slices.
    for (size_t start = 0; start < tokens.size() && status == ok;) {
        const size_t count = std::min(tokens.size() - start, static_cast<size_t>(contextParameters.n_batch));
        if (llama_decode(context, llama_batch_get_one(tokens.data() + start, static_cast<int32_t>(count))) != 0) {
            status = decodeFailure;
        }
        start += count;
    }
    for (int generated = 0; status == ok && generated < options.maxTokens; ++generated) {
        llama_token next = llama_sampler_sample(sampler, context, -1);
        if (llama_vocab_is_eog(vocab, next)) { truncated = false; break; }
        char piece[256];
        const int bytes = llama_token_to_piece(vocab, next, piece, sizeof(piece), 0, false);
        if (bytes < 0) { status = decodeFailure; break; }
        response.append(piece, static_cast<size_t>(bytes));
        if (llama_decode(context, llama_batch_get_one(&next, 1)) != 0) status = decodeFailure;
    }
    if (status == ok) {
        std::fwrite(response.data(), 1, response.size(), stdout);
        std::fflush(stdout);
        if (truncated) std::fputs("JSTI_TRUNCATED\n", stderr);
    } else {
        std::fputs("Generation failed in the local model runtime.\n", stderr);
    }
    llama_sampler_free(sampler);
    llama_free(context);
    llama_model_free(model);
    llama_backend_free();
    return status;
}
} // namespace

#ifdef _WIN32
// Wide arguments keep a model path under a non-ASCII user profile intact.
int wmain(int argc, wchar_t **argv) {
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
    std::vector<std::string> arguments;
    for (int index = 0; index < argc; ++index) {
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, argv[index], -1, nullptr, 0, nullptr, nullptr);
        std::string value(static_cast<size_t>(bytes > 0 ? bytes : 1), '\0');
        WideCharToMultiByte(CP_UTF8, 0, argv[index], -1, value.data(), bytes, nullptr, nullptr);
        value.resize(std::strlen(value.c_str()));
        arguments.push_back(value);
    }
    return run(arguments);
}
#else
int main(int argc, char **argv) { return run(std::vector<std::string>(argv, argv + argc)); }
#endif
