import AppKit
import HinomiCore

/// メニューバー常駐とは別に、ターミナルから叩けるサブコマンド群。
enum CLI {
    static func usage() {
        print("""
        hinomi \(hinomiVersion) — Claude Code セッションを画面上部で見張る常駐アプリ

        使い方:
          hinomi                     常駐アプリとして起動（メニューバー＋notch オーバーレイ）
          hinomi install-hooks       ~/.claude/settings.json に hinomi の hooks を非破壊マージ
          hinomi uninstall-hooks     追記した hinomi の hooks を除去
          hinomi status              socket の待ち受け状況と hooks の導入状況を表示
          hinomi hook <event|ask>    hinomi-hook と同じ動作（stdin の hook JSON を送る）
          hinomi version             バージョン表示

        オプション（install-hooks / uninstall-hooks）:
          --settings <path>          対象の settings.json（既定: ~/.claude/settings.json）
          --hook-path <path>         hooks に書き込む hinomi-hook のパス（既定: 実行ファイルの隣）

        socket:   \(HinomiPaths.socketPath)
        設定:     \(HinomiPaths.configURL.path)
        ログ:     \(HinomiPaths.logURL.path)
        """)
    }

    // MARK: - hooks の導入 / 除去

    static func installHooks(arguments: [String]) {
        let options = Options(arguments)
        let hookPath: String
        do {
            hookPath = try options.hookPath ?? resolveHookExecutable()
        } catch {
            fail(error.localizedDescription)
        }

        let installer = HookInstaller(settingsURL: options.settingsURL,
                                      hookExecutable: hookPath,
                                      config: HinomiConfig.load())
        do {
            let result = try installer.install()
            print("hinomi: hooks を追記しました → \(result.settingsURL.path)")
            if let backup = result.backupURL {
                print("hinomi: バックアップ → \(backup.path)")
            }
            print("hinomi: 対象イベント → \(result.events.joined(separator: ", "))")
            print("hinomi: hinomi-hook → \(hookPath)")
            print("hinomi: 既に開いている Claude Code セッションには反映されません（開き直してください）")
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func uninstallHooks(arguments: [String]) {
        let options = Options(arguments)
        let installer = HookInstaller(settingsURL: options.settingsURL,
                                      hookExecutable: (try? resolveHookExecutable()) ?? "hinomi-hook",
                                      config: HinomiConfig.load())
        do {
            let result = try installer.uninstall()
            print("hinomi: hooks を除去しました → \(result.settingsURL.path)")
            if let backup = result.backupURL {
                print("hinomi: バックアップ → \(backup.path)")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func status() {
        let listening = SocketClient.isAppListening()
        let installer = HookInstaller(hookExecutable: (try? resolveHookExecutable()) ?? "hinomi-hook")
        print("socket:  \(HinomiPaths.socketPath)")
        print("待ち受け: \(listening ? "あり（アプリ起動中）" : "なし（アプリ未起動）")")
        print("hooks:   \(installer.isInstalled() ? "導入済み" : "未導入") (\(HinomiPaths.claudeSettingsURL.path))")
        let config = HinomiConfig.load()
        let matcherLabel = config.permissionToolMatcher.isEmpty ? "全ツール" : config.permissionToolMatcher
        print("許可UI:  \(config.permissionPromptEnabled ? "有効" : "無効") / 待ち \(Int(config.clampedPermissionWait))秒 / matcher \(matcherLabel)")
        exit(listening ? 0 : 1)
    }

    // MARK: - hinomi-hook 相当（同梱バイナリが使えない環境向けの保険）

    static func hook(arguments: [String]) {
        let mode = HookMessageMode(rawValue: arguments.first ?? "event") ?? .event
        let config = HinomiConfig.load()
        let payload = HookEnvelope.build(stdin: FileHandle.standardInput.readDataToEndOfFile(),
                                         mode: mode,
                                         config: config)
        switch mode {
        case .event:
            _ = SocketClient.send(payload, expectReply: false, timeout: 2)
        case .ask:
            guard config.permissionPromptEnabled else { exit(0) }
            let result = SocketClient.send(payload, expectReply: true, timeout: config.clampedPermissionWait + 2)
            if case .delivered(let data) = result, let data,
               let reply = PermissionReply(data: data),
               let json = HookOutput.preToolUseJSON(answer: reply.answer,
                                                    reason: reply.reason ?? "hinomi") {
                print(json)
            }
        }
        exit(0)
    }

    // MARK: - ヘルパ

    private struct Options {
        var settingsURL: URL = HinomiPaths.claudeSettingsURL
        var hookPath: String?

        init(_ arguments: [String]) {
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--settings":
                    if index + 1 < arguments.count {
                        settingsURL = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
                        index += 1
                    }
                case "--hook-path":
                    if index + 1 < arguments.count {
                        hookPath = (arguments[index + 1] as NSString).expandingTildeInPath
                        index += 1
                    }
                default:
                    break
                }
                index += 1
            }
        }
    }

    /// 実行ファイルの隣にある hinomi-hook を探す（.app の Contents/MacOS でも .build/release でも同じ形）
    static func resolveHookExecutable() throws -> String {
        var candidates: [String] = []
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(executable.deletingLastPathComponent()
                .appendingPathComponent("hinomi-hook").path)
        }
        let argv0 = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(argv0.deletingLastPathComponent().appendingPathComponent("hinomi-hook").path)

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw CLIError.hookExecutableMissing(candidates)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("hinomi: \(message)\n".utf8))
        exit(1)
    }

    enum CLIError: LocalizedError {
        case hookExecutableMissing([String])

        var errorDescription: String? {
            switch self {
            case .hookExecutableMissing(let paths):
                return """
                hinomi-hook が見つかりません。--hook-path で明示してください。
                探した場所: \(paths.joined(separator: ", "))
                """
            }
        }
    }
}
