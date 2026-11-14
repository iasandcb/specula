#if !canImport(Security)
import Foundation
#if canImport(Glibc)
import Glibc
#endif

let kSecRandomDefault: UnsafeMutableRawPointer? = nil
let errSecSuccess: Int32 = 0

func SecRandomCopyBytes(_ rnd: UnsafeMutableRawPointer?, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> Int32 {
    let fd = open("/dev/urandom", O_RDONLY)
    guard fd >= 0 else { return -1 }
    defer { _ = close(fd) }
    var filled = 0
    while filled < count {
        let readCount = read(fd, bytes.advanced(by: filled), count - filled)
        if readCount > 0 { filled += readCount }
        else if errno == EINTR { continue }
        else { return -1 }
    }
    return errSecSuccess
}
#endif
