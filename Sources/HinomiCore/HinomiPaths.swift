import Foundation

/// hinomi が使うファイルパスの集約。テストや検証用に環境変数で差し替えできる。
public enum HinomiPaths {
    public static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/.hinomi`（`HINOMI_HOME` で上書き可能）
    public static var stateDir: URL {
        if let override = environment["HINOMI_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(".hinomi", isDirectory: true)
    }

    /// `~/.hinomi/hinomi.sock`（`HINOMI_SOCKET` で上書き可能）
    public static var socketPath: String {
        if let override = environment["HINOMI_SOCKET"], !override.isEmpty {
            return override
        }
        return stateDir.appendingPathComponent("hinomi.sock").path
    }

    public static var configURL: URL {
        stateDir.appendingPathComponent("config.json")
    }

    public static var logURL: URL {
        stateDir.appendingPathComponent("hinomi.log")
    }

    /// Claude Code のユーザー設定（`CLAUDE_SETTINGS_PATH` で上書き可能）
    public static var claudeSettingsURL: URL {
        if let override = environment["HINOMI_CLAUDE_SETTINGS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @discardableResult
    public static func ensureStateDir() -> Bool {
        let fm = FileManager.default
        let dir = stateDir
        if fm.fileExists(atPath: dir.path) { return true }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }
}
