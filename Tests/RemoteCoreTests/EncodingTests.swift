import XCTest
@testable import RemoteCore

final class EncodingTests: XCTestCase {
    func testPreferredEncodingsPutCompressionAheadOfRaw() {
        let message = RFBEncodings.setEncodingsMessage()
        XCTAssertEqual(Array(message.prefix(4)), [2, 0, 0, 6])
        let values = stride(from: 4, to: message.count, by: 4).map { Wire.integer(message[$0..<$0 + 4]) }
        XCTAssertEqual(values, [
            RFBEncodings.zrle, RFBEncodings.copyRect, RFBEncodings.raw,
            RFBEncodings.cursor, RFBEncodings.desktopSize, RFBEncodings.lastRect
        ])
        XCTAssertLessThan(values.firstIndex(of: RFBEncodings.zrle)!, values.firstIndex(of: RFBEncodings.raw)!)
        XCTAssertLessThan(values.firstIndex(of: RFBEncodings.copyRect)!, values.firstIndex(of: RFBEncodings.raw)!)
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
        XCTAssertNil(CursorPseudo.payloadLength(width: 800, height: 800))
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
