import Foundation

/// Binary reader/writer for emulator snapshots.
///
/// Deliberately plain: fixed-width little-endian fields, no compression, no
/// reflection. A snapshot is a development tool, so being able to read it with
/// a hex editor is worth more than being small.
struct StateWriter {
    private(set) var data = Data()

    mutating func write(_ value: UInt8) { data.append(value) }

    mutating func write(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: Int) { write(UInt32(bitPattern: Int32(truncatingIfNeeded: value))) }
    mutating func write(_ value: Bool) { write(UInt8(value ? 1 : 0)) }
    mutating func write(_ value: Int16) { write(UInt16(bitPattern: value)) }
    mutating func write(_ value: Int32) { write(UInt32(bitPattern: value)) }

    mutating func write(_ bytes: [UInt8]) {
        write(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func write(_ values: [UInt32]) {
        write(UInt32(values.count))
        for value in values { write(value) }
    }

    mutating func write(_ values: [Int]) {
        write(UInt32(values.count))
        for value in values { write(value) }
    }

    mutating func write(_ values: [Int16]) {
        write(UInt32(values.count))
        for value in values { write(value) }
    }

    mutating func write(_ values: [Int32]) {
        write(UInt32(values.count))
        for value in values { write(value) }
    }

    mutating func write(_ values: [UInt16]) {
        write(UInt32(values.count))
        for value in values { write(value) }
    }

    mutating func write(_ values: [Bool]) {
        write(UInt32(values.count))
        for value in values { write(value) }
    }

    /// Marks a section boundary, so a mismatch is caught at the right place
    /// rather than silently decoding the next component's bytes.
    mutating func mark(_ tag: String) {
        let bytes = Array(tag.utf8.prefix(4))
        for i in 0..<4 { write(i < bytes.count ? bytes[i] : 0x20) }
    }
}

struct StateReader {
    private let data: [UInt8]
    private var offset = 0

    init(_ data: Data) { self.data = [UInt8](data) }

    var isExhausted: Bool { offset >= data.count }

    enum Failure: LocalizedError {
        case truncated
        case badSection(expected: String, found: String)
        case unsupportedVersion(Int)
        case wrongCartridge

        var errorDescription: String? {
            switch self {
            case .truncated: return "The snapshot is incomplete."
            case .badSection(let expected, let found):
                return "Snapshot section mismatch: expected \(expected), found \(found)."
            case .unsupportedVersion(let v):
                return "Snapshot format version \(v) is not supported by this build."
            case .wrongCartridge:
                return "That snapshot was taken from a different cartridge."
            }
        }
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw Failure.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let low = try readUInt8(), high = try readUInt8()
        return UInt16(low) | (UInt16(high) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let a = try readUInt16(), b = try readUInt16()
        return UInt32(a) | (UInt32(b) << 16)
    }

    mutating func readInt() throws -> Int { Int(Int32(bitPattern: try readUInt32())) }
    mutating func readBool() throws -> Bool { try readUInt8() != 0 }
    mutating func readInt16() throws -> Int16 { Int16(bitPattern: try readUInt16()) }
    mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }

    mutating func readBytes() throws -> [UInt8] {
        let count = Int(try readUInt32())
        guard offset + count <= data.count else { throw Failure.truncated }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func readUInt32Array() throws -> [UInt32] {
        let count = Int(try readUInt32())
        return try (0..<count).map { _ in try readUInt32() }
    }

    mutating func readIntArray() throws -> [Int] {
        let count = Int(try readUInt32())
        return try (0..<count).map { _ in try readInt() }
    }

    mutating func readInt16Array() throws -> [Int16] {
        let count = Int(try readUInt32())
        return try (0..<count).map { _ in try readInt16() }
    }

    mutating func readInt32Array() throws -> [Int32] {
        let count = Int(try readUInt32())
        return try (0..<count).map { _ in try readInt32() }
    }

    mutating func readUInt16Array() throws -> [UInt16] {
        let count = Int(try readUInt32())
        return try (0..<count).map { _ in try readUInt16() }
    }

    mutating func readBoolArray() throws -> [Bool] {
        let count = Int(try readUInt32())
        return try (0..<count).map { _ in try readBool() }
    }

    mutating func expect(_ tag: String) throws {
        var found = ""
        for _ in 0..<4 { found.append(Character(UnicodeScalar(try readUInt8()))) }
        let want = tag.padding(toLength: 4, withPad: " ", startingAt: 0)
        guard found == want else {
            throw Failure.badSection(expected: want, found: found)
        }
    }
}

/// Snapshot format.
enum SaveStateFormat {
    static let magic: UInt32 = 0x444D_5354   // "DMST"
    /// Bumped whenever the layout changes; older snapshots are refused rather
    /// than decoded into the wrong fields.
    static let version = 1
}
