#!/bin/bash

# Apply streaming upload patches
# This script applies all the necessary changes for streaming audio uploads

set -e

echo "========================================="
echo "Applying Streaming Upload Patches"
echo "========================================="
echo ""

cd /Users/cm/work/justspeaktoit

# Check we're on the right branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "perf/stream-audio-uploads" ]; then
    echo "❌ ERROR: Not on perf/stream-audio-uploads branch"
    echo "Current branch: $CURRENT_BRANCH"
    echo "Run: git checkout -b perf/stream-audio-uploads"
    exit 1
fi

echo "✅ On correct branch: $CURRENT_BRANCH"
echo ""

# Apply patches manually using sed and awk

echo "1. Patching DeepgramTranscriptionProvider.swift..."
# Lines 287-290: Replace Data(contentsOf:) with session.upload

# Create a backup
cp Sources/SpeakApp/DeepgramTranscriptionProvider.swift Sources/SpeakApp/DeepgramTranscriptionProvider.swift.bak

# Use perl for in-place editing (more reliable than sed on macOS)
perl -i -pe '
if ($. == 287) {
    $_ = "        // Stream file upload instead of loading into memory\n";
} elsif ($. == 288) {
    $_ = "        let (data, response) = try await session.upload(for: request, fromFile: url)\n";
} elsif ($. == 289 || $. == 290) {
    $_ = "";
}
' Sources/SpeakApp/DeepgramTranscriptionProvider.swift

echo "✅ Deepgram patched"
echo ""

echo "2. Patching OpenAITranscriptionProvider.swift..."
cp Sources/SpeakApp/OpenAITranscriptionProvider.swift Sources/SpeakApp/OpenAITranscriptionProvider.swift.bak

# This is more complex - need to replace the entire multipart building section
# Lines 27-60 need to be replaced
cat > /tmp/openai_new_section.txt << 'EOF'
    let endpoint = baseURL.appendingPathComponent("audio/transcriptions")
    
    let boundary = "Boundary-\(UUID().uuidString)"
    
    // Build multipart form data by streaming to a temporary file
    let multipartBuilder = try StreamingMultipartFormData(boundary: boundary)
    defer { multipartBuilder.cleanup() }
    
    // Extract model name without provider prefix
    let modelName = model.split(separator: "/").last.map(String.init) ?? model
    
    try multipartBuilder.appendFormField(named: "model", value: modelName)
    try multipartBuilder.appendFormField(named: "response_format", value: "verbose_json")

    if let language {
      // OpenAI expects ISO-639-1 (2-letter code), not full locale (e.g., "en" not "en_GB")
      let languageCode = extractLanguageCode(from: language)
      try multipartBuilder.appendFormField(named: "language", value: languageCode)
    }

    try multipartBuilder.appendFileField(
      named: "file",
      filename: url.lastPathComponent,
      mimeType: "audio/m4a",
      fileURL: url
    )
    try multipartBuilder.finalize()
    
    // Create request with streaming upload
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.upload(for: request, fromFile: multipartBuilder.fileURL)
EOF

# Delete lines 27-60 and insert new content
perl -i -ne 'print unless 27..60' Sources/SpeakApp/OpenAITranscriptionProvider.swift
# Insert new content after line 26
perl -i -pe 'print `cat /tmp/openai_new_section.txt` if $. == 26' Sources/SpeakApp/OpenAITranscriptionProvider.swift

echo "✅ OpenAI patched"
echo ""

echo "3. Patching RevAITranscriptionProvider.swift..."
cp Sources/SpeakApp/RevAITranscriptionProvider.swift Sources/SpeakApp/RevAITranscriptionProvider.swift.bak

# Similar to OpenAI - replace lines 91-131
cat > /tmp/revai_new_section.txt << 'EOF'
    let endpoint = baseURL.appendingPathComponent("jobs")
    
    let boundary = "Boundary-\(UUID().uuidString)"
    
    // Build multipart form data by streaming to a temporary file
    let multipartBuilder = try StreamingMultipartFormData(boundary: boundary)
    defer { multipartBuilder.cleanup() }

    // Add metadata
    var metadata: [String: Any] = [:]
    if let language {
      // Rev.ai accepts language codes like "en", but also accepts locale-specific codes
      // Normalize to just language code for consistency
      let languageCode = extractLanguageCode(from: language)
      metadata["language"] = languageCode
    }
    metadata["skip_diarization"] = false
    metadata["skip_punctuation"] = false

    if let metadataJSON = try? JSONSerialization.data(withJSONObject: metadata) {
      try multipartBuilder.appendFormField(
        named: "metadata",
        value: String(data: metadataJSON, encoding: .utf8) ?? "{}"
      )
    }

    try multipartBuilder.appendFileField(
      named: "media",
      filename: url.lastPathComponent,
      mimeType: "audio/m4a",
      fileURL: url
    )
    try multipartBuilder.finalize()
    
    // Create request with streaming upload
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.upload(for: request, fromFile: multipartBuilder.fileURL)
EOF

# Delete lines 91-131 and insert new content
perl -i -ne 'print unless 91..131' Sources/SpeakApp/RevAITranscriptionProvider.swift
# Insert new content after line 90
perl -i -pe 'print `cat /tmp/revai_new_section.txt` if $. == 90' Sources/SpeakApp/RevAITranscriptionProvider.swift

echo "✅ RevAI patched"
echo ""

# Clean up temp files
rm -f /tmp/openai_new_section.txt /tmp/revai_new_section.txt

echo "========================================="
echo "Patches Applied Successfully!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Run ./verify_streaming_changes.sh to verify"
echo "2. Run make build to test compilation"
echo "3. Run make test to run tests"
echo ""
echo "Backups created:"
echo "- Sources/SpeakApp/DeepgramTranscriptionProvider.swift.bak"
echo "- Sources/SpeakApp/OpenAITranscriptionProvider.swift.bak"
echo "- Sources/SpeakApp/RevAITranscriptionProvider.swift.bak"
