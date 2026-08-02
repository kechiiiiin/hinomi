import AppKit
import HinomiCore

/// TERM_PROGRAM から、そのターミナルアプリを前面に出す。
/// タブ単位の精密ジャンプはしない（アプリのアクティベートまで）。
enum TerminalJump {
    @discardableResult
    static func activate(termProgram: String?) -> Bool {
        guard let terminal = TerminalCatalog.terminal(forTermProgram: termProgram) else {
            HinomiLog.write("jump: 未知の TERM_PROGRAM (\(termProgram ?? "nil"))")
            return false
        }

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
