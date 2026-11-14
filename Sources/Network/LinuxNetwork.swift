#if os(Linux)
import Dispatch
import Foundation
import Glibc

/// Test stand-in for Apple's Network.framework. The iOS app uses the system module;
/// this target is part of the package only when tests run on Linux.
public struct NWEndpoint {
    public struct Host: Equatable, Sendable {
        public var name: String
        public init(_ name: String) { self.name = name }
    }
    public struct Port: RawRepresentable, Equatable, Sendable {
        public var rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public static let any = Port(rawValue: 0)!
    }
}

public class NWProtocolTLS {
    public class Options { public init() {} }
}

public class NWProtocolTCP {
    public class Options {
        public var noDelay = false
        public var enableKeepalive = false
        public var keepaliveIdle = 0
        public var keepaliveInterval = 0
        public var keepaliveCount = 0
        public init() {}
    }
}

public struct NWParameters: Sendable {
    public var noDelay: Bool
    public var enableKeepalive: Bool
    public init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options) {
        noDelay = tcp.noDelay
        enableKeepalive = tcp.enableKeepalive
    }
    public static var tcp: NWParameters { NWParameters(tls: nil, tcp: NWProtocolTCP.Options()) }
}

public enum NWError: Error {
    case posix(Int32)
    case invalid
}

public final class NWConnection: @unchecked Sendable {
    public class ContentContext { public init() {} }
    public enum SendCompletion {
        case contentProcessed((Error?) -> Void)
    }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var queue: DispatchQueue?
    private var parameters: NWParameters
    private let host: String?
    private let port: UInt16?
    private var cancelled = false

    public init(host: NWEndpoint.Host, port: NWEndpoint.Port, using parameters: NWParameters) {
        self.host = host.name
        self.port = port.rawValue
        self.parameters = parameters
    }

    init(fd: Int32) {
        self.fd = fd
        self.host = nil
        self.port = nil
        self.parameters = .tcp
        tune(fd)
    }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        if fd >= 0 { return }
        queue.async { [weak self] in self?.connect() }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let descriptor = fd
        fd = -1
        lock.unlock()
        if descriptor >= 0 { _ = Glibc.close(descriptor) }
    }

    public func send(content: Data?, completion: SendCompletion) {
        let queue = queue ?? .global()
        queue.async { [weak self] in
            let error = self?.write(content ?? Data())
            if case .contentProcessed(let callback) = completion { callback(error) }
        }
    }

    public func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void) {
        let queue = queue ?? .global()
        queue.async { [weak self] in
            guard let self else {
                completion(nil, nil, true, .invalid)
                return
            }
            let minimum = max(minimumIncompleteLength, 1)
            let limit = max(maximumLength, minimum)
            var collected = Data()
            while collected.count < minimum {
                let room = limit - collected.count
                var buffer = [UInt8](repeating: 0, count: room)
                self.lock.lock()
                let descriptor = self.fd
                let closed = self.cancelled
                self.lock.unlock()
                if closed || descriptor < 0 {
                    completion(collected.isEmpty ? nil : collected, nil, true, collected.isEmpty ? .posix(Int32(ECONNRESET)) : nil)
                    return
                }
                let count = buffer.withUnsafeMutableBytes { raw in
                    Glibc.recv(descriptor, raw.baseAddress, room, 0)
                }
                if count > 0 {
                    collected.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    completion(collected.isEmpty ? nil : collected, nil, true, nil)
                    return
                } else if errno == EINTR {
                    continue
                } else {
                    completion(nil, nil, true, .posix(errno))
                    return
                }
            }
            completion(collected, nil, false, nil)
        }
    }

    private func connect() {
        guard let host, let port else { return }
        let descriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { return }
        tune(descriptor)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            _ = Glibc.close(descriptor)
            return
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            _ = Glibc.close(descriptor)
            return
        }
        lock.lock()
        if cancelled {
            lock.unlock()
            _ = Glibc.close(descriptor)
            return
        }
        fd = descriptor
        lock.unlock()
    }

    private func write(_ data: Data) -> Error? {
        lock.lock()
        let descriptor = fd
        let closed = cancelled
        lock.unlock()
        if closed || descriptor < 0 { return NWError.posix(Int32(ECONNRESET)) }
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Glibc.send(descriptor, raw.baseAddress! + sent, bytes.count - sent, Int32(MSG_NOSIGNAL))
            }
            if count > 0 { sent += count }
            else if errno == EINTR { continue }
            else { return NWError.posix(errno) }
        }
        return nil
    }

    private func tune(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        if parameters.noDelay { setsockopt(descriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size)) }
        if parameters.enableKeepalive { setsockopt(descriptor, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size)) }
    }
}

public final class NWListener: @unchecked Sendable {
    public enum State {
        case setup
        case waiting(NWError)
        case ready
        case failed(NWError)
        case cancelled
    }

    public var newConnectionHandler: ((NWConnection) -> Void)?
    public var stateUpdateHandler: ((State) -> Void)?
    public private(set) var port: NWEndpoint.Port?
    private var fd: Int32 = -1
    private var queue: DispatchQueue?
    private let lock = NSLock()
    private var stopped = false

    public init(using _: NWParameters, on port: NWEndpoint.Port) throws {
        let descriptor = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { throw NWError.posix(errno) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.rawValue.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Glibc.listen(descriptor, 16) == 0 else {
            let error = errno
            _ = Glibc.close(descriptor)
            throw NWError.posix(error)
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else {
            _ = Glibc.close(descriptor)
            throw NWError.posix(errno)
        }
        self.fd = descriptor
        self.port = NWEndpoint.Port(rawValue: UInt16(bigEndian: boundAddress.sin_port))
    }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        queue.async { [weak self] in self?.stateUpdateHandler?(.ready) }
        DispatchQueue.global().async { [weak self] in self?.acceptLoop() }
    }

    public func cancel() {
        lock.lock()
        stopped = true
        let descriptor = fd
        fd = -1
        lock.unlock()
        if descriptor >= 0 { _ = Glibc.close(descriptor) }
        queue?.async { [weak self] in self?.stateUpdateHandler?(.cancelled) }
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let descriptor = fd
            let closed = stopped
            lock.unlock()
            if closed || descriptor < 0 { return }
            let client = Glibc.accept(descriptor, nil, nil)
            if client < 0 {
                if stopped || errno == EBADF { return }
                continue
            }
            let connection = NWConnection(fd: client)
            queue?.async { [weak self] in self?.newConnectionHandler?(connection) }
        }
    }
}
#endif
