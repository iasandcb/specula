import Foundation
import zlib

/// RFC 6143 §7.7.6, for the client's fixed little-endian RGB888 pixel format.
/// Confined to one RFB receive loop. The zlib dictionary survives rectangles and resizes.
final class ZRLEDecoder {
    static let maximumCompressedLength = 64 * 1024 * 1024

    // zlib retains the stream's address internally; it must not move between calls.
    private let stream: UnsafeMutablePointer<z_stream>
    private var ended = false

    init() throws {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deinitialize(count: 1); stream.deallocate()
            throw RFBError.invalid("화면 압축 해제를 초기화하지 못했습니다.")
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deinitialize(count: 1); stream.deallocate()
    }

    func decode(_ compressed: Data, width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 16_777_216 else {
            throw RFBError.invalid("ZRLE 화면 데이터의 크기가 잘못되었습니다.")
        }
        let tiles = ((width + 63) / 64) * ((height + 63) / 64)
        // Worst case: a separate RGB+length run per pixel, plus tile palettes/headers.
        let maximumInflatedLength = width * height * 4 + tiles * 382
        var input = TileReader(data: try inflate(compressed, limit: maximumInflatedLength))
        var output = [UInt32](repeating: 0, count: width * height)

        for y in stride(from: 0, to: height, by: 64) {
            for x in stride(from: 0, to: width, by: 64) {
                let tileWidth = min(64, width - x), tileHeight = min(64, height - y)
                let tile = try input.tile(width: tileWidth, height: tileHeight)
                for row in 0..<tileHeight {
                    let start = (y + row) * width + x
                    output.replaceSubrange(start..<(start + tileWidth),
                                           with: tile[(row * tileWidth)..<((row + 1) * tileWidth)])
                }
            }
        }
        guard input.offset == input.data.count else {
            throw RFBError.invalid("ZRLE 화면 데이터에 불필요한 내용이 있습니다.")
        }
        return output.withUnsafeBytes { Data($0) }
    }

    private func inflate(_ compressed: Data, limit: Int) throws -> Data {
        guard !ended, !compressed.isEmpty, compressed.count <= Self.maximumCompressedLength else {
            throw RFBError.invalid("ZRLE 압축 데이터의 크기 또는 상태가 잘못되었습니다.")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        try compressed.withUnsafeBytes { bytes in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.pointee.avail_in = uInt(compressed.count)
            defer {
                stream.pointee.next_in = nil; stream.pointee.avail_in = 0
                stream.pointee.next_out = nil; stream.pointee.avail_out = 0
            }
            while true {
                let remaining = stream.pointee.avail_in
                let capacity = buffer.count
                let status = buffer.withUnsafeMutableBytes { out -> Int32 in
                    stream.pointee.next_out = out.bindMemory(to: UInt8.self).baseAddress
                    stream.pointee.avail_out = uInt(capacity)
                    return zlib.inflate(stream, Z_SYNC_FLUSH)
                }
                let produced = capacity - Int(stream.pointee.avail_out)
                guard status == Z_OK || status == Z_BUF_ERROR || status == Z_STREAM_END,
                      result.count + produced <= limit else {
                    throw RFBError.invalid("ZRLE 압축 데이터가 손상되었거나 허용 크기를 초과했습니다.")
                }
                result.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.pointee.avail_in == 0 else {
                        throw RFBError.invalid("ZRLE 압축 스트림 뒤에 잘못된 데이터가 있습니다.")
                    }
                    ended = true
                    break
                }
                if stream.pointee.avail_in == 0 && produced < capacity { break }
                guard produced > 0 || stream.pointee.avail_in < remaining else {
                    throw RFBError.invalid("ZRLE 압축 데이터를 해제하지 못했습니다.")
                }
            }
        }
        return result
    }

    private struct TileReader {
        let data: Data
        var offset = 0

        mutating func byte() throws -> UInt8 {
            guard offset < data.count else { throw RFBError.invalid("ZRLE 화면 데이터가 잘렸습니다.") }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func pixel() throws -> UInt32 {
            // CPIXEL omits the unused fourth byte. Emit opaque RGBA on any endianness.
            let r = try byte(), g = try byte(), b = try byte()
            return (UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xff000000).littleEndian
        }

        mutating func runLength(remaining: Int) throws -> Int {
            var length = 1
            while true {
                let part = try byte()
                length += Int(part)
                guard length <= remaining else { throw RFBError.invalid("ZRLE 반복 길이가 타일 범위를 초과했습니다.") }
                if part != 255 { return length }
            }
        }

        mutating func tile(width: Int, height: Int) throws -> [UInt32] {
            let mode = try byte(), count = width * height
            switch mode {
            case 0:
                return try (0..<count).map { _ in try pixel() }
            case 1:
                return [UInt32](repeating: try pixel(), count: count)
            case 2...16:
                let palette = try (0..<Int(mode)).map { _ in try pixel() }
                let bits = mode == 2 ? 1 : (mode <= 4 ? 2 : 4)
                let mask = (1 << bits) - 1
                var pixels = [UInt32]()
                pixels.reserveCapacity(count)
                for _ in 0..<height {
                    var packed = 0
                    for x in 0..<width {
                        if x % (8 / bits) == 0 { packed = Int(try byte()) }
                        let index = (packed >> (8 - bits - (x % (8 / bits)) * bits)) & mask
                        guard index < palette.count else { throw RFBError.invalid("ZRLE 색상 번호가 잘못되었습니다.") }
                        pixels.append(palette[index])
                    }
                }
                return pixels
            case 128, 130...255:
                let palette = try (0..<Int(mode & 127)).map { _ in try pixel() }
                var pixels = [UInt32]()
                pixels.reserveCapacity(count)
                while pixels.count < count {
                    let color: UInt32
                    let length: Int
                    if mode == 128 {
                        color = try pixel()
                        length = try runLength(remaining: count - pixels.count)
                    } else {
                        let index = try byte()
                        guard Int(index & 127) < palette.count else { throw RFBError.invalid("ZRLE 색상 번호가 잘못되었습니다.") }
                        color = palette[Int(index & 127)]
                        length = index & 128 == 0 ? 1 : try runLength(remaining: count - pixels.count)
                    }
                    pixels.append(contentsOf: repeatElement(color, count: length))
                }
                return pixels
            default:
                // 17...126 are unused; 127/129 palette reuse is forbidden in ZRLE.
                throw RFBError.invalid("지원하지 않는 ZRLE 타일 형식입니다: \(mode)")
            }
        }
    }
}
