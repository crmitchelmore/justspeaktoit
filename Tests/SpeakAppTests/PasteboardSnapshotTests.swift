import AppKit
import XCTest

@testable import SpeakApp

/// Pasteboard save/restore must be byte-for-byte across every item and type,
/// not just the plain string (issue #673).
final class PasteboardSnapshotTests: XCTestCase {
  private let customType = NSPasteboard.PasteboardType("com.speakapp.tests.blob")

  private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.speakapp.pasteboard-snapshot-tests.\(UUID().uuidString)"))
  }

  func testRestore_bringsBackEveryItemAndTypeByteForByte() throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.clearContents() }

    let rich = NSPasteboardItem()
    rich.setString("plain form", forType: .string)
    rich.setData(Data("{\\rtf1 rich form}".utf8), forType: .rtf)
    rich.setData(Data([0x00, 0xFF, 0x10, 0x20]), forType: customType)
    let second = NSPasteboardItem()
    second.setData(Data(repeating: 0xAB, count: 64), forType: .tiff)
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([rich, second]))

    let snapshot = PasteboardSnapshot(reading: pasteboard)
    XCTAssertEqual(snapshot.items.count, 2)

    pasteboard.clearContents()
    pasteboard.setString("transient paste", forType: .string)
    snapshot.restore(to: pasteboard)

    let items = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].string(forType: .string), "plain form")
    XCTAssertEqual(items[0].data(forType: .rtf), Data("{\\rtf1 rich form}".utf8))
    XCTAssertEqual(items[0].data(forType: customType), Data([0x00, 0xFF, 0x10, 0x20]))
    XCTAssertEqual(items[1].data(forType: .tiff), Data(repeating: 0xAB, count: 64))
    XCTAssertNil(items[1].string(forType: .string), "An item must not gain types it never had")
  }

  func testSnapshotOfEmptyPasteboard_restoresToEmpty() {
    let pasteboard = makePasteboard()
    defer { pasteboard.clearContents() }
    pasteboard.clearContents()

    let snapshot = PasteboardSnapshot(reading: pasteboard)
    XCTAssertTrue(snapshot.isEmpty)

    pasteboard.setString("transient paste", forType: .string)
    snapshot.restore(to: pasteboard)

    XCTAssertNil(pasteboard.string(forType: .string))
    XCTAssertEqual(pasteboard.pasteboardItems?.count ?? 0, 0)
  }

  func testSnapshot_isValueComparable() {
    let contents: [[NSPasteboard.PasteboardType: Data]] = [[.string: Data("x".utf8)]]
    XCTAssertEqual(PasteboardSnapshot(items: contents), PasteboardSnapshot(items: contents))
    XCTAssertNotEqual(PasteboardSnapshot(items: contents), PasteboardSnapshot(items: []))
  }
}
