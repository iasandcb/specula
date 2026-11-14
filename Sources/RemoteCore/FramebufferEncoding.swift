import Foundation

public enum RFBEncodings {
    public static let raw = 0
    public static let copyRect = 1
    public static let zrle = 16
    /// Pseudo-encodings. They are not pixel encodings and do not replace Raw.
    public static let cursor = 0xFFFF_FF11
    public static let lastRect = 0xFFFF_FF20
    public static let desktopSize = 0xFFFF_FF21

    /// macOS Screen Sharing drops the session when ZRLE or the Cursor pseudo-encoding is mishandled.
    /// Those stay off unless explicitly enabled. CopyRect, Raw, DesktopSize, and LastRect are the safe set.
    public static func advertised(enableZRLE: Bool = false, enableCursor: Bool = false) -> [Int] {
        var list: [Int] = []
        if enableZRLE { list.append(zrle) }
        list.append(copyRect)
        list.append(raw)
        if enableCursor { list.append(cursor) }
        list.append(desktopSize)
        list.append(lastRect)
        return list
    }

    public static func setEncodingsMessage(enableZRLE: Bool = false, enableCursor: Bool = false) -> Data {
        let values = advertised(enableZRLE: enableZRLE, enableCursor: enableCursor)
        var bytes: [UInt8] = [2, 0]
        bytes.append(contentsOf: Wire.u16(values.count))
        for value in values { bytes.append(contentsOf: Wire.u32(UInt32(value))) }
        return Data(bytes)
    }
}

public enum RectangleFailure {
    public static func message(encoding: Int, x: Int, y: Int, width: Int, height: Int, underlying: String) -> String {
        "화면 데이터 오류 · 인코딩 \(encoding) · \(x),\(y) \(width)×\(height): \(underlying)"
    }
}

public struct RemoteCursor: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var hotspotX: Int
    public var hotspotY: Int
    public var rgba: Data
    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.rgba = rgba
    }
    public var isHidden: Bool { width <= 0 || height <= 0 || rgba.isEmpty }
}

public enum CursorPseudo {
    public static func payloadLength(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return 0 }
        guard width <= 512, height <= 512 else { return nil }
        return width * height * 4 + ((width + 7) / 8) * height
    }

    /// Cursor pixels use the client pixel format. The mask's high bit is the leftmost pixel.
    public static func decode(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixels: Data, mask: Data) throws -> RemoteCursor {
        if width == 0 || height == 0 {
            return RemoteCursor(width: 0, height: 0, hotspotX: hotspotX, hotspotY: hotspotY, rgba: Data())
        }
        guard let payload = payloadLength(width: width, height: height), payload > 0 else {
            throw RFBError.invalid("커서 크기가 지원 범위를 넘습니다.")
        }
        // Slices from Data.prefix/suffix do not start at index 0.
        let pixels = Data(pixels)
        let mask = Data(mask)
        let maskStride = (width + 7) / 8
        guard pixels.count == width * height * 4, mask.count == maskStride * height else {
            throw RFBError.invalid("커서 데이터가 잘렸습니다.")
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let bit = mask[y * maskStride + x / 8]
                let opaque = bit & UInt8(0x80 >> (x % 8)) != 0
                let index = (y * width + x) * 4
                rgba[index] = pixels[index]
                rgba[index + 1] = pixels[index + 1]
                rgba[index + 2] = pixels[index + 2]
                rgba[index + 3] = opaque ? 255 : 0
            }
        }
        return RemoteCursor(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY, rgba: Data(rgba))
    }
}

public enum FramebufferCopy {
    /// Copies a rectangle through a temporary buffer so a scroll onto itself stays intact.
    public static func copy(pixels: inout Data, width: Int, height: Int, x: Int, y: Int, w: Int, h: Int, fromX: Int, fromY: Int) throws {
        guard w > 0, h > 0, x >= 0, y >= 0, fromX >= 0, fromY >= 0,
              x + w <= width, y + h <= height, fromX + w <= width, fromY + h <= height else {
            throw RFBError.invalid("화면 복사 범위가 잘못되었습니다.")
        }
        var rows: [Data] = []
        rows.reserveCapacity(h)
        for row in 0..<h {
            let start = ((fromY + row) * width + fromX) * 4
            rows.append(pixels.subdata(in: start..<(start + w * 4)))
        }
        for row in 0..<h {
            let start = ((y + row) * width + x) * 4
            pixels.replaceSubrange(start..<(start + w * 4), with: rows[row])
        }
    }
}

/// ZRLE tiles in the client's 32-bit little-endian format. CPIXEL is the low three bytes, R, G, B.
/// One decoder is kept for the connection so a tile can reuse the previous palette (subencodings 127 and 129).
/// RFC 6143 says ZRLE should not reuse palettes; macOS Screen Sharing still does.
public struct ZRLEDecoder {
    private var palette: [(UInt8, UInt8, UInt8)] = []
    public init() {}

