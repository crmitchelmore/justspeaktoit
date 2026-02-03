#!/bin/bash

# Final Testing and Commit Script
# Run this after the streaming optimization changes

set -e

echo "========================================="
echo "Audio Upload Streaming Optimization"
echo "Final Testing and Commit"
echo "========================================="
echo ""

# Step 1: Verify changes
echo "Step 1: Verifying code changes..."
chmod +x verify_streaming_changes.sh
./verify_streaming_changes.sh
if [ $? -ne 0 ]; then
    echo "❌ Verification failed. Please review the changes."
    exit 1
fi
echo ""

# Step 2: Build the project
echo "Step 2: Building the project..."
make build
if [ $? -ne 0 ]; then
    echo "❌ Build failed. Please fix compilation errors."
    exit 1
fi
echo "✅ Build successful"
echo ""

# Step 3: Run tests
echo "Step 3: Running tests..."
make test
if [ $? -ne 0 ]; then
    echo "❌ Tests failed. Please fix failing tests."
    exit 1
fi
echo "✅ Tests passed"
echo ""

# Step 4: Show changes
echo "Step 4: Reviewing changes..."
git --no-pager diff --stat
echo ""
git --no-pager diff Sources/SpeakCore/StreamingMultipartFormData.swift
echo ""

# Step 5: Commit changes
echo "Step 5: Committing changes..."
git add Sources/SpeakCore/StreamingMultipartFormData.swift
git add Sources/SpeakApp/DeepgramTranscriptionProvider.swift
git add Sources/SpeakApp/OpenAITranscriptionProvider.swift
git add Sources/SpeakApp/RevAITranscriptionProvider.swift
git add PERFORMANCE_OPTIMIZATION.md

git commit -m "perf: stream audio file uploads to reduce memory usage

- Replace Data(contentsOf:) with streaming uploads
- Add StreamingMultipartFormData helper for multipart forms
- Use URLSession.upload(for:fromFile:) for direct streaming
- Reduces memory usage from full file size to ~64KB buffer
- Fixes memory spikes with large audio files (>50MB)

Affected providers:
- DeepgramTranscriptionProvider: Direct file streaming
- OpenAITranscriptionProvider: Multipart streaming
- RevAITranscriptionProvider: Multipart streaming"

echo "✅ Changes committed"
echo ""

# Step 6: Push to remote
echo "Step 6: Ready to push..."
echo "Run: git push -u origin perf/stream-audio-uploads"
echo ""
echo "Then create PR with title:"
echo "perf: Stream audio file uploads to reduce memory usage"
echo ""
echo "========================================="
echo "✅ All steps completed successfully!"
echo "========================================="
