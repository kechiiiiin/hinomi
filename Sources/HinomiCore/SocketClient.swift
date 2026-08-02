import Foundation

/// hinomi-hook 側の送信口。アプリが居なければ静かに諦める（セッションを止めない）。
public enum SocketClient {
    public enum Result: Equatable {
        case delivered(Data?)   // 送信できた（ask のときは応答 Data）
        case unavailable        // アプリが起動していない／socket が無い
    }

    public static func send(_ payload: Data,
                            to path: String = HinomiPaths.socketPath,
                            expectReply: Bool,
                            timeout: TimeInterval) -> Result {
        guard FileManager.default.fileExists(atPath: path) else { return .unavailable }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }

        UnixSocket.setTimeout(fd, option: SO_SNDTIMEO, seconds: min(timeout, 3))
        UnixSocket.setTimeout(fd, option: SO_RCVTIMEO, seconds: timeout)

        do {
            var addr = try UnixSocket.makeAddress(path: path)
            let result = UnixSocket.withSockAddr(&addr) { pointer, length in
                connect(fd, pointer, length)
            }
            guard result == 0 else { return .unavailable }
        } catch {
            return .unavailable
        }

        var data = payload
        if data.last != 0x0A { data.append(0x0A) }
        guard UnixSocket.writeAll(fd: fd, data: data) else { return .unavailable }

        guard expectReply else {
            shutdown(fd, SHUT_WR)
            return .delivered(nil)
        }
        shutdown(fd, SHUT_WR)
        return .delivered(UnixSocket.readLine(fd: fd))
    }

    /// アプリが listen しているかの軽い確認。
    public static func isAppListening(path: String = HinomiPaths.socketPath) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        do {
            var addr = try UnixSocket.makeAddress(path: path)
            let result = UnixSocket.withSockAddr(&addr) { pointer, length in
                connect(fd, pointer, length)
            }
            return result == 0
        } catch {
            return false
        }
    }
}
