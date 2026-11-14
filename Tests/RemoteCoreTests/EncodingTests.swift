import XCTest
@testable import RemoteCore

final class EncodingTests: XCTestCase {
    func testDefaultEncodingsStayCompatibleWithMacScreenSharing() {
        let safe = RFBEncodings.advertised()
        XCTAssertEqual(safe, [RFBEncodings.zrle, RFBEncodings.copyRect, RFBEncodings.raw, RFBEncodings.desktopSize, RFBEncodings.lastRect])
        XCTAssertFalse(safe.contains(RFBEncodings.cursor))
        let message = RFBEncodings.setEncodingsMessage()
        XCTAssertEqual(Array(message.prefix(4)), [2, 0, 0, 5])
        let withoutZRLE = RFBEncodings.advertised(enableZRLE: false)
        XCTAssertFalse(withoutZRLE.contains(RFBEncodings.zrle))
        XCTAssertFalse(withoutZRLE.contains(RFBEncodings.cursor))
        let enabled = RFBEncodings.advertised(enableZRLE: true, enableCursor: true)
        XCTAssertEqual(enabled.first, RFBEncodings.zrle)
        XCTAssertLessThan(enabled.firstIndex(of: RFBEncodings.copyRect)!, enabled.firstIndex(of: RFBEncodings.raw)!)
        XCTAssertTrue(enabled.contains(RFBEncodings.cursor))
        XCTAssertEqual(RectangleFailure.message(encoding: 16, x: 0, y: 64, width: 64, height: 64, underlying: "팔레트"), "화면 데이터 오류 · 인코딩 16 · 0,64 64×64: 팔레트")
    }

    func testCopyRectOverlappingScrollUsesTheOriginalPixels() throws {
        var pixels = Data([1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255, 4, 0, 0, 255])
        try FramebufferCopy.copy(pixels: &pixels, width: 4, height: 1, x: 1, y: 0, w: 3, h: 1, fromX: 0, fromY: 0)
        XCTAssertEqual(Array(pixels), [1, 0, 0, 255, 1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255])
    }

    func testCursorMaskUsesTheHighBitAndAnEmptyCursorHides() throws {
        let pixels = Data([9, 8, 7, 1, 1, 2, 3, 4])
        let cursor = try CursorPseudo.decode(width: 2, height: 1, hotspotX: 0, hotspotY: 1, pixels: pixels, mask: Data([0b1000_0000]))
        XCTAssertEqual(Array(cursor.rgba), [9, 8, 7, 255, 1, 2, 3, 0])
        let packet = Data([0, 0, 9, 8, 7, 1, 0b1000_0000])
        let sliced = try CursorPseudo.decode(width: 1, height: 1, hotspotX: 0, hotspotY: 0, pixels: packet.dropFirst(2).prefix(4), mask: packet.suffix(1))
        XCTAssertEqual(Array(sliced.rgba), [9, 8, 7, 255])
        XCTAssertEqual(cursor.hotspotY, 1)
        XCTAssertFalse(cursor.isHidden)
        let hidden = try CursorPseudo.decode(width: 0, height: 0, hotspotX: 0, hotspotY: 0, pixels: Data(), mask: Data())
        XCTAssertTrue(hidden.isHidden)
        XCTAssertEqual(CursorPseudo.payloadLength(width: 2, height: 1), 8 + 1)
        XCTAssertEqual(CursorPseudo.payloadLength(width: 0, height: 16), 0)
        XCTAssertNil(CursorPseudo.payloadLength(width: 800, height: 800))
        // 8×2 cursor: row stride is 1 byte. Mask 0xF0 then 0x0F keeps the left half of row 0 and the right half of row 1.
        var wide = Data()
        for index in 0..<16 { wide.append(contentsOf: [UInt8(index), 0, 0, 0]) }
        let shaped = try CursorPseudo.decode(width: 8, height: 2, hotspotX: 0, hotspotY: 0, pixels: wide, mask: Data([0b1111_0000, 0b0000_1111]))
        XCTAssertEqual(shaped.rgba.count, 16 * 4)
        XCTAssertEqual(shaped.rgba[3], 255)
        XCTAssertEqual(shaped.rgba[4 * 4 + 3], 0)
        XCTAssertEqual(shaped.rgba[(8 + 4) * 4 + 3], 255)
        XCTAssertEqual(shaped.rgba[(8 + 0) * 4 + 3], 0)
    }

