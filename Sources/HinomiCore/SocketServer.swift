import Foundation

/// `~/.hinomi/hinomi.sock` を listen し、hinomi-hook からの1行 JSON を受ける。
///
/// - 1接続 = 1メッセージ（改行終端 JSON）
/// - mode=ask のときだけ、ハンドラが答えを返すまで（or 期限まで）接続を保って1行 JSON を書き返す
public final class SocketServer {
    /// ハンドラは main キューで呼ばれる。ask のときは respond を1回だけ呼ぶ。
    public typealias Handler = (_ message: HookMessage, _ respond: @escaping (PermissionAnswer) -> Void) -> Void

    public let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let workQueue = DispatchQueue(label: "app.hinomi.socket.work", attributes: .concurrent)
    private let stateLock = NSLock()
    private var running = false

    public init(path: String = HinomiPaths.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        HinomiPaths.ensureStateDir()
        // 前回の残骸を掃除（起動中の他インスタンスがいれば bind が失敗して分かる）
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocket.SocketError.syscall("socket", errno) }

        var addr = try UnixSocket.makeAddress(path: path)
        let bound = UnixSocket.withSockAddr(&addr) { pointer, length in
            bind(fd, pointer, length)
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw UnixSocket.SocketError.syscall("bind", code)
        }
        guard listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw UnixSocket.SocketError.syscall("listen", code)
        }
        chmod(path, 0o600)

        listenFD = fd
        stateLock.lock(); running = true; stateLock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "app.hinomi.socket.accept"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    public func stop() {
        stateLock.lock(); running = false; stateLock.unlock()
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func acceptLoop() {
        while isRunning {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            workQueue.async { [weak self] in
                self?.serve(clientFD: clientFD)
            }
        }
    }

    private func serve(clientFD: Int32) {
        defer { close(clientFD) }
        UnixSocket.setTimeout(clientFD, option: SO_RCVTIMEO, seconds: 5)
        UnixSocket.setTimeout(clientFD, option: SO_SNDTIMEO, seconds: 5)

        guard let line = UnixSocket.readLine(fd: clientFD),
              let message = HookMessage(jsonData: line) else { return }

        guard message.mode == .ask else {
            DispatchQueue.main.async { [handler] in
                handler(message) { _ in }
            }
            return
        }

        let box = AnswerBox()
        DispatchQueue.main.async { [handler] in
            handler(message) { answer in box.resolve(answer) }
        }
        // フック側のタイムアウトより少し短く待つ（フック側が先に諦めないように）
        let waitSeconds = min(max(message.waitSeconds, 1), 120)
        let answer = box.wait(timeout: waitSeconds + 0.5)
        let reply = PermissionReply(answer: answer,
                                    reason: answer == .none ? "hinomi: 無応答のため通常フローへ" : "hinomi: notch で選択")
        UnixSocket.writeAll(fd: clientFD, data: reply.encoded())
    }
}

/// 1回だけ解決される答えの箱（背景スレッドが待ち、main スレッドが解決する）。
private final class AnswerBox {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var answer: PermissionAnswer?
    private var settled = false

    func resolve(_ value: PermissionAnswer) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        answer = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> PermissionAnswer {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        settled = true
        return answer ?? .none
    }
}
