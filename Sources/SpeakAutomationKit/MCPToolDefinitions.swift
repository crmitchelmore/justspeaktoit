import SpeakCore

extension MCPRequestHandler {
    static let toolDefinitions: [[String: Any]] = [
        [
            "name": AutomationCommand.awaitTranscript.rawValue,
            "description": "Await an identified active local Mac capture. No recording start or phone/Watch sync.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "capture_id": ["type": "string", "format": "uuid"],
                    "since_id": ["type": "string", "format": "uuid"],
                    "timeout_seconds": ["type": "number", "exclusiveMinimum": 0, "maximum": 600]
                ],
                "required": ["capture_id"]
            ]
        ],
        [
            "name": AutomationCommand.status.rawValue,
            "description": "Report app status and the active local capture identity, when present.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": AutomationCommand.transcribeFile.rawValue,
            "description": "Transcribe a local audio file using the user's configured provider.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to an audio file."],
                    "timeout_seconds": ["type": "number", "description": "Deadline in seconds."]
                ],
                "required": ["path"]
            ]
        ],
        [
            "name": AutomationCommand.getHistoryToolName,
            "description": "Return the most recent transcriptions, newest first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": AutomationLimits.maxHistoryLimit,
                        "description": "How many entries to return (default \(AutomationLimits.defaultHistoryLimit))."
                    ]
                ]
            ]
        ],
        [
            "name": AutomationCommand.startDictation.rawValue,
            "description": "Start a dictation session in the app. Idempotent per call id.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": AutomationCommand.stopDictation.rawValue,
            "description": "Stop the active dictation session and return its transcript.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": AutomationCommand.speakText.rawValue,
            "description": "Speak text aloud with the app's voices, or save it as an audio file. "
                + "Returns once playback finishes and the file is complete.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": [
                        "type": "string", "maxLength": AutomationLimits.maxSpeechCharacters,
                        "description": "The text to speak."
                    ],
                    "voice": [
                        "type": "string",
                        "description": "Voice ID or name from list_voices; omit for the app's selected voice, "
                            + "\"system\" for the on-device voice."
                    ],
                    "provider": ["type": "string", "description": "Provider ID or name from list_voices."],
                    "model": ["type": "string", "description": "Model ID from list_voices."],
                    "speed": [
                        "type": "number", "minimum": VoiceSynthesisOptions.speedRange.lowerBound,
                        "maximum": VoiceSynthesisOptions.speedRange.upperBound,
                        "description": "Speaking rate; 1 is normal. Checked against the voice."
                    ],
                    "pitch": [
                        "type": "integer", "minimum": Int(VoiceSynthesisOptions.pitchRange.lowerBound),
                        "maximum": Int(VoiceSynthesisOptions.pitchRange.upperBound),
                        "description": "Semitones; only voices with pitch control accept it."
                    ],
                    "quality": ["type": "string", "enum": VoiceSynthesisQuality.allCases.map(\.rawValue)],
                    "language": ["type": "string", "description": "automatic or a voice language ID, e.g. en-US."],
                    "path": ["type": "string", "description": "Audio file to write (.wav, .mp3 or .m4a)."],
                    "play": ["type": "boolean", "description": "Play aloud. Defaults to true without a path."],
                    "timeout_seconds": ["type": "number", "description": "Deadline in seconds."]
                ],
                "required": ["text"]
            ]
        ],
        [
            "name": AutomationCommand.listVoices.rawValue,
            "description": "List the providers, voices and models speak_text can use: the app's selected "
                + "voice, configured cloud voices and on-device voices.",
            "inputSchema": [
                "type": "object",
                "properties": ["provider": ["type": "string", "description": "Only this provider's voices."]]
            ]
        ]
    ]

}
