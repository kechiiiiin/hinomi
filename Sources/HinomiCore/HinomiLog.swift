import Foundation

/// `~/.hinomi/hinomi.log` への軽い追記ロガー（常駐なので上限を設けて回す）。
public enum HinomiLog {
    private static let lock = NSLock()
    private static let maxBytes = 512 * 1024

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func write(_ message: String, to url: URL = HinomiPaths.logURL) {
        lock.lock()
        defer { lock.unlock() }
        HinomiPaths.ensureStateDir()

        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
           size.intValue > maxBytes {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
