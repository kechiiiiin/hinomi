import Foundation

/// AF_UNIX ソケット周りの低レベルヘルパ（Foundation + POSIX のみ）。
enum UnixSocket {
    static let maxPathLength = 100  // sockaddr_un.sun_path は 104 バイト

    enum SocketError: LocalizedError {
        case pathTooLong(String)
        case syscall(String, Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong(let path):
                return "socket のパスが長すぎます（\(path)）"
            case .syscall(let name, let code):
                return "\(name) が失敗しました: \(String(cString: strerror(code))) (errno=\(code))"
            }
        }
    }

    static func makeAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathLength else { throw SocketError.pathTooLong(path) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return addr
    }

    static func withSockAddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                body(rebound, length)
            }
        }
    }

    static func setTimeout(_ fd: Int32, option: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 改行までを1メッセージとして読む。EOF でも読めた分を返す。
    static func readLine(fd: Int32, limit: Int = 1 << 20) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < limit {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if let index = buffer.firstIndex(of: 0x0A) {
                    return buffer.prefix(upTo: index)
                }
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                break
            }
        }
        return buffer.isEmpty ? nil : buffer
    }

    @discardableResult
    static func writeAll(fd: Int32, data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress, raw.count)
            }
            if written > 0 {
                remaining = remaining.dropFirst(written)
            } else {
                if written < 0 && errno == EINTR { continue }
                return false
            }
        }
        return true
    }
}
