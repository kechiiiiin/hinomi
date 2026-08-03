import AppKit
import HinomiCore

/// セッションのターミナルへ跳ぶ。
///
/// tty が分かっていて、かつ AppleScript で辿れるターミナル（iTerm2 / Terminal.app）なら
/// **そのタブ／ペインまで**選ぶ。それ以外はアプリを前面に出すところまで。
/// AppleScript が失敗したとき（オートメーション権限の拒否を含む）は黙って
/// アクティベートに退避する——ジャンプできないより、雑にでも前に出る方がまし。
enum TerminalJump {
    /// NSAppleScript はスレッドセーフではないので、実行はこの直列キューに閉じる。
    /// （UI スレッドで走らせると、権限ダイアログや遅い端末で notch が固まる）
    /// 注: NSAppleScript を「main のみ」と読む解釈も世間にはある。直列キューに閉じれば
    /// Apple のスレッド安全性分類（同時1スレッド）は満たすが、稀な不具合報告があることは承知の上のトレードオフ。
    private static let scriptQueue = DispatchQueue(label: "app.hinomi.applescript")

    @discardableResult
    static func activate(termProgram: String?, tty: String? = nil) -> Bool {
        guard let terminal = TerminalCatalog.terminal(forTermProgram: termProgram) else {
            HinomiLog.write("jump: 未知の TERM_PROGRAM (\(termProgram ?? "nil"))")
            return false
        }

        if let tty, let source = TerminalJumpScript.script(bundleID: terminal.bundleID, tty: tty) {
            scriptQueue.async {
                switch runAppleScript(source) {
                case .selected:
                    return
                case .notFound:
                    HinomiLog.write("jump: \(terminal.displayName) に tty=\(tty) のタブが見つからず。アプリのアクティベートに退避")
                case .scriptError:
                    HinomiLog.write("jump: \(terminal.displayName) の AppleScript 実行に失敗（オートメーション権限拒否の可能性）。アプリのアクティベートに退避 tty=\(tty)")
                }
                DispatchQueue.main.async { _ = activateApp(terminal) }
            }
            return true
        }

        return activateApp(terminal)
    }

    private enum ScriptOutcome {
        case selected     // tty が一致するタブを選べた
        case notFound     // 実行はできたが一致するタブが無かった
        case scriptError  // 実行自体が失敗（権限拒否・構文など）
    }

    private static func runAppleScript(_ source: String) -> ScriptOutcome {
        guard let script = NSAppleScript(source: source) else { return .scriptError }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            HinomiLog.write("jump: AppleScript エラー \(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")")
            return .scriptError
        }
        return result.booleanValue ? .selected : .notFound
    }

    @discardableResult
    private static func activateApp(_ terminal: TerminalCatalog.Terminal) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: terminal.bundleID)
        if let app = running.first {
            return app.activate(options: [.activateAllWindows])
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleID) else {
            HinomiLog.write("jump: \(terminal.bundleID) が見つかりません")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }
}
