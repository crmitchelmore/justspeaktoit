import Foundation
import XCTest
@testable import SpeakApp

final class RecordingLibraryListingTests: XCTestCase {
  func testListingIncludesDamagedAudioSoCleanupCanRemoveItWithoutDecoding() throws {
    let directory = try temporaryDirectory()
    let recordingID = UUID()
    let recording = directory.appendingPathComponent("Recording-\(recordingID.uuidString).m4a")
    // A failed capture can leave a partial file that AVAudioPlayer cannot open.
    let partialFile = Data([0x00, 0x01, 0x02])
    try partialFile.write(to: recording)

    let recordings = AudioFileManager.listRecordings(in: directory)

    XCTAssertEqual(recordings.count, 1)
    let listed = try XCTUnwrap(recordings.first)
    XCTAssertEqual(listed.id, recordingID)
    XCTAssertEqual(listed.url, recording)
    XCTAssertEqual(listed.fileSize, Int64(partialFile.count))
    XCTAssertEqual(listed.duration, 0, "Management listings must not decode audio for unused durations")
  }

  func testListingFindsNestedAudioButExcludesStagingAndNonAudioFiles() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("Imported", isDirectory: true)
    let staging = directory.appendingPathComponent(".capture-staging", isDirectory: true)
    let fakeAudioDirectory = directory.appendingPathComponent("folder.wav", isDirectory: true)
    for folder in [nested, staging, fakeAudioDirectory] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let recording = nested.appendingPathComponent("meeting.MP3")
    let files = [
      recording, staging.appendingPathComponent("unclaimed.m4a"), directory.appendingPathComponent("notes.txt")
    ]
    for file in files {
      try Data([0x01]).write(to: file)
    }

    let recordings = AudioFileManager.listRecordings(in: directory)

    XCTAssertEqual(recordings.map(\.url), [recording])
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
}
