import Foundation
#if canImport(CInflate)
import CInflate
#endif

/// One zlib stream for a connection. ZRLE feeds it one sync-flushed chunk per rectangle.
public final class InflateStream {
    private var session: OpaquePointer?
    public init() { session = inflate_session_create() }
    deinit { if let session { inflate_session_destroy(session) } }

    public func inflate(_ data: Data) throws -> Data {
        guard let session else { throw RFBError.invalid("화면 압축을 풀지 못했습니다.") }
        let chunk: inflate_chunk
        if data.isEmpty {
            chunk = inflate_session_process(session, nil, 0)
        } else {
            chunk = data.withUnsafeBytes { raw in
                inflate_session_process(session, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        }
        defer { inflate_session_free(chunk.bytes) }
        guard chunk.status == 0 else { throw RFBError.invalid("화면 압축을 풀지 못했습니다.") }
        guard let bytes = chunk.bytes, chunk.count > 0 else { return Data() }
        return Data(bytes: bytes, count: chunk.count)
    }

    /// Inflates one ZRLE rectangle in small pulls so a 4K frame does not keep the whole plain buffer.
    func decodeZRLE(_ compressed: Data, width: Int, height: Int, decoder: inout ZRLEDecoder) throws -> Data {
        guard FrameLimits.contains(width: width, height: height) else {
            throw RFBError.invalid("화면 압축 크기가 잘못되었습니다.")
        }
        guard let session else { throw RFBError.invalid("화면 압축을 풀지 못했습니다.") }
        let plainLimit = ZRLEBudget.plainBytes(width: width, height: height)
        return try compressed.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: UInt8.self).baseAddress
            var source = InflateByteSource(session: session, input: input, inputLength: compressed.count, plainLimit: plainLimit)
            return try decoder.decode(width: width, height: height, reader: &source)
        }
    }
}

private final class InflateByteSource: ZRLEBytes {
    let session: OpaquePointer
    let input: UnsafePointer<UInt8>?
    let inputLength: Int
    let plainLimit: Int

    init(session: OpaquePointer, input: UnsafePointer<UInt8>?, inputLength: Int, plainLimit: Int) {
        self.session = session
        self.input = input
        self.inputLength = inputLength
        self.plainLimit = plainLimit
    }
    var started = false
    var offset = 0
    private var produced = 0
    private var stash = [UInt8]()
    private var stashIndex = 0
    private var ended = false

    func byte() throws -> UInt8 {
        if stashIndex >= stash.count { try fill() }
        guard stashIndex < stash.count else { throw RFBError.invalid("화면 압축 데이터가 부족합니다.") }
        let value = stash[stashIndex]
        stashIndex += 1
        offset += 1
        return value
    }

    func isAtEnd() throws -> Bool {
        if stashIndex < stash.count { return false }
        try fill()
        return stashIndex >= stash.count
    }

    private func fill() throws {
        guard stashIndex >= stash.count, !ended else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var written = 0
        let provide = started ? 0 : 1
        let capacity = buffer.count
        started = true
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            inflate_session_read(session, provide == 1 ? input : nil, provide == 1 ? inputLength : 0, Int32(provide),
                                 raw.bindMemory(to: UInt8.self).baseAddress, capacity, &written)
        }
        guard status >= 0, written >= 0, written <= buffer.count else { throw RFBError.invalid("화면 압축을 풀지 못했습니다.") }
        if written == 0 {
            ended = true
            stash.removeAll(keepingCapacity: true)
            stashIndex = 0
            return
        }
        produced += written
        guard produced <= plainLimit else { throw RFBError.invalid("화면 압축 크기가 잘못되었습니다.") }
        stash = Array(buffer.prefix(written))
        stashIndex = 0
    }
}
