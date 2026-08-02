import Foundation

/// `~/.claude/settings.json` に hinomi の hooks を **非破壊マージ** する。
///
/// - 既存の hooks（他ツールのもの）は一切触らない
/// - hinomi のエントリは command 文字列に `hinomi-hook` を含むことで識別し、再インストール時は置換する
/// - 書き換え前に必ずバックアップを作る
public struct HookInstaller {
    /// hinomi のエントリを見分ける目印（余計なキーを settings.json に足さないため command で判定する）
    public static let marker = "hinomi-hook"

    public struct Entry {
        public let event: String
        public let matcher: String?
        public let mode: HookMessageMode
        public let timeout: Int
        public let async: Bool
    }

    public struct Result {
        public let settingsURL: URL
        public let backupURL: URL?
        public let events: [String]
    }

    public let settingsURL: URL
    public let hookExecutable: String
    public let config: HinomiConfig

    public init(settingsURL: URL = HinomiPaths.claudeSettingsURL,
                hookExecutable: String,
                config: HinomiConfig = .load()) {
        self.settingsURL = settingsURL
        self.hookExecutable = hookExecutable
        self.config = config
    }

    // MARK: - エントリ定義

    public static func entries(config: HinomiConfig) -> [Entry] {
        var list: [Entry] = [
            Entry(event: "SessionStart", matcher: nil, mode: .event, timeout: 10, async: true),
            Entry(event: "UserPromptSubmit", matcher: nil, mode: .event, timeout: 10, async: true),
            Entry(event: "Notification", matcher: nil, mode: .event, timeout: 10, async: true),
            Entry(event: "Stop", matcher: nil, mode: .event, timeout: 10, async: true),
            Entry(event: "SessionEnd", matcher: nil, mode: .event, timeout: 10, async: true),
        ]
        if config.permissionPromptEnabled {
            // ask は応答を待つので async にできない。timeout は待ち時間 + 余裕。
            let timeout = Int(config.clampedPermissionWait.rounded(.up)) + 10
            list.append(Entry(event: "PreToolUse",
                              matcher: config.permissionToolMatcher,
                              mode: .ask,
                              timeout: timeout,
                              async: false))
        } else {
            list.append(Entry(event: "PreToolUse",
                              matcher: config.permissionToolMatcher,
                              mode: .event,
                              timeout: 10,
                              async: true))
        }
        return list
    }

    /// シェル経由で実行されるため、パスは単一引用符で囲む。
    public static func command(hookExecutable: String, mode: HookMessageMode) -> String {
        let escaped = hookExecutable.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)' \(mode.rawValue)"
    }

    // MARK: - 純粋なマージ処理（テスト対象）

    public static func removingOurs(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for group in groups {
                guard let inner = group["hooks"] as? [[String: Any]] else {
                    kept.append(group)
                    continue
                }
                let remaining = inner.filter { hook in
                    guard let command = hook["command"] as? String else { return true }
                    return !command.contains(marker)
                }
                if remaining.isEmpty { continue }        // hinomi 専用グループごと消す
                if remaining.count == inner.count {
                    kept.append(group)                    // 変化なし
                } else {
                    var group = group
                    group["hooks"] = remaining            // 他ツールと同居していた分は残す
                    kept.append(group)
                }
            }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        return settings
    }

    public static func merged(into settings: [String: Any],
                              hookExecutable: String,
                              config: HinomiConfig) -> [String: Any] {
        var settings = removingOurs(from: settings)   // 冪等性のため先に自分の分を除去
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for entry in entries(config: config) {
            var hook: [String: Any] = [
                "type": "command",
                "command": command(hookExecutable: hookExecutable, mode: entry.mode),
                "timeout": entry.timeout,
            ]
            if entry.async { hook["async"] = true }

            var group: [String: Any] = ["hooks": [hook]]
            if let matcher = entry.matcher { group["matcher"] = matcher }

            var groups = hooks[entry.event] as? [[String: Any]] ?? []
            groups.append(group)
            hooks[entry.event] = groups
        }

        settings["hooks"] = hooks
        return settings
    }

    // MARK: - ファイル操作

    @discardableResult
    public func install() throws -> Result {
        let (settings, backup) = try loadAndBackup()
        let merged = HookInstaller.merged(into: settings, hookExecutable: hookExecutable, config: config)
        try write(merged)
        return Result(settingsURL: settingsURL,
                      backupURL: backup,
                      events: HookInstaller.entries(config: config).map(\.event))
    }

    @discardableResult
    public func uninstall() throws -> Result {
        let (settings, backup) = try loadAndBackup()
        let cleaned = HookInstaller.removingOurs(from: settings)
        try write(cleaned)
        return Result(settingsURL: settingsURL, backupURL: backup, events: [])
    }

    public func isInstalled() -> Bool {
        guard let settings = try? loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let inner = group["hooks"] as? [[String: Any]] else { continue }
                for hook in inner {
                    if let command = hook["command"] as? String,
                       command.contains(HookInstaller.marker) { return true }
                }
            }
        }
        return false
    }

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unreadableSettings(settingsURL.path)
        }
        return object
    }

    private func loadAndBackup() throws -> ([String: Any], URL?) {
        let settings = try loadSettings()
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return (settings, nil) }
        let stamp = HookInstaller.timestampFormatter.string(from: Date())
        let backup = settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(settingsURL.lastPathComponent).hinomi-backup-\(stamp)")
        try Data(contentsOf: settingsURL).write(to: backup, options: .atomic)
        return (settings, backup)
    }

    private func write(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
    }

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public enum InstallError: LocalizedError {
        case unreadableSettings(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableSettings(let path):
                return "\(path) を JSON として読めませんでした。手で確認してください。"
            }
        }
    }
}
