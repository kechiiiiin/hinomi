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
    private static let scriptQueue = DispatchQueue(label: "app.hinomi.applescript")

    @discardableResult
    static func activate(termProgram: String?, tty: String? = nil) -> Bool {
        guard let terminal = TerminalCatalog.terminal(forTermProgram: termProgram) else {
            HinomiLog.write("jump: 未知の TERM_PROGRAM (\(termProgram ?? "nil"))")
            return false
        }

        if let tty, let source = TerminalJumpScript.script(bundleID: terminal.bundleID, tty: tty) {
            scriptQueue.async {
                if runAppleScript(source) { return }
                HinomiLog.write("jump: \(terminal.displayName) のタブ選択に失敗（オートメーション権限の可能性）。アプリのアクティベートに退避 tty=\(tty)")
                DispatchQueue.main.async { _ = activateApp(terminal) }
            }
            return true
        }

        return activateApp(terminal)
    }

    /// tty が一致するタブが見つかって選べたら true
    private static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            HinomiLog.write("jump: AppleScript エラー \(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")")
            return false
        }
        return result.booleanValue
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
