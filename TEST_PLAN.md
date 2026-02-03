# Test Plan: Audio Upload Streaming Optimization

## Overview
This test plan verifies that streaming audio uploads work correctly and reduce memory usage without introducing regressions.

## Pre-Test Setup
1. Ensure you're on branch `perf/stream-audio-uploads`
2. Build succeeds: `make build`
3. Tests pass: `make test`

## Test 1: Small File Upload (Baseline)
**Purpose:** Verify normal operation with small files

**Steps:**
1. Record a short audio file (<5MB)
2. Upload to each provider:
   - Deepgram
   - OpenAI
   - Rev.ai
3. Verify transcription completes successfully
4. Compare results with previous version

**Expected Results:**
- ✅ Upload succeeds
- ✅ Transcription is accurate
- ✅ No errors in console
- ✅ Same behavior as before optimization

## Test 2: Large File Upload (Memory Test)
**Purpose:** Verify memory optimization with large files

**Steps:**
1. Create or obtain a large audio file (>50MB)
2. Open Activity Monitor (macOS) or similar tool
3. Note baseline memory usage
4. Upload file to each provider
5. Monitor memory during upload
6. Verify transcription completes

**Expected Results:**
- ✅ Upload succeeds
- ✅ Memory usage stays relatively flat
- ✅ No memory spike equivalent to file size
- ✅ Transcription completes successfully
- ✅ Memory returns to baseline after upload

**Metrics to Capture:**
- Baseline memory: _______MB
- Peak memory during upload: _______MB
- Memory increase: _______MB (should be <100MB regardless of file size)

## Test 3: Very Large File Upload (Stress Test)
**Purpose:** Test with extremely large files

**Steps:**
1. Create or obtain a very large audio file (>100MB)
2. Run with Xcode Instruments - Memory Profiler
3. Upload to one provider (e.g., OpenAI)
4. Review memory allocation graph

**Expected Results:**
- ✅ Flat memory usage during upload
- ✅ No large allocations equal to file size
- ✅ Temporary file is cleaned up
- ✅ Upload completes or fails gracefully

## Test 4: Multiple Concurrent Uploads
**Purpose:** Verify streaming works with concurrent uploads

**Steps:**
1. Queue multiple file uploads
2. Start uploading to different providers simultaneously
3. Monitor memory usage
4. Verify all uploads complete

**Expected Results:**
- ✅ All uploads succeed
- ✅ Memory usage scales linearly with small buffer sizes, not file sizes
- ✅ No resource exhaustion
- ✅ Temporary files are cleaned up

## Test 5: Error Handling
**Purpose:** Verify cleanup happens even with errors

**Steps:**
1. Attempt upload with invalid API key
2. Attempt upload with malformed file
3. Cancel an in-progress upload
4. Check temp directory for leftover files

**Expected Results:**
- ✅ Errors are handled gracefully
- ✅ Temporary files are cleaned up
- ✅ No memory leaks
- ✅ App remains stable

## Test 6: Network Interruption
**Purpose:** Test resilience to network issues

**Steps:**
1. Start a large file upload
2. Disconnect network midway
3. Reconnect and retry
4. Verify behavior

**Expected Results:**
- ✅ Error is reported to user
- ✅ Temporary files are cleaned up
- ✅ Retry works correctly
- ✅ No corrupted state

## Test 7: Different File Formats
**Purpose:** Verify streaming works with various audio formats

**Test Files:**
- M4A file
- MP3 file (if supported)
- WAV file (if supported)

**Expected Results:**
- ✅ All supported formats work
- ✅ No file-format-specific issues
- ✅ Streaming applies to all formats

## Test 8: Performance Comparison
**Purpose:** Quantify the improvement

**Method:**
Use the `test_memory_usage.swift` script to compare before/after

**Steps:**
1. Checkout main branch
2. Run memory test with large file
3. Record peak memory usage
4. Checkout perf/stream-audio-uploads
5. Run same memory test
6. Compare results

**Expected Results:**
- Before: Memory spike ≈ file size
- After: Memory spike ≈ 64KB buffer
- Improvement: ~99% reduction for large files

## Regression Testing

### Unit Tests
```bash
make test
```
All existing tests should pass.

### Integration Tests
Test actual API calls if possible:
1. Use real API keys (in test environment)
2. Upload small test file to each provider
3. Verify transcription results match expected output

## Memory Profiling with Xcode Instruments

**Steps:**
1. Open project in Xcode
2. Product > Profile (⌘I)
3. Choose "Allocations" instrument
4. Start recording
5. Upload a large file (>50MB)
6. Stop recording
7. Review allocations graph

**What to Look For:**
- No large Data allocations equal to file size
- InputStream allocations showing streaming
- FileHandle allocations for temp file
- Cleanup of temporary allocations after upload

## Acceptance Criteria Checklist

- [ ] Small files (<5MB) upload successfully
- [ ] Large files (>50MB) upload successfully
- [ ] Memory usage stays flat during upload
- [ ] All three providers work correctly:
  - [ ] Deepgram
  - [ ] OpenAI
  - [ ] Rev.ai
- [ ] Existing tests pass
- [ ] No memory leaks detected
- [ ] Temporary files are cleaned up
- [ ] Error handling works correctly
- [ ] Network interruptions handled gracefully
- [ ] Performance improvement documented

## Known Limitations

1. **Disk I/O**: Slightly increased disk usage due to temporary files
2. **Temp Space**: Requires available temp space equal to file size
3. **Double Read**: Audio file is read twice (once to temp, once for upload)

These trade-offs are acceptable given the memory savings.

## Rollback Plan

If critical issues are found:
```bash
git checkout main
make build
make test
```

Document any issues in GitHub issue tracker before rolling back.

## Sign-Off

- [ ] Developer tested locally
- [ ] Code review completed
- [ ] Tests passed in CI
- [ ] Documentation updated
- [ ] Ready for merge

---

**Notes:**
Use this space to record actual test results, observations, or issues discovered during testing.
