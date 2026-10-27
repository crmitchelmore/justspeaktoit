import Foundation

/// Locates only the two identity fields in already syntax-validated UTF-8 JSON.
/// Numeric tokens never pass through Foundation's floating-point integer fallback.
struct MCPAwaitRawIdentity {
    private enum Failure: Error { case invalid }
    private static let maximumDepth = 128
    private let bytes: [UInt8]
    private var offset = 0

    init(validatedData: Data) { self.bytes = Array(validatedData) }

    mutating func identity(cancellation: Bool) -> String? {
        do {
            let root = try self.members()
            self.skipWhitespace()
            guard self.offset == self.bytes.count else { return nil }
            let identifier: Range<Int>?
            if cancellation {
                guard let range = root["params"] else { return nil }
                self.offset = range.lowerBound
                let parameters = try self.members()
                guard self.offset == range.upperBound else { return nil }
                identifier = parameters["requestId"]
            } else {
                identifier = root["id"]
            }
            guard let identifier else { return nil }
            return try self.decodeIdentifier(identifier)
        } catch { return nil }
    }

    /// Duplicate decoded keys fail closed, including escaped aliases for the same key.
    private mutating func members() throws -> [String: Range<Int>] {
        self.skipWhitespace()
        try self.require(0x7B)
        self.skipWhitespace()
        var result: [String: Range<Int>] = [:]
        if self.consume(0x7D) { return result }
        while true {
            let keyRange = try self.stringToken()
            let key = try self.decodeString(keyRange)
            guard result[key] == nil else { throw Failure.invalid }
            self.skipWhitespace()
            try self.require(0x3A)
            self.skipWhitespace()
            result[key] = try self.valueToken()
            self.skipWhitespace()
            if self.consume(0x7D) { return result }
            try self.require(0x2C)
            self.skipWhitespace()
        }
    }

    private func decodeIdentifier(_ range: Range<Int>) throws -> String? {
        let token = self.bytes[range]
        guard let first = token.first else { return nil }
        if first == 0x22 { return "s:" + (try self.decodeString(range)) }
        let digits = first == 0x2D ? token.dropFirst() : token[...]
        guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }),
              digits.count == 1 || digits.first != 0x30 else { return nil }
        guard let literal = String(bytes: token, encoding: .utf8) else { return nil }
        if let signed = Int64(literal) { return "n:" + String(signed) }
        if let unsigned = UInt64(literal) { return "n:" + String(unsigned) }
        return nil
    }

    private func decodeString(_ range: Range<Int>) throws -> String {
        try JSONDecoder().decode(String.self, from: Data(self.bytes[range]))
    }

    private mutating func stringToken() throws -> Range<Int> {
        let start = self.offset
        try self.require(0x22)
        while self.offset < self.bytes.count {
            switch self.bytes[self.offset] {
            case 0x22:
                self.offset += 1
                return start..<self.offset
            case 0x5C:
                guard self.offset + 1 < self.bytes.count else { throw Failure.invalid }
                self.offset += 2
            default: self.offset += 1
            }
        }
        throw Failure.invalid
    }

    /// Iterative container skipping with a fixed stack cap; syntax was validated by JSONDecoder.
    private mutating func valueToken() throws -> Range<Int> {
        let start = self.offset
        guard self.offset < self.bytes.count else { throw Failure.invalid }
        let first = self.bytes[self.offset]
        if first == 0x22 { return try self.stringToken() }
        if first == 0x7B || first == 0x5B {
            try self.skipContainer(opening: first)
        } else {
            while self.offset < self.bytes.count,
                  ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x7D, 0x5D].contains(self.bytes[self.offset]) {
                self.offset += 1
            }
        }
        guard self.offset > start else { throw Failure.invalid }
        return start..<self.offset
    }

    private mutating func skipContainer(opening: UInt8) throws {
        var closing: [UInt8] = [Self.closingByte(for: opening)]
        self.offset += 1
        while let expected = closing.last {
            guard self.offset < self.bytes.count else { throw Failure.invalid }
            switch self.bytes[self.offset] {
            case 0x22: _ = try self.stringToken()
            case 0x7B, 0x5B:
                guard closing.count < Self.maximumDepth else { throw Failure.invalid }
                closing.append(Self.closingByte(for: self.bytes[self.offset]))
                self.offset += 1
            case 0x7D, 0x5D:
                guard self.bytes[self.offset] == expected else { throw Failure.invalid }
                closing.removeLast()
                self.offset += 1
            default: self.offset += 1
            }
        }
    }

    private static func closingByte(for opening: UInt8) -> UInt8 { opening == 0x7B ? 0x7D : 0x5D }

    private mutating func skipWhitespace() {
        while self.offset < self.bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(self.bytes[self.offset]) {
            self.offset += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard self.offset < self.bytes.count, self.bytes[self.offset] == byte else { return false }
        self.offset += 1
        return true
    }

    private mutating func require(_ byte: UInt8) throws {
        guard self.consume(byte) else { throw Failure.invalid }
    }
}
