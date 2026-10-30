import XCTest
import zlib
@testable import RemoteCore

final class ZRLETests: XCTestCase {
    private let red: [UInt8] = [255, 0, 0]
    private let green: [UInt8] = [0, 255, 0]
    private let blue: [UInt8] = [0, 0, 255]

    func testRawCompactPixelsBecomeOpaqueRGBA() throws {
        let actual = try decode([0] + red + green + blue, width: 3, height: 1)
        XCTAssertEqual(actual, rgba([red, green, blue]))
    }

    func testSolidTilesAndPartialEdgesInBothDirections() throws {
        let white: [UInt8] = [255, 255, 255]
        let actual = try decode([1] + red + [1] + green + [1] + blue + [1] + white, width: 65, height: 65)
        var expected = [[UInt8]]()
        for y in 0..<65 {
            for x in 0..<65 { expected.append(y < 64 ? (x < 64 ? red : green) : (x < 64 ? blue : white)) }
        }
        XCTAssertEqual(actual, rgba(expected))
    }

    func testPackedPalettesUseMostSignificantBitsAndPadEveryRow() throws {
        XCTAssertEqual(try decode([2] + red + green + [0xa0, 0x40], width: 3, height: 2),
                       rgba([green, red, green, red, green, red]))
        XCTAssertEqual(try decode([3] + red + green + blue + [0x18, 0x90], width: 3, height: 2),
                       rgba([red, green, blue, blue, green, red]))
        let palette = [red, green, blue, [255, 255, 255], [0, 0, 0]]
        XCTAssertEqual(try decode([5] + palette.flatMap { $0 } + [0x01, 0x20, 0x43, 0x00], width: 3, height: 2),
                       rgba([palette[0], palette[1], palette[2], palette[4], palette[3], palette[0]]))
    }

    func testPlainRLECrossesRowsAndUsesExtendedLengths() throws {
        XCTAssertEqual(try decode([128] + red + [255, 64], width: 64, height: 5),
                       rgba(Array(repeating: red, count: 320)))
    }

    func testPaletteRLESupportsRunsAndSingletons() throws {
        XCTAssertEqual(try decode([130] + red + green + [128, 255, 63, 1], width: 64, height: 5),
                       rgba(Array(repeating: red, count: 319) + [green]))
        let palette = (0..<127).map { [UInt8($0), UInt8(0), UInt8(0)] }
        XCTAssertEqual(try decode([255] + palette.flatMap { $0 } + [126, 0], width: 2, height: 1),
                       rgba([palette[126], palette[0]]))
    }

    func testZlibDictionarySurvivesRectanglesAndDimensionChanges() throws {
        // Independent Python zlib.compressobj() reference: two identical raw tiles,
        // each flushed with Z_SYNC_FLUSH. The second chunk has no zlib header.
        let chunks = ["789c62f8cfc0c000c64000000000ffff", "6240e600000000ffff"].map(hex)
        let decoder = try ZRLEDecoder()
        let expected = rgba([red, green, blue, [255, 255, 255]])
        XCTAssertEqual(try decoder.decode(chunks[0], width: 4, height: 1), expected)
        XCTAssertEqual(try decoder.decode(chunks[1], width: 2, height: 2), expected)
        XCTAssertThrowsError(try ZRLEDecoder().decode(chunks[1], width: 2, height: 2))
        // A new connection starts with a fresh dictionary.
        XCTAssertEqual(try ZRLEDecoder().decode(chunks[0], width: 4, height: 1), expected)
    }

    func testInflatedDataLargerThanOneOutputBuffer() throws {
        let color: [UInt8] = [12, 34, 56]
        let tile: [UInt8] = [0] + Array(repeating: color, count: 4096).flatMap { $0 }
        XCTAssertEqual(try decode(Array(repeating: tile, count: 8).flatMap { $0 }, width: 256, height: 128),
                       rgba(Array(repeating: [12, 34, 56], count: 256 * 128)))
    }

    func testUnusedAndForbiddenSubencodingsAreRejected() throws {
        for mode: UInt8 in [17, 126, 127, 129] {
            XCTAssertThrowsError(try decode([mode], width: 1, height: 1), "mode \(mode)")
        }
    }

    func testPaletteIndexesAndRunOverflowsAreRejected() throws {
        XCTAssertThrowsError(try decode([3] + red + green + blue + [0xc0], width: 1, height: 1))
        XCTAssertThrowsError(try decode([130] + red + green + [2], width: 1, height: 1))
        XCTAssertThrowsError(try decode([128] + red + [1], width: 1, height: 1))
        XCTAssertThrowsError(try decode([130] + red + green + [128, 1], width: 1, height: 1))
    }

    func testTruncatedTilesAndTrailingDataAreRejected() throws {
        let invalid: [[UInt8]] = [[], [0], [0, 1, 2], [1, 1], [2] + red,
                                  [2] + red + green, [128] + red, [130] + red + green + [128],
                                  [1] + red + [0]]
        for bytes in invalid { XCTAssertThrowsError(try decode(bytes, width: 1, height: 1)) }
    }

    func testInvalidCompressedDataAndExpansionLimitAreRejected() throws {
        XCTAssertThrowsError(try ZRLEDecoder().decode(Data(), width: 1, height: 1))
        XCTAssertThrowsError(try ZRLEDecoder().decode(Data([1, 2, 3, 4]), width: 1, height: 1))
        let valid = try ZRLETestCompressor().compress([1] + red)
        XCTAssertThrowsError(try ZRLEDecoder().decode(Data(valid.prefix(4)), width: 1, height: 1))
        XCTAssertThrowsError(try decode([UInt8](repeating: 0, count: 100_000), width: 1, height: 1))
    }

    func testInvalidDimensionsAreRejectedBeforeAllocation() throws {
        let data = try ZRLETestCompressor().compress([1] + red)
        for (width, height) in [(0, 1), (-1, 1), (8193, 1), (8192, 8192)] {
            XCTAssertThrowsError(try ZRLEDecoder().decode(data, width: width, height: height))
        }
    }

    private func decode(_ bytes: [UInt8], width: Int, height: Int) throws -> Data {
        try ZRLEDecoder().decode(ZRLETestCompressor().compress(bytes), width: width, height: height)
    }

    private func rgba(_ pixels: [[UInt8]]) -> Data { Data(pixels.flatMap { $0 + [255] }) }

    private func hex(_ string: String) -> Data {
        let bytes = Array(string.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(decoding: bytes[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
        })
    }
}

/// A mock server's persistent compressor, deliberately separate from tile encoding.
final class ZRLETestCompressor {
    private let stream: UnsafeMutablePointer<z_stream>

    init() throws {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        guard deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deinitialize(count: 1); stream.deallocate()
            throw RFBError.invalid("Test compressor initialization failed")
        }
    }

    deinit {
        deflateEnd(stream)
        stream.deinitialize(count: 1); stream.deallocate()
    }

    func compress(_ input: [UInt8]) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        try input.withUnsafeBytes { bytes in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.pointee.avail_in = uInt(input.count)
            defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
            repeat {
                let capacity = buffer.count
                let status = buffer.withUnsafeMutableBytes { out -> Int32 in
                    stream.pointee.next_out = out.bindMemory(to: UInt8.self).baseAddress
                    stream.pointee.avail_out = uInt(capacity)
                    return deflate(stream, Z_SYNC_FLUSH)
                }
                guard status == Z_OK else { throw RFBError.invalid("Test compression failed") }
                result.append(contentsOf: buffer.prefix(capacity - Int(stream.pointee.avail_out)))
            } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0
        }
        return result
    }
}
