import Foundation

/// tty からタブ／ペインを選ぶ AppleScript の組み立て（純粋関数だけ）。
///
/// 実行は hinomi 側の `TerminalJump` が行う。ここに閉じてあるのは、
/// 文字列の組み立てとエスケープをテストで固定したいため。
public enum TerminalJumpScript {
    /// `/dev/ttys003` の形だけ通す。AppleScript に渡す値を素性の分かるものに限る
    /// （ここで弾いておけば、エスケープを抜けられても害が出ない）。
    public static func isPlausibleTTY(_ tty: String) -> Bool {
        guard tty.hasPrefix("/dev/tty"), tty.count <= 32 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/")
        return tty.allSatisfy { allowed.contains($0) }
    }

    /// AppleScript の文字列リテラルとして安全にする。`\` を先に潰してから `"`。
    public static func escapedLiteral(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// tty が一致するタブ／セッションを選ぶスクリプト。
    /// AppleScript で辿れないターミナル（Ghostty / kitty / WezTerm / VS Code 等）は nil。
    public static func script(bundleID: String, tty: String) -> String? {
        guard isPlausibleTTY(tty) else { return nil }
        let target = escapedLiteral(tty)
        switch bundleID {
        case "com.googlecode.iterm2":
            // iTerm2 は windows → tabs → sessions（= ペイン）まで辿れる
            return """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(target)" then
                      select w
                      select t
                      select s
                      activate
                      return true
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return false
            """
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(target)" then
                    set selected tab of w to t
                    set frontmost of w to true
                    activate
                    return true
                  end if
                end repeat
              end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }
}
