import Foundation

/// `TERM_PROGRAM` からターミナルアプリの bundle ID / 表示名を引く。
/// （NSWorkspace を使ったアクティベート自体は hinomi 側の TerminalJump が行う）
public enum TerminalCatalog {
    public struct Terminal: Equatable {
        public let bundleID: String
        public let displayName: String
    }

    private static let table: [String: Terminal] = [
        "iterm.app": Terminal(bundleID: "com.googlecode.iterm2", displayName: "iTerm2"),
        "iterm2": Terminal(bundleID: "com.googlecode.iterm2", displayName: "iTerm2"),
        "apple_terminal": Terminal(bundleID: "com.apple.Terminal", displayName: "Terminal"),
        "ghostty": Terminal(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"),
        "wezterm": Terminal(bundleID: "com.github.wez.wezterm", displayName: "WezTerm"),
        "kitty": Terminal(bundleID: "net.kovidgoyal.kitty", displayName: "kitty"),
        "alacritty": Terminal(bundleID: "org.alacritty", displayName: "Alacritty"),
        "warp": Terminal(bundleID: "dev.warp.Warp-Stable", displayName: "Warp"),
        "warpterminal": Terminal(bundleID: "dev.warp.Warp-Stable", displayName: "Warp"),
        "hyper": Terminal(bundleID: "co.zeit.hyper", displayName: "Hyper"),
        "vscode": Terminal(bundleID: "com.microsoft.VSCode", displayName: "VS Code"),
        "cursor": Terminal(bundleID: "com.todesktop.230313mzl4w4u92", displayName: "Cursor"),
    ]

    public static func terminal(forTermProgram raw: String?) -> Terminal? {
        guard let raw else { return nil }
        let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let hit = table[key] { return hit }
        // "iTerm.app"→"iterm"、"Apple_Terminal"→"apple_terminal" 等の揺れを吸収
        let stripped = key.replacingOccurrences(of: ".app", with: "")
        if let hit = table[stripped] { return hit }
        for (name, terminal) in table where stripped.contains(name) {
            return terminal
        }
        return nil
    }

    /// 一覧に出す短い名前（マッピングが無ければ生の値をそのまま）
    public static func shortName(forTermProgram raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let terminal = terminal(forTermProgram: raw) { return terminal.displayName }
        return raw.replacingOccurrences(of: ".app", with: "")
    }
}
