import Foundation

/// `~/.hinomi/config.json`。全フィールド任意（欠けていれば既定値）。
public struct HinomiConfig: Codable, Equatable {
    /// PreToolUse の Allow/Deny を notch で受け付けるか
    public var permissionPromptEnabled: Bool
    /// notch でクリックを待つ秒数。無応答なら decision を返さず通常フローへ流す
    public var permissionWaitSeconds: Double
    /// Allow/Deny の対象ツール（Claude Code の matcher 記法）。空文字で全ツール（既定）
    public var permissionToolMatcher: String
    /// Stop（完了）時に鳴らす NSSound 名。空文字で無音
    public var doneSound: String
    /// 許可待ち発生時に鳴らす NSSound 名。空文字で無音（既定。うるさいため 2026-08-02 に無音化）
    public var permissionSound: String
    /// 効果音を鳴らすか。false ならどの音も鳴らさない（doneSound 等の設定は保ったまま黙らせる）
    public var soundsEnabled: Bool
    /// イベント発生時に自動展開しておく秒数
    public var autoExpandSeconds: Double
    /// セッションが無いときも畳んだ表示を出しておくか
    public var showWhenEmpty: Bool
    /// 完了したセッションを一覧に残す分数
    public var doneRetentionMinutes: Double
    /// オーバーレイを出すディスプレイ名（NSScreen.localizedName）。空文字で自動（マウスのある画面）
    public var preferredDisplay: String
    /// 展開ヘッダにトークン使用量（transcript のローカル集計）を出すか
    public var usageEnabled: Bool
    /// 直近5時間のトークン予算。0 で未設定（実数のまま表示し、%にしない）
    public var usageBudget5h: Double
    /// 直近7日のトークン予算。0 で未設定
    public var usageBudget7d: Double

    public static let `default` = HinomiConfig(
        permissionPromptEnabled: true,
        permissionWaitSeconds: 15,
        permissionToolMatcher: "",
        doneSound: "Glass",
        permissionSound: "",
        soundsEnabled: true,
        autoExpandSeconds: 6,
        showWhenEmpty: false,
        doneRetentionMinutes: 30,
        preferredDisplay: "",
        usageEnabled: true,
        usageBudget5h: 0,
        usageBudget7d: 0
    )

    public init(permissionPromptEnabled: Bool,
                permissionWaitSeconds: Double,
                permissionToolMatcher: String,
                doneSound: String,
                permissionSound: String,
                soundsEnabled: Bool = true,
                autoExpandSeconds: Double,
                showWhenEmpty: Bool,
                doneRetentionMinutes: Double,
                preferredDisplay: String = "",
                usageEnabled: Bool = true,
                usageBudget5h: Double = 0,
                usageBudget7d: Double = 0) {
        self.permissionPromptEnabled = permissionPromptEnabled
        self.permissionWaitSeconds = permissionWaitSeconds
        self.permissionToolMatcher = permissionToolMatcher
        self.doneSound = doneSound
        self.permissionSound = permissionSound
        self.soundsEnabled = soundsEnabled
        self.autoExpandSeconds = autoExpandSeconds
        self.showWhenEmpty = showWhenEmpty
        self.doneRetentionMinutes = doneRetentionMinutes
        self.preferredDisplay = preferredDisplay
        self.usageEnabled = usageEnabled
        self.usageBudget5h = usageBudget5h
        self.usageBudget7d = usageBudget7d
    }

    private enum CodingKeys: String, CodingKey {
        case permissionPromptEnabled, permissionWaitSeconds, permissionToolMatcher
        case doneSound, permissionSound, soundsEnabled
        case autoExpandSeconds, showWhenEmpty, doneRetentionMinutes
        case preferredDisplay
        case usageEnabled, usageBudget5h, usageBudget7d
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HinomiConfig.default
        permissionPromptEnabled = try c.decodeIfPresent(Bool.self, forKey: .permissionPromptEnabled) ?? d.permissionPromptEnabled
        permissionWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .permissionWaitSeconds) ?? d.permissionWaitSeconds
        permissionToolMatcher = try c.decodeIfPresent(String.self, forKey: .permissionToolMatcher) ?? d.permissionToolMatcher
        doneSound = try c.decodeIfPresent(String.self, forKey: .doneSound) ?? d.doneSound
        permissionSound = try c.decodeIfPresent(String.self, forKey: .permissionSound) ?? d.permissionSound
        soundsEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? d.soundsEnabled
        autoExpandSeconds = try c.decodeIfPresent(Double.self, forKey: .autoExpandSeconds) ?? d.autoExpandSeconds
        showWhenEmpty = try c.decodeIfPresent(Bool.self, forKey: .showWhenEmpty) ?? d.showWhenEmpty
        doneRetentionMinutes = try c.decodeIfPresent(Double.self, forKey: .doneRetentionMinutes) ?? d.doneRetentionMinutes
        preferredDisplay = try c.decodeIfPresent(String.self, forKey: .preferredDisplay) ?? d.preferredDisplay
        usageEnabled = try c.decodeIfPresent(Bool.self, forKey: .usageEnabled) ?? d.usageEnabled
        usageBudget5h = try c.decodeIfPresent(Double.self, forKey: .usageBudget5h) ?? d.usageBudget5h
        usageBudget7d = try c.decodeIfPresent(Double.self, forKey: .usageBudget7d) ?? d.usageBudget7d
    }

    /// 待ち時間は 1〜120 秒に丸める（フックを不用意に長く止めない）
    public var clampedPermissionWait: Double {
        min(max(permissionWaitSeconds, 1), 120)
    }

    public static func load(from url: URL = HinomiPaths.configURL) -> HinomiConfig {
        guard let data = try? Data(contentsOf: url) else { return .default }
        return (try? JSONDecoder().decode(HinomiConfig.self, from: data)) ?? .default
    }

    public func save(to url: URL = HinomiPaths.configURL) throws {
        HinomiPaths.ensureStateDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
