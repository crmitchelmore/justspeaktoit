/// Byte-exact output of the macOS definitions that preceded the SpeakCore
/// extraction. Store files use a default `JSONEncoder` (unspecified key order,
/// escaped slashes); the catalogue pins sort keys. Fragments keep lines short.
enum LocalModelPersistenceFixtures {
    /// `imported-hugging-face-models.json`
    static let importedTranscriptionModels = [
        #"[{"modelName":"openai_whisper-tiny","displayName":"Whisper Tiny from argmaxinc\/whisperkit-coreml",""#,
        #"description":"Imported from Hugging Face. WhisperKit will download the matching Core ML files from a"#,
        #"rgmaxinc\/whisperkit-coreml.","engine":"whisperkit","approximateSizeMB":75,"modelRepo":"argmaxinc\/w"#,
        #"hisperkit-coreml","supportsLiveStreaming":false,"id":"local\/whisperkit\/huggingface\/argmaxinc\/whi"#,
        #"sperkit-coreml\/openai-whisper-tiny"},{"modelName":"custom_model_123MB","displayName":"custom_model_"#,
        #"123MB from example\/custom-whisperkit","description":"Imported from Hugging Face. WhisperKit will do"#,
        #"wnload the matching Core ML files from example\/custom-whisperkit.","engine":"whisperkit","approxima"#,
        #"teSizeMB":123,"modelRepo":"example\/custom-whisperkit","supportsLiveStreaming":false,"id":"local\/wh"#,
        #"isperkit\/huggingface\/example\/custom-whisperkit\/custom-model-123mb"},{"modelName":"openai_whisper"#,
        #"-large-v3_turbo","modelRepo":"argmaxinc\/whisperkit-coreml","id":"local\/whisperkit\/huggingface\/ar"#,
        #"gmaxinc\/whisperkit-coreml\/openai-whisper-large-v3-turbo","displayName":"openai_whisper-large-v3_tu"#,
        #"rbo from argmaxinc\/whisperkit-coreml","description":"Imported from Hugging Face.","engine":"whisper"#,
        #"kit","supportsLiveStreaming":false,"approximateSizeMB":0},{"approximateSizeMB":12,"modelName":"futur"#,
        #"e-model","displayName":"Future Model","supportsLiveStreaming":true,"engine":"future-runtime","descri"#,
        #"ption":"Kept verbatim.","id":"local\/future-runtime\/custom\/model"}]"#
    ].joined()

    /// `streaming-model-sources.json`
    static let streamingModelSources = [
        #"[{"archiveURL":"https:\/\/github.com\/k2-fsa\/sherpa-onnx\/releases\/download\/asr-models\/sherpa-on"#,
        #"nx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2","modelName":"sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8","#,
        #""id":"local\/streaming\/huggingface\/k2-fsa\/sherpa-onnx\/sherpa-onnx-nemo-parakeet-tdt-0-6b-v3-int8"#,
        #"","repoID":"k2-fsa\/sherpa-onnx","runtime":"sherpa-onnx streaming runtime","approximateSizeMB":465},"#,
        #"{"approximateSizeMB":73,"id":"local\/streaming\/huggingface\/csukuangfj\/sherpa-onnx-streaming-zipfo"#,
        #"rmer-en-2023-06-26\/streaming-zipformer-en-2023-06-26","modelName":"streaming-zipformer-en-2023-06-2"#,
        #"6","runtime":"sherpa-onnx streaming runtime","repoID":"csukuangfj\/sherpa-onnx-streaming-zipformer-e"#,
        #"n-2023-06-26"},{"modelName":"zipformer-fr","id":"local\/streaming\/huggingface\/acme\/sherpa-onnx-st"#,
        #"reaming-zipformer-fr\/zipformer-fr","runtime":"sherpa-onnx streaming runtime","repoID":"acme\/sherpa"#,
        #"-onnx-streaming-zipformer-fr"},{"repoID":"nvidia\/parakeet-tdt-0.6b-v2","modelName":"parakeet-tdt-0."#,
        #"6b-v2","id":"local\/streaming\/huggingface\/nvidia\/parakeet-tdt-0-6b-v2\/parakeet-tdt-0-6b-v2","run"#,
        #"time":"NeMo \/ Parakeet runtime"},{"repoID":"csukuangfj\/sherpa-onnx-streaming-zipformer-en-20M-2023"#,
        #"-02-17","modelName":"streaming-zipformer-en-20M-2023-02-17","runtime":"Streaming ASR runtime","appro"#,
        #"ximateSizeMB":44,"id":"local\/streaming\/huggingface\/csukuangfj\/sherpa-onnx-streaming-zipformer-en"#,
        #"-20m-2023-02-17\/streaming-zipformer-en-20m-2023-02-17"}]"#
    ].joined()

