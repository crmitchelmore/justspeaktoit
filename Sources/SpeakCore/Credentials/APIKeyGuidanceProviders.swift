import Foundation

// The provider table behind `APIKeyGuidance.guides`. Each entry restates its
// provider's documentation as of `APIKeyGuidance.lastVerified`; update the
// date and sources together. Long literals keep each label exactly as the
// provider writes it.
// swiftlint:disable line_length file_length
extension APIKeyGuidance {
    public static let guides: [APIKeyProviderGuide] = multiUseGuides + remainingGuides

    /// Split in two only to keep each literal within the type checker's budget.
    static let multiUseGuides: [APIKeyProviderGuide] = [
        APIKeyProviderGuide(
            providerName: "OpenAI",
            identifiers: ["openai.apiKey", OpenAITTSCatalog.credentialIdentifier],
            creationURL: url("https://platform.openai.com/api-keys"),
            steps: ["Choose the project", "Create new secret key", "Permissions: Restricted"],
            scopes: .granular,
            requirements: [
                APIKeyPermissionRequirement(
                    .transcription, permissions: ["Model capabilities: Request"],
                    endpoints: ["/v1/audio/transcriptions", "/v1/realtime (transcription sessions)"],
                    note: "OpenAI documents this permission for /v1/audio and /v1/realtime as a whole."
                ),
                APIKeyPermissionRequirement(
                    .voiceOutput, permissions: ["Model capabilities: Request"],
                    endpoints: ["/v1/audio/speech", "/v1/realtime (Realtime voices)"]
                ),
                APIKeyPermissionRequirement(nil, permissions: ["List models: Read"], endpoints: ["GET /v1/models"])
            ],
            expiry: APIKeyExpiryGuidance(
                .configurable("an expiration date on project keys"),
                providerRecommendation: "set an expiration date when you create a project API key and keep a regular rotation process."
            ),
            notes: ["Transcription and Voice Output use separate stored OpenAI keys, so each can be restricted to its own use."],
            sources: [
                url("https://developers.openai.com/api/docs/guides/rbac"),
                url("https://developers.openai.com/api/docs/guides/production-best-practices"),
                url("https://help.openai.com/en/articles/8867743-assign-api-key-permissions")
            ]
        ),
        APIKeyProviderGuide(
            providerName: "OpenRouter",
            identifiers: [APIKeyCatalog.openRouterIdentifier],
            creationURL: OpenRouterService.apiKeysURL,
            steps: ["Keys", "Create Key", "give it a name and a credit limit"],
            scopes: .none("A standard key can call every model; a credit limit is the documented way to cap it. Never use a management key: it cannot call models."),
            requirements: [
                APIKeyPermissionRequirement(.postProcessing, permissions: [], endpoints: ["/api/v1/chat/completions"]),
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/api/v1/audio", "/api/v1/chat/completions with audio input"]),
                APIKeyPermissionRequirement(.voiceOutput, permissions: [], endpoints: ["/api/v1/audio"]),
                APIKeyPermissionRequirement(nil, permissions: [], endpoints: ["GET /api/v1/key"]),
                APIKeyPermissionRequirement(
                    nil, permissions: [], endpoints: ["GET /api/v1/credits"],
                    note: "Shows the balance only; dictation works without it.", isOptional: true
                )
            ],
            expiry: APIKeyExpiryGuidance(
                .notDocumented,
                providerRecommendation: "set a credit limit on every key. OpenRouter documents an expires_at field only for keys created through its management API."
            ),
            notes: ["One OpenRouter key serves every OpenRouter feature you use in Speak."],
            sources: [
                url("https://openrouter.ai/docs/api/api-reference/api-keys/create-keys"),
                url("https://openrouter.ai/docs/api_reference/authentication")
            ]
        ),
        APIKeyProviderGuide(
            providerName: "Deepgram",
            identifiers: ["deepgram.apiKey"],
            creationURL: url("https://console.deepgram.com/signup?jump=keys"),
            steps: ["Choose the project", "Settings", "API Keys", "Create a New API Key", "Advanced", "permission Member"],
            scopes: .granular,
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: ["Member role"], endpoints: ["/v1/listen (REST and WebSocket)"]),
                APIKeyPermissionRequirement(.voiceOutput, permissions: ["Member role"], endpoints: ["/v1/speak"]),
                APIKeyPermissionRequirement(nil, permissions: ["Member role"], endpoints: ["GET /v1/projects"]),
                APIKeyPermissionRequirement(
                    nil, permissions: ["billing:read (Owner or Admin)"], endpoints: ["GET /v1/projects/{id}/balances"],
                    note: "The balance line may be unavailable with a Member key. Do not raise the role for it.",
                    isOptional: true
                )
            ],
            expiry: APIKeyExpiryGuidance(.configurable("an expiration date or duration")),
            notes: [],
            sources: [
                url("https://developers.deepgram.com/docs/create-additional-api-keys"),
                url("https://developers.deepgram.com/docs/working-with-roles"),
                url("https://developers.deepgram.com/reference/auth/tokens/grant")
            ]
        ),
        APIKeyProviderGuide(
            providerName: "ElevenLabs",
            identifiers: [ElevenLabsTTSCatalog.credentialIdentifier],
            creationURL: url("https://elevenlabs.io/app/settings/api-keys"),
            steps: ["Developers", "API Keys", "Create API Key", "keep Restrict Key on"],
            scopes: .granular,
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: ["Speech to Text"], endpoints: ["/v1/speech-to-text"]),
                APIKeyPermissionRequirement(
                    .voiceOutput, permissions: ["Text to Speech", "Voices: Read"],
                    endpoints: ["/v1/text-to-speech", "/v1/voices"]
                ),
                APIKeyPermissionRequirement(
                    nil, permissions: ["User: Read"], endpoints: ["GET /v1/user", "GET /v1/user/subscription"],
                    note: "Speak's key check reads the user, and the balance line reads the subscription."
                )
            ],
            expiry: APIKeyExpiryGuidance(.configurable("Expire After (15 minutes to 30 days, or Never)")),
            notes: ["ElevenLabs names these speech_to_text, text_to_speech, voices_read and user_read in its API; check the labels in the dialog."],
            sources: [
                url("https://elevenlabs.io/docs/overview/administration/workspaces/api-keys"),
                url("https://elevenlabs.io/docs/api-reference/authentication")
            ]
        ),
        APIKeyProviderGuide(
            providerName: "Soniox",
            identifiers: ["soniox.apiKey"],
            creationURL: url("https://console.soniox.com"),
            steps: ["Open the project", "API keys", "Create API key", "turn off Full access"],
            scopes: .granular,
            requirements: [
                APIKeyPermissionRequirement(
                    .transcription,
                    permissions: ["Speech-to-text, real-time", "Speech-to-text, async: Write", "Files: Write"],
                    endpoints: ["WebSocket transcription", "/v1/files upload", "/v1/transcriptions and their results"],
                    note: "Async and Files are needed only for recorded-audio models; Soniox does not say whether Write is required."
                ),
                APIKeyPermissionRequirement(.voiceOutput, permissions: ["Text-to-speech, real-time"], endpoints: ["Soniox TTS"]),
                APIKeyPermissionRequirement(
                    nil, permissions: ["Temporary API keys", "Speech-to-text, real-time"],
                    endpoints: ["POST /v1/auth/temporary-api-key"],
                    note: "Speak checks a key by creating a 60-second real-time transcription key."
                )
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented),
            notes: ["Soniox lets you edit permissions later without changing the key."],
            sources: [url("https://docs.soniox.com/guides/api-key-permissions")]
        ),
        APIKeyProviderGuide(
            providerName: "xAI",
            identifiers: ["xai.apiKey"],
            creationURL: url("https://console.x.ai"),
            steps: ["Choose the team", "API Keys", "Create API Key"],
            scopes: .granular,
            requirements: [
                APIKeyPermissionRequirement(
                    .transcription, permissions: ["speech-to-text endpoint access"], endpoints: ["wss /v1/stt", "Grok Voice realtime"]
                ),
                APIKeyPermissionRequirement(.voiceOutput, permissions: ["text-to-speech endpoint access"], endpoints: ["/v1/tts", "/v1/tts/voices"]),
                APIKeyPermissionRequirement(nil, permissions: ["api-key:endpoint:models"], endpoints: ["GET /v1/models"])
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented, providerRecommendation: "rotate keys regularly."),
            notes: ["xAI limits keys with endpoint and model ACLs but does not document the ACL names for its speech endpoints, so Speak cannot name them exactly. Its expireTime field is documented only for the management API."],
            sources: [
                url("https://docs.x.ai/developers/management-api-guide"),
                url("https://docs.x.ai/console/faq/security")
            ]
        ),
        APIKeyProviderGuide(
            providerName: "Mistral",
            identifiers: [MistralTTSCatalog.credentialIdentifier],
            creationURL: url("https://console.mistral.ai/api-keys"),
            steps: ["Choose the workspace", "Create new key", "leave Connector access scope at Shared connectors only"],
            scopes: .none("Keys are scoped to the workspace they were created in, so use a workspace only for Speak."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/v1/audio/transcriptions"]),
                APIKeyPermissionRequirement(.voiceOutput, permissions: [], endpoints: ["/v1/audio/speech", "/v1/audio/voices"]),
                APIKeyPermissionRequirement(nil, permissions: [], endpoints: ["GET /v1/models"])
            ],
            expiry: APIKeyExpiryGuidance(
                .configurable("Expiration"),
                providerRecommendation: "regular rotation improves security. Expiration cannot be changed after creation."
            ),
            notes: [],
            sources: [url("https://docs.mistral.ai/admin/identity-access/api-keys")]
        ),
        APIKeyProviderGuide(
            providerName: "Anthropic",
            identifiers: [ProviderCredentialCatalogue.apiKeyIdentifier(for: NativeTextModels.anthropic.id)],
            creationURL: url("https://platform.claude.com/settings/keys"),
            steps: ["Choose the workspace", "Create Key", "give it a name"],
            scopes: .none("Keys are scoped to the workspace they were created in; a workspace for Speak can carry its own spend limit."),
            requirements: [
                APIKeyPermissionRequirement(.postProcessing, permissions: [], endpoints: ["/v1/chat/completions"])
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented, providerRecommendation: "rotate API keys regularly and set a workspace spend limit."),
            notes: ["Speak uses Anthropic's OpenAI-compatible endpoint for transcript cleanup only."],
            sources: [
                url("https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/openai-sdk"),
                url("https://platform.claude.com/docs/en/manage-claude/authentication")
            ]
        ),
        APIKeyProviderGuide(
            providerName: "Groq",
            identifiers: [GroqTTSCatalog.credentialIdentifier],
            creationURL: url("https://console.groq.com/keys"),
            steps: ["Choose the project", "API Keys", "Create API Key"],
            scopes: .none("Groq limits models per organisation or project, not per key; a project for Speak can use Only Allow limits."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/openai/v1/audio/transcriptions"]),
                APIKeyPermissionRequirement(
                    .voiceOutput, permissions: [], endpoints: ["/openai/v1/audio/speech"],
                    note: "Orpheus voices also need the organisation to accept the model terms."
                ),
                APIKeyPermissionRequirement(nil, permissions: [], endpoints: ["GET /openai/v1/models"])
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented, providerRecommendation: "rotate API keys periodically (e.g., quarterly)."),
            notes: [],
            sources: [
                url("https://console.groq.com/docs/model-permissions"),
                url("https://console.groq.com/docs/production-readiness/security-onboarding")
            ]
        ),
        APIKeyProviderGuide(
            providerName: "Google Gemini",
            identifiers: [GeminiTTSCatalog.credentialIdentifier],
            creationURL: url("https://aistudio.google.com/apikey"),
            steps: ["Create API key", "choose the Google Cloud project", "if it shows Unrestricted: Add restrictions", "Restrict to Gemini API only"],
            scopes: .granular,
            requirements: [
                APIKeyPermissionRequirement(
                    .transcription, permissions: ["Gemini API (Generative Language API) only"],
                    endpoints: ["/upload/v1beta/files", "/v1beta/interactions"]
                ),
                APIKeyPermissionRequirement(
                    .voiceOutput, permissions: ["Gemini API (Generative Language API) only"], endpoints: ["/v1beta/interactions"]
                ),
                APIKeyPermissionRequirement(nil, permissions: ["Gemini API (Generative Language API) only"], endpoints: ["GET /v1beta/models"])
            ],
            expiry: APIKeyExpiryGuidance(
                .notDocumented,
                providerRecommendation: "periodically create new keys, move applications to them and delete the old ones; keep the old key until the new one works."
            ),
            notes: ["Google offers no narrower per-feature restriction than the Gemini API."],
            sources: [
                url("https://aistudio.google.com/docs/api-key"),
                url("https://docs.cloud.google.com/docs/authentication/api-keys-best-practices")
            ]
        ),
        APIKeyProviderGuide(
            providerName: "Azure Speech",
            identifiers: [AzureSpeechConfiguration.credentialIdentifier],
            creationURL: url("https://portal.azure.com"),
            steps: ["Open your Speech resource", "Keys and Endpoint", "copy Key 1 or Key 2 and the Location/Region"],
            scopes: .none("A key opens the whole Speech resource, so use a resource only for Speak."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["Speech to text (batch and real time)"]),
                APIKeyPermissionRequirement(.voiceOutput, permissions: [], endpoints: ["Text to speech", "voices list"]),
                APIKeyPermissionRequirement(nil, permissions: [], endpoints: ["voices list for the region"])
            ],
            expiry: APIKeyExpiryGuidance(
                .notDocumented,
                providerRecommendation: "use the two keys to rotate: move clients to Key 1, regenerate Key 2, switch to Key 2, then regenerate Key 1."
            ),
            notes: [],
            sources: [url("https://learn.microsoft.com/en-us/azure/ai-services/rotate-keys")]
        )
    ]

    /// The remaining credentials, most of them used only for transcription.
    static let remainingGuides: [APIKeyProviderGuide] = [
        APIKeyProviderGuide(
            providerName: "Alibaba Model Studio",
            identifiers: [AlibabaSpeechConfiguration.credentialIdentifier],
            creationURL: url("https://modelstudio.console.alibabacloud.com/ap-southeast-1/settings/api-key"),
            steps: ["Choose the region at the top right", "Create API Key", "choose the workspace", "Permissions: Custom", "Access Scope: the speech models you use"],
            scopes: .granular,
            requirements: [
                APIKeyPermissionRequirement(
                    .transcription, permissions: ["Access Scope limited to the speech recognition models you select"],
                    endpoints: ["the workspace's realtime and recorded speech recognition endpoints"]
                )
            ],
            expiry: APIKeyExpiryGuidance(.notOffered),
            notes: ["Keys work only in their region. Mainland China keys are created at bailian.console.aliyun.com instead."],
            sources: [url("https://www.alibabacloud.com/help/en/model-studio/get-api-key")]
        ),
        APIKeyProviderGuide(
            providerName: "AssemblyAI",
            identifiers: ["assemblyai.apiKey"],
            creationURL: url("https://www.assemblyai.com/dashboard/home"),
            steps: ["Workspace", "Manage", "API Keys", "Create New API Key"],
            scopes: .none("Keys are scoped to a project, and a key can transcribe only files uploaded in its project; use a project for Speak."),
            requirements: [
                APIKeyPermissionRequirement(
                    .transcription, permissions: [],
                    endpoints: ["/v2/upload", "/v2/transcript and its result", "streaming WebSocket"]
                ),
                APIKeyPermissionRequirement(nil, permissions: [], endpoints: ["/v2/transcript"])
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented),
            notes: [],
            sources: [url("https://www.assemblyai.com/docs/account-management")]
        ),
        APIKeyProviderGuide(
            providerName: "Cartesia",
            identifiers: [CartesiaTTSCatalog.credentialIdentifier],
            creationURL: url("https://play.cartesia.ai/keys"),
            steps: ["API Keys", "create a standard key, not an Admin key"],
            scopes: .none("Standard keys have full account access; Admin keys are rejected for speech and are not needed."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/stt"]),
                APIKeyPermissionRequirement(.voiceOutput, permissions: [], endpoints: ["/tts/bytes"]),
                APIKeyPermissionRequirement(nil, permissions: [], endpoints: ["GET /voices"])
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented),
            notes: [],
            sources: [url("https://docs.cartesia.ai/get-started/authenticate-your-client-applications")]
        ),
        APIKeyProviderGuide(
            providerName: "Speechmatics",
            identifiers: [SpeechmaticsTTSCatalog.credentialIdentifier],
            creationURL: url("https://portal.speechmatics.com/settings/api-keys/"),
            steps: ["Settings", "API Keys", "name the key", "Generate"],
            scopes: .none("Speechmatics scopes only short-lived temporary keys, which Speak does not use."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/v2/jobs and their transcripts", "real-time WebSocket"]),
                APIKeyPermissionRequirement(.voiceOutput, permissions: [], endpoints: ["Speechmatics TTS (preview)"])
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented),
            notes: [],
            sources: [url("https://docs.speechmatics.com/get-started/authentication")]
        ),
        APIKeyProviderGuide(
            providerName: "Rev.ai",
            identifiers: ["revai.apiKey"],
            creationURL: url("https://www.rev.ai/access-token"),
            steps: ["Access Token", "Generate New Access Token"],
            scopes: .none("Access tokens carry the account's full API access."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/speechtotext/v1/jobs (upload, status and transcript)", "streaming WebSocket"]),
                APIKeyPermissionRequirement(nil, permissions: [], endpoints: ["GET /speechtotext/v1/jobs"]),
                APIKeyPermissionRequirement(
                    nil, permissions: [], endpoints: ["GET /speechtotext/v1/account"],
                    note: "Shows the balance only.", isOptional: true
                )
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented),
            notes: ["Rev.ai allows two tokens at once, so create the replacement before deleting the old one."],
            sources: [url("https://docs.rev.ai/get-started/")]
        ),
        APIKeyProviderGuide(
            providerName: "Gladia",
            identifiers: ["gladia.apiKey"],
            creationURL: url("https://app.gladia.io/apikeys"),
            steps: ["API keys", "create a key for Speak"],
            scopes: .none("A key is the only authentication method and covers every endpoint."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/v2/upload", "/v2/pre-recorded and its result", "/v2/live"]),
                APIKeyPermissionRequirement(nil, permissions: [], endpoints: ["GET /v2/live"])
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented),
            notes: [],
            sources: [url("https://docs.gladia.io/api-reference/authentication")]
        ),
        APIKeyProviderGuide(
            providerName: "Modulate",
            identifiers: ["modulate.apiKey"],
            creationURL: ModulateTranscriptionService.apiKeysURL,
            steps: ["Dashboard", "API Keys", "create a key"],
            scopes: .none("Model access and limits belong to the organisation, not the key."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["batch transcription", "velma-2 streaming WebSocket"])
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented),
            notes: [],
            sources: [url("https://docs.modulate.ai/guides/authentication")]
        ),
        APIKeyProviderGuide(
            providerName: "Smallest AI",
            identifiers: ["smallest.apiKey"],
            creationURL: url("https://app.smallest.ai/dashboard/api-keys"),
            steps: ["Developer", "API Keys", "Create API Key"],
            scopes: .none("Smallest AI documents no key permissions."),
            requirements: [APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/waves/v1/stt/"])],
            expiry: APIKeyExpiryGuidance(.notDocumented, providerRecommendation: "rotate keys periodically from the API Keys page."),
            notes: [],
            sources: [url("https://docs.smallest.ai/waves/documentation/getting-started/authentication")]
        ),
        APIKeyProviderGuide(
            providerName: "Reson8",
            identifiers: ["reson8.apiKey"],
            creationURL: url("https://console.reson8.dev"),
            steps: ["Create a client for Speak", "generate an API key for it"],
            scopes: .none("Keys are scoped to a client, so use a client only for Speak."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/v1/speech-to-text/prerecorded", "/v1/speech-to-text/realtime"])
            ],
            expiry: APIKeyExpiryGuidance(.notDocumented),
            notes: [],
            sources: [url("https://docs.reson8.dev/authentication/")]
        ),
        APIKeyProviderGuide(
            providerName: "StepFun",
            identifiers: ["stepfun.apiKey"],
            creationURL: url("https://platform.stepfun.ai/interface-key"),
            steps: ["Sign in to the StepFun Open Platform", "Interface Keys", "Create Key"],
            scopes: .none("StepFun documents no key permissions."),
            requirements: [APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/v1/audio/asr/sse"])],
            expiry: APIKeyExpiryGuidance(.notDocumented),
            notes: [
                "Keys are region-bound: platform.stepfun.ai keys work only internationally and platform.stepfun.com "
                    + "(China) keys only in China. Choose the matching region before saving."
            ],
            sources: [
                url("https://platform.stepfun.ai/docs/en/quickstart/overview.md"),
                url("https://platform.stepfun.com/docs/zh/quickstart/create-api-key")
            ]
        ),
        APIKeyProviderGuide(
            providerName: "Meta",
            identifiers: ["meta.apiKey"],
            creationURL: url("https://dev.meta.ai"),
            steps: ["Model API dashboard", "API keys", "Create API key"],
            scopes: .none("Meta documents no key permissions; keys on a team share its rate limits."),
            requirements: [
                APIKeyPermissionRequirement(.transcription, permissions: [], endpoints: ["/v1/asr/transcribe", "/v1/asr/realtime"])
            ],
            expiry: APIKeyExpiryGuidance(
                .notDocumented,
                providerRecommendation: "to rotate, create a new key, move applications to it, then delete the old key."
            ),
            notes: [],
            sources: [url("https://dev.meta.ai/docs/authentication")]
        )
    ]
}
// swiftlint:enable line_length file_length
