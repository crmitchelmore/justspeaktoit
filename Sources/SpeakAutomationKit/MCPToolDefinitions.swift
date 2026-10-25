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
        ]
    ]

}