    /// `imported-hugging-face-gguf-models.json`
    static let importedPostProcessingModels = [
        #"[{"repoID":"unsloth\/Qwen3-4B-GGUF","displayName":"Qwen3 4B Q4 K M from unsloth\/Qwen3-4B-GGUF","fil"#,
        #"ename":"Qwen3-4B-Q4_K_M.gguf","description":"Imported from Hugging Face. Runs locally through the ll"#,
        #"ama.cpp post-processing runtime.","approximateSizeMB":2500,"id":"local\/post-processing\/huggingface"#,
        #"\/unsloth\/qwen3-4b-gguf\/qwen3-4b-q4-k-m-gguf"},{"repoID":"bartowski\/Llama-3.2-1B-Instruct-GGUF",""#,
        #"displayName":"Llama 3.2 1B Instruct Q4 K M from bartowski\/Llama-3.2-1B-Instruct-GGUF","filename":"L"#,
        #"lama-3.2-1B-Instruct-Q4_K_M.gguf","description":"Imported from Hugging Face. Runs locally through th"#,
        #"e llama.cpp post-processing runtime.","id":"local\/post-processing\/huggingface\/bartowski\/llama-3-"#,
        #"2-1b-instruct-gguf\/llama-3-2-1b-instruct-q4-k-m-gguf"},{"repoID":"example\/tiny-models","displayNam"#,
        #"e":"tiny model 1.5GB from example\/tiny-models","filename":"tiny_model-1.5GB.gguf","description":"Im"#,
        #"ported from Hugging Face. Runs locally through the llama.cpp post-processing runtime.","approximateS"#,
        #"izeMB":1536,"id":"local\/post-processing\/huggingface\/example\/tiny-models\/tiny-model-1-5gb-gguf"}"#,
        #"]"#
    ].joined()