    public mutating func decode(width: Int, height: Int, uncompressed: Data) throws -> Data {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw RFBError.invalid("화면 압축 크기가 잘못되었습니다.")
        }
        var reader = ByteCursor(data: Data(uncompressed))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var originY = 0
        while originY < height {
            let tileH = min(64, height - originY)
            var originX = 0
            while originX < width {
                let tileW = min(64, width - originX)
                try decodeTile(into: &pixels, frameWidth: width, originX: originX, originY: originY, tileW: tileW, tileH: tileH, reader: &reader)
                originX += 64
            }
            originY += 64
        }
        guard reader.isAtEnd else { throw RFBError.invalid("화면 압축 데이터가 남았습니다.") }
        return Data(pixels)
    }

    private mutating func decodeTile(into pixels: inout [UInt8], frameWidth: Int, originX: Int, originY: Int, tileW: Int, tileH: Int, reader: inout ByteCursor) throws {
        let sub = Int(try reader.byte())
        let count = tileW * tileH
        if sub == 0 {
            for index in 0..<count {
                let pixel = try reader.cpixel()
                write(pixel, into: &pixels, frameWidth: frameWidth, x: originX + index % tileW, y: originY + index / tileW)
            }
        } else if sub == 1 {
            let pixel = try reader.cpixel()
            for index in 0..<count {
                write(pixel, into: &pixels, frameWidth: frameWidth, x: originX + index % tileW, y: originY + index / tileW)
            }
        } else if (2...16).contains(sub) {
            palette = try reader.palette(sub)
            try paintPacked(palette, into: &pixels, frameWidth: frameWidth, originX: originX, originY: originY, tileW: tileW, tileH: tileH, reader: &reader)
        } else if sub == 127 {
            guard !palette.isEmpty else { throw RFBError.invalid("재사용할 ZRLE 팔레트가 없습니다.") }
            try paintPacked(palette, into: &pixels, frameWidth: frameWidth, originX: originX, originY: originY, tileW: tileW, tileH: tileH, reader: &reader)
        } else if sub == 128 {
            var written = 0
            while written < count {
                let pixel = try reader.cpixel()
                let run = try reader.run(limit: count - written)
                for offset in 0..<run {
                    let index = written + offset
                    write(pixel, into: &pixels, frameWidth: frameWidth, x: originX + index % tileW, y: originY + index / tileW)
                }
                written += run
            }
        } else if sub == 129 {
            guard !palette.isEmpty else { throw RFBError.invalid("재사용할 ZRLE 팔레트가 없습니다.") }
            try paintPaletteRun(palette, count: count, into: &pixels, frameWidth: frameWidth, originX: originX, originY: originY, tileW: tileW, reader: &reader)
        } else if (130...255).contains(sub) {
            palette = try reader.palette(sub - 128)
            try paintPaletteRun(palette, count: count, into: &pixels, frameWidth: frameWidth, originX: originX, originY: originY, tileW: tileW, reader: &reader)
        } else {
            throw RFBError.invalid("지원하지 않는 ZRLE 타일입니다: \(sub)")
        }
    }

    private func paintPacked(_ palette: [(UInt8, UInt8, UInt8)], into pixels: inout [UInt8], frameWidth: Int, originX: Int, originY: Int, tileW: Int, tileH: Int, reader: inout ByteCursor) throws {
        let bits = palette.count <= 2 ? 1 : (palette.count <= 4 ? 2 : 4)
        guard (2...16).contains(palette.count) else { throw RFBError.invalid("ZRLE 팔레트 크기를 압축할 수 없습니다.") }
        for row in 0..<tileH {
            var bitsLeft = 0
            var value = 0
            for column in 0..<tileW {
                if bitsLeft < bits {
                    value = Int(try reader.byte())
                    bitsLeft = 8
                }
                bitsLeft -= bits
                let index = (value >> bitsLeft) & ((1 << bits) - 1)
                guard palette.indices.contains(index) else { throw RFBError.invalid("화면 압축 팔레트가 잘못되었습니다.") }
                write(palette[index], into: &pixels, frameWidth: frameWidth, x: originX + column, y: originY + row)
            }
        }
    }

    private func paintPaletteRun(_ palette: [(UInt8, UInt8, UInt8)], count: Int, into pixels: inout [UInt8], frameWidth: Int, originX: Int, originY: Int, tileW: Int, reader: inout ByteCursor) throws {
        var written = 0
        while written < count {
            let marker = Int(try reader.byte())
            let index = marker & 127
            guard palette.indices.contains(index) else { throw RFBError.invalid("화면 압축 팔레트가 잘못되었습니다.") }
            let run = marker < 128 ? 1 : try reader.run(limit: count - written)
            for offset in 0..<run {
                let pixelIndex = written + offset
                write(palette[index], into: &pixels, frameWidth: frameWidth, x: originX + pixelIndex % tileW, y: originY + pixelIndex / tileW)
            }
            written += run
        }
    }

    private func write(_ pixel: (UInt8, UInt8, UInt8), into pixels: inout [UInt8], frameWidth: Int, x: Int, y: Int) {
        let index = (y * frameWidth + x) * 4
        pixels[index] = pixel.0
        pixels[index + 1] = pixel.1
        pixels[index + 2] = pixel.2
        pixels[index + 3] = 255
    }
}

public enum ZRLERect {
    public static func decode(width: Int, height: Int, uncompressed: Data) throws -> Data {
        var decoder = ZRLEDecoder()
        return try decoder.decode(width: width, height: height, uncompressed: uncompressed)
    }
}

private struct ByteCursor {
    var data: Data
    var index = 0
    var isAtEnd: Bool { index == data.count }
    mutating func byte() throws -> UInt8 {
        guard index < data.count else { throw RFBError.invalid("화면 압축 데이터가 부족합니다.") }
        defer { index += 1 }
        return data[index]
    }
    mutating func cpixel() throws -> (UInt8, UInt8, UInt8) {
        (try byte(), try byte(), try byte())
    }
    mutating func palette(_ count: Int) throws -> [(UInt8, UInt8, UInt8)] {
        var colors: [(UInt8, UInt8, UInt8)] = []
        for _ in 0..<count { colors.append(try cpixel()) }
        return colors
    }
    /// ZRLE run length is one plus a sequence of bytes, ending at the first byte below 255.
    mutating func run(limit: Int) throws -> Int {
        var length = 1
        while true {
            let extra = Int(try byte())
            guard length <= limit - extra else { throw RFBError.invalid("화면 압축의 반복 길이가 잘못되었습니다.") }
            length += extra
            if extra != 255 { return length }
        }
    }
}
