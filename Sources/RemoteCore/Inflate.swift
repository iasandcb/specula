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
}