    /// `LocalModelManager.recommendedStreamingModelSources (sorted keys)`
    static let recommendedStreamingSources = [
        #"[{"approximateSizeMB":465,"archiveURL":"https:\/\/github.com\/k2-fsa\/sherpa-onnx\/releases\/downloa"#,
        #"d\/asr-models\/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2","id":"local\/streaming\/huggingfa"#,
        #"ce\/k2-fsa\/sherpa-onnx\/sherpa-onnx-nemo-parakeet-tdt-0-6b-v3-int8","modelName":"sherpa-onnx-nemo-p"#,
        #"arakeet-tdt-0.6b-v3-int8","repoID":"k2-fsa\/sherpa-onnx","runtime":"sherpa-onnx streaming runtime"},"#,
        #"{"approximateSizeMB":632,"archiveURL":"https:\/\/github.com\/k2-fsa\/sherpa-onnx\/releases\/download"#,
        #"\/asr-models\/sherpa-onnx-nemotron-speech-streaming-en-0.6b-1120ms-int8-2026-04-25.tar.bz2","id":"lo"#,
        #"cal\/streaming\/huggingface\/k2-fsa\/sherpa-onnx\/sherpa-onnx-nemotron-speech-streaming-en-0-6b-1120"#,
        #"ms-int8-2026-04-25","modelName":"sherpa-onnx-nemotron-speech-streaming-en-0.6b-1120ms-int8-2026-04-2"#,
        #"5","repoID":"k2-fsa\/sherpa-onnx","runtime":"sherpa-onnx streaming runtime"},{"approximateSizeMB":63"#,
        #"2,"archiveURL":"https:\/\/github.com\/k2-fsa\/sherpa-onnx\/releases\/download\/asr-models\/sherpa-on"#,
        #"nx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25.tar.bz2","id":"local\/streaming\/huggingf"#,
        #"ace\/k2-fsa\/sherpa-onnx\/sherpa-onnx-nemotron-speech-streaming-en-0-6b-560ms-int8-2026-04-25","mode"#,
        #"lName":"sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25","repoID":"k2-fsa\/sherp"#,
        #"a-onnx","runtime":"sherpa-onnx streaming runtime"},{"approximateSizeMB":71,"id":"local\/streaming\/h"#,
        #"uggingface\/csukuangfj\/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06\/streaming-zipformer-en-"#,
        #"kroko-2025-08-06","modelName":"streaming-zipformer-en-kroko-2025-08-06","repoID":"csukuangfj\/sherpa"#,
        #"-onnx-streaming-zipformer-en-kroko-2025-08-06","runtime":"sherpa-onnx streaming runtime"},{"approxim"#,
        #"ateSizeMB":181,"id":"local\/streaming\/huggingface\/csukuangfj\/sherpa-onnx-streaming-zipformer-en-2"#,
        #"023-06-21\/streaming-zipformer-en-2023-06-21","modelName":"streaming-zipformer-en-2023-06-21","repoI"#,
        #"D":"csukuangfj\/sherpa-onnx-streaming-zipformer-en-2023-06-21","runtime":"sherpa-onnx streaming runt"#,
        #"ime"},{"approximateSizeMB":73,"id":"local\/streaming\/huggingface\/csukuangfj\/sherpa-onnx-streaming"#,
        #"-zipformer-en-2023-06-26\/streaming-zipformer-en-2023-06-26","modelName":"streaming-zipformer-en-202"#,
        #"3-06-26","repoID":"csukuangfj\/sherpa-onnx-streaming-zipformer-en-2023-06-26","runtime":"sherpa-onnx"#,
        #" streaming runtime"},{"approximateSizeMB":44,"id":"local\/streaming\/huggingface\/csukuangfj\/sherpa"#,
        #"-onnx-streaming-zipformer-en-20m-2023-02-17\/streaming-zipformer-en-20m-2023-02-17","modelName":"str"#,
        #"eaming-zipformer-en-20M-2023-02-17","repoID":"csukuangfj\/sherpa-onnx-streaming-zipformer-en-20M-202"#,
        #"3-02-17","runtime":"sherpa-onnx streaming runtime"}]"#
    ].joined()

    /// `LocalPostProcessingModelManager.recommendedModels (sorted keys)`
    static let recommendedPostProcessingModels = [
        #"[{"approximateSizeMB":1100,"description":"Recommended tiny local LLM for higher-quality cleanup. Cur"#,
        #"rent Qwen3 family, stronger instructions.","displayName":"Qwen3 1.7B Q4","filename":"Qwen3-1.7B-Q4_K"#,
        #"_M.gguf","id":"local\/post-processing\/qwen3-1.7b-q4","repoID":"unsloth\/Qwen3-1.7B-GGUF"},{"approxi"#,
        #"mateSizeMB":450,"description":"Fastest current Qwen3 tiny local model. Good for quick simple cleanup"#,
        #" on-device.","displayName":"Qwen3 0.6B Q4","filename":"Qwen3-0.6B-Q4_K_M.gguf","id":"local\/post-pro"#,
        #"cessing\/qwen3-0.6b-q4","repoID":"unsloth\/Qwen3-0.6B-GGUF"},{"approximateSizeMB":230,"description":"#,
        #""Smallest recommended download. Best for quick cleanup, with lower quality on complex transcripts.","#,
        #""displayName":"SmolLM2 360M Instruct Q4","filename":"SmolLM2-360M-Instruct-Q4_K_M.gguf","id":"local"#,
        #"\/post-processing\/smollm2-360m-instruct-q4","repoID":"bartowski\/SmolLM2-360M-Instruct-GGUF"}]"#
    ].joined()
}
