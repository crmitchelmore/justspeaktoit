import Foundation
import XCTest

@testable import SpeakApp

/// The installer refuses a wrong-architecture executable by reading Mach-O
/// headers directly (issue #775).
final class MachOArchitecturesTests: XCTestCase {
  func testThinLittleEndianHeader_reportsItsSlice() throws {
    XCTAssertEqual(try MachOArchitectures.architectures(in: MachOFixtures.thin(architecture: "arm64")), ["arm64"])
    XCTAssertEqual(try MachOArchitectures.architectures(in: MachOFixtures.thin(architecture: "x86_64")), ["x86_64"])
  }

  func testFatHeader_reportsEverySlice() throws {
    XCTAssertEqual(
      try MachOArchitectures.architectures(in: MachOFixtures.fat(["x86_64", "arm64"])),
      ["arm64", "x86_64"]
    )
  }

  func testByteSwappedFatHeader_reportsEverySlice() throws {
    // FAT_CIGAM: the magic reads byte-swapped, so the count and every
    // cputype are little-endian too. Reading them big-endian turns a
    // one-slice header into a count of 16,777,216 and rejects the file.
    XCTAssertEqual(try MachOArchitectures.architectures(in: MachOFixtures.fatSwapped(["arm64"])), ["arm64"])
    XCTAssertEqual(
      try MachOArchitectures.architectures(in: MachOFixtures.fatSwapped(["x86_64", "arm64"])),
      ["arm64", "x86_64"]
    )
  }

  func testNonMachOData_isRejected() {
    XCTAssertThrowsError(try MachOArchitectures.architectures(in: Data("#!/bin/sh\necho hi\n".utf8)))
    XCTAssertThrowsError(try MachOArchitectures.architectures(in: Data([0xCA, 0xFE])))
  }

  func testSystemBinary_isReadable() throws {
    let slices = try MachOArchitectures.architectures(of: URL(fileURLWithPath: "/bin/ls"))
    XCTAssertFalse(slices.isEmpty)
    XCTAssertTrue(slices.isSubset(of: ["arm64", "x86_64"]))
  }
}

/// Synthetic Mach-O headers shared with the installer tests.
enum MachOFixtures {
  private static let cpuTypes: [String: UInt32] = ["arm64": 0x0100_000C, "x86_64": 0x0100_0007]

  /// A 64-bit little-endian thin header (magic 0xFEEDFACF stored byte-swapped) with padding.
  static func thin(architecture: String) -> Data {
    var data = Data([0xCF, 0xFA, 0xED, 0xFE])
    data.append(littleEndian(cpuTypes[architecture] ?? 0))
    data.append(Data(repeating: 0, count: 24))
    return data
  }

  /// A fat header (always big-endian) with one entry per slice.
  static func fat(_ architectures: [String]) -> Data {
    var data = Data([0xCA, 0xFE, 0xBA, 0xBE])
    data.append(bigEndian(UInt32(architectures.count)))
    for architecture in architectures {
      data.append(bigEndian(cpuTypes[architecture] ?? 0))
      data.append(Data(repeating: 0, count: 16))
    }
    return data
  }

  /// A byte-swapped fat header (FAT_CIGAM): every field little-endian.
  static func fatSwapped(_ architectures: [String]) -> Data {
    var data = Data([0xBE, 0xBA, 0xFE, 0xCA])
    data.append(littleEndian(UInt32(architectures.count)))
    for architecture in architectures {
      data.append(littleEndian(cpuTypes[architecture] ?? 0))
      data.append(Data(repeating: 0, count: 16))
    }
    return data
  }

  private static func bigEndian(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
  }

  private static func littleEndian(_ value: UInt32) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
  }
}
