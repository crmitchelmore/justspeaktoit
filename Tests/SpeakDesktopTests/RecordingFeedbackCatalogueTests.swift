import Foundation
import SpeakCore
import SpeakFeedbackResources
import XCTest

final class RecordingFeedbackCatalogueTests: XCTestCase {
    func testProfiles_PreserveCanonicalIDsTitlesAndAssetNames() {
        XCTAssertEqual(
            RecordingFeedbackProfile.allCases.map(\.rawValue), ["classic", "bubbly", "futuristic", "soft"]
        )
        XCTAssertEqual(
            RecordingFeedbackProfile.allCases.map(\.displayName), ["Classic", "Bubbly", "Futuristic", "Soft"]
        )
        XCTAssertEqual(Set(RecordingFeedbackDefaults.filenames), Set([
            "recording_start.m4a", "recording_stop.m4a",
            "recording_start_bubbly.m4a", "recording_stop_bubbly.m4a",
            "recording_start_futuristic.m4a", "recording_stop_futuristic.m4a",
            "recording_start_soft.m4a", "recording_stop_soft.m4a"
        ]))
        XCTAssertEqual(RecordingFeedbackDefaults.filenames.count, 8)
    }

    func testDefaultsAndGain_MatchTheExistingMacCurve() {
        XCTAssertTrue(RecordingFeedbackDefaults.enabled)
        XCTAssertEqual(RecordingFeedbackDefaults.profile, .classic)
        XCTAssertEqual(RecordingFeedbackDefaults.volume, 0.7)
        XCTAssertEqual(RecordingFeedbackDefaults.gain(for: 0.7), 0.49, accuracy: 0.000_001)
        XCTAssertEqual(RecordingFeedbackDefaults.gain(for: -1), 0)
        XCTAssertEqual(RecordingFeedbackDefaults.gain(for: 0), 0)
        XCTAssertEqual(RecordingFeedbackDefaults.gain(for: 0.5), 0.25)
        XCTAssertEqual(RecordingFeedbackDefaults.gain(for: 1), 1)
        XCTAssertEqual(RecordingFeedbackDefaults.gain(for: 2), 1)
    }

    func testResources_AllEightCanonicalM4AsExistInTheirOwnBundle() throws {
        var urls: Set<URL> = []
        for profile in RecordingFeedbackProfile.allCases {
            for sound in RecordingFeedbackSound.allCases {
                let url = try RecordingFeedbackResources.url(for: sound, profile: profile)
                XCTAssertEqual(url.lastPathComponent, profile.filename(for: sound))
                XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Sounds")
                XCTAssertTrue(url.path.contains("SpeakFeedbackResources"))
                let prefix = try FileHandle(forReadingFrom: url)
                defer { try? prefix.close() }
                let bytes = try XCTUnwrap(prefix.read(upToCount: 12))
                XCTAssertEqual(bytes.count, 12)
                guard bytes.count == 12 else { continue }
                XCTAssertEqual(String(bytes: bytes[4..<8], encoding: .utf8), "ftyp")
                XCTAssertTrue(urls.insert(url).inserted)
            }
        }
        XCTAssertEqual(urls.count, 8)
        let directory = try XCTUnwrap(urls.first).deletingLastPathComponent()
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            Set(RecordingFeedbackDefaults.filenames)
        )
    }
}