    func testZRLETilesSolidRawPaletteAndRuns() throws {
        let solid = Data([1, 0, 0, 255])
        let blue = try ZRLERect.decode(width: 2, height: 1, uncompressed: solid)
        XCTAssertEqual(Array(blue), [0, 0, 255, 255, 0, 0, 255, 255])

        var raw = Data([0])
        raw.append(contentsOf: [255, 0, 0, 0, 255, 0])
        let pair = try ZRLERect.decode(width: 2, height: 1, uncompressed: raw)
        XCTAssertEqual(Array(pair.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual(Array(pair.suffix(4)), [0, 255, 0, 255])

        // Two rows of three 1-bit pixels. Each row is padded to a byte, so the second row must not reuse leftover bits.
        let packed = Data([2, 0, 0, 0, 255, 255, 255, 0b1010_0000, 0b0100_0000])
        let rows = try ZRLERect.decode(width: 3, height: 2, uncompressed: packed)
        XCTAssertEqual(rows.map { $0 }, [
            255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255,
            0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255
        ])

        let rle = Data([128, 255, 0, 0, 2, 0, 255, 0, 0])
        let run = try ZRLERect.decode(width: 4, height: 1, uncompressed: rle)
        XCTAssertEqual(run.filter { $0 == 255 }.count, 3 + 1 + 4) // three red R, one green G, four alphas

        let paletteRun = Data([130, 0, 0, 0, 255, 255, 255, 0, 129, 2])
        let mixed = try ZRLERect.decode(width: 4, height: 1, uncompressed: paletteRun)
        XCTAssertEqual(Array(mixed.prefix(4)), [0, 0, 0, 255])
        XCTAssertEqual(Array(mixed.dropFirst(4)), [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255])
    }

    func testZRLEReusesThePreviousPalette() throws {
        // 65×1 is two tiles: 64 pixels, then 1. The second tile must not carry its own palette.
        var bytes = Data([2, 0, 0, 0, 255, 255, 255])
        bytes.append(contentsOf: repeatElement(0, count: 8))
        bytes.append(contentsOf: [127, 0b1000_0000])
        let image = try ZRLERect.decode(width: 65, height: 1, uncompressed: bytes)
        XCTAssertEqual(image.count, 65 * 4)
        XCTAssertEqual(Array(image.prefix(4)), [0, 0, 0, 255])
        XCTAssertEqual(Array(image.suffix(4)), [255, 255, 255, 255])

        var runs = Data([130, 0, 0, 0, 255, 255, 255, 129, 63])
        runs.append(129)
        runs.append(0)
        var decoder = ZRLEDecoder()
        let first = try decoder.decode(width: 64, height: 1, uncompressed: runs.prefix(9))
        XCTAssertEqual(Array(first.prefix(4)), [255, 255, 255, 255])
        let reused = try decoder.decode(width: 1, height: 1, uncompressed: runs.suffix(2))
        XCTAssertEqual(Array(reused), [0, 0, 0, 255])

        XCTAssertThrowsError(try ZRLERect.decode(width: 1, height: 1, uncompressed: Data([127, 0]))) { error in
            XCTAssertEqual(error.localizedDescription, "재사용할 ZRLE 팔레트가 없습니다.")
        }
    }

    func testCompressedZRLEFixturesRoundTrip() throws {
        let solid = Data([0x78, 0x9c, 0x62, 0xfc, 0xcf, 0xc0, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff])
        let inflated = try InflateStream().inflate(solid)
        XCTAssertEqual(inflated, Data([1, 255, 0, 0]))
        let tile = try ZRLERect.decode(width: 64, height: 64, uncompressed: inflated)
        XCTAssertEqual(tile.count, 64 * 64 * 4)
        XCTAssertEqual(Array(tile.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual(Array(tile.suffix(4)), [255, 0, 0, 255])

        let reuse = Data([0x78, 0x9c, 0x62, 0x62, 0x60, 0x60, 0xf8, 0xff, 0xff, 0x3f, 0x03, 0x14, 0xd4, 0x37, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff])
        let plain = try InflateStream().inflate(reuse)
        let image = try ZRLERect.decode(width: 65, height: 1, uncompressed: plain)
        XCTAssertEqual(Array(image.prefix(4)), [0, 0, 0, 255])
        XCTAssertEqual(Array(image.suffix(4)), [255, 255, 255, 255])
    }

    func testInflateResumesASyncFlushedStream() throws {
        let stream = InflateStream()
        let hello = try stream.inflate(Data(hex: "789cca48cdc9c907000000ffff"))
        let world = try stream.inflate(Data(hex: "2acf2fca49515404000000ffff"))
        XCTAssertEqual(hello, Data("hello".utf8))
        XCTAssertEqual(world, Data("world!!".utf8))

        let blob = InflateStream()
        let compressed = Data(base64Encoded: "eJxjYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVT19DU0tbR1dM3MDQyNjE1M7ewtLK2sbWzd3B0cnZxdXP38PTy9vH18w8IDAoOCQ0Lj4iMio6JjYtPSExKTklNS8/IzMrOyc3LLygsKi4pLSuvqKyqrqmtq29obGpuaW1r7+js6u7p7eufMHHS5ClTp02fMXPW7Dlz581fsHDR4iVLly1fsXLV6jVr163fsHHT5i1bt23fsXPX7j179+0/cPDQ4SNHjx0/cfLU6TNnz52/cPHS5StXr12/cfPW7Tt3791/8PDR4ydPnz1/8fLV6zdv373/8PHT5y9fv33/8fMXw6jXR70+6vVRr496fdTro14f9fqo10e9Pur1Ua+Pen3U66NeH/X6qNdHvT7q9VGvj3p91OujXh/1+qjXR70+6vVRr496fdTrMK8DACxSNXI=")!
        var produced = Data()
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + 17, compressed.count)
            produced.append(try blob.inflate(compressed.subdata(in: offset..<end)))
            offset = end
        }
        XCTAssertEqual(produced, Data((0..<8000).map { UInt8($0 % 251) }))
    }

    func testInflateThroughputOfARepeatedFrame() throws {
        let compressed = Data(hex: "789cedc13101000000c2a0f54f6d0d0fa00000000000000000000000000000000000000078304e200001")
        let clock = ContinuousClock()
        let started = clock.now
        var output = 0
        for _ in 0..<40 {
            let stream = InflateStream()
            output += try stream.inflate(compressed).count
        }
        let elapsed = started.duration(to: clock.now)
        XCTAssertEqual(output, 20000 * 40)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("inflate \(output) bytes in \(String(format: "%.3f", seconds))s")
        XCTAssertLessThan(seconds, 2)
    }

    func testFourKZRLERectAndSixKFramebufferFit() throws {
        XCTAssertTrue(FrameLimits.contains(width: 3840, height: 2160))
        XCTAssertTrue(FrameLimits.contains(width: 6016, height: 3384))
        XCTAssertFalse(FrameLimits.contains(width: 8192, height: 8192))
        XCTAssertEqual(FrameLimits.rawBytes(width: 6016, height: 3384), 6016 * 3384 * 4)
        XCTAssertEqual(FrameLimits.rawBytes(width: 3840, height: 2160), 3840 * 2160 * 4)
        XCTAssertNil(FrameLimits.rawBytes(width: 8192, height: 8192))
        let fourK = try XCTUnwrap(ZRLEBudget.compressedBytes(width: 3840, height: 2160))
        XCTAssertGreaterThan(fourK, 8_000_000)
        XCTAssertGreaterThanOrEqual(fourK, 3840 * 2160 * 4)
        XCTAssertTrue((1...fourK).contains(8_000_001))
        XCTAssertNil(ZRLEBudget.compressedBytes(width: 8192, height: 8192))
        let tile = try XCTUnwrap(ZRLEBudget.compressedBytes(width: 64, height: 64))
        XCTAssertFalse((1...tile).contains(9_000_000))

        // 3840×2160 of solid tiles. 2160 is not a multiple of 64, so the last row is a partial tile.
        let compressed = Data(hex: "78daedc3a10d00000803b0cca2d1fbff4cde40b44933dba8aaaaaaaaaaaaaaaf1f74ece628")
        let stream = InflateStream()
        var decoder = ZRLEDecoder()
        let frame = try stream.decodeZRLE(compressed, width: 3840, height: 2160, decoder: &decoder)
        XCTAssertEqual(frame.count, 3840 * 2160 * 4)
        XCTAssertEqual(Array(frame.prefix(4)), [10, 20, 30, 255])
        let middle = (1080 * 3840 + 1920) * 4
        XCTAssertEqual(Array(frame[middle..<(middle + 4)]), [10, 20, 30, 255])
        XCTAssertEqual(Array(frame.suffix(4)), [10, 20, 30, 255])

        // The same zlib stream must stay aligned across rectangles when each one is pulled per tile.
        let continued = InflateStream()
        let first = try continued.decodeZRLE(Data(hex: "78da62e4e46007000000ffff"), width: 64, height: 64, decoder: &decoder)
        let second = try continued.decodeZRLE(Data(hex: "62046200000000ffff"), width: 64, height: 64, decoder: &decoder)
        XCTAssertEqual(Array(first.prefix(4)), [9, 8, 7, 255])
        XCTAssertEqual(Array(second.suffix(4)), [9, 8, 7, 255])
        XCTAssertEqual(first.count, 64 * 64 * 4)
    }
}

private extension Data {
    init(hex: String) {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
}
