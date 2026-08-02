import XCTest
@testable import HinomiCore

final class HookInstallerTests: XCTestCase {
    private let hookPath = "/Applications/hinomi.app/Contents/MacOS/hinomi-hook"

    private func commands(in settings: [String: Any], event: String) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let groups = hooks[event] as? [[String: Any]] else { return [] }
        return groups.flatMap { group -> [String] in
            (group["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        }
    }

    func testMergePreservesExistingHooks() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [
                    ["hooks": [
                        ["type": "command", "command": "python3 $HOME/.claude/hooks/discord-notify.py", "async": true],
                        ["type": "command", "command": "python3 $HOME/.claude/scripts/save-conversation.py --event stop"],
                    ]],
                ],
                "PreCompact": [["matcher": "auto", "hooks": [["type": "command", "command": "echo hi"]]]],
            ],
        ]

        let merged = HookInstaller.merged(into: existing, hookExecutable: hookPath, config: .default)

        // 既存の設定・既存フックは残る
        XCTAssertEqual(merged["model"] as? String, "opus")
        let stopCommands = commands(in: merged, event: "Stop")
        XCTAssertTrue(stopCommands.contains("python3 $HOME/.claude/hooks/discord-notify.py"))
        XCTAssertTrue(stopCommands.contains("python3 $HOME/.claude/scripts/save-conversation.py --event stop"))
        XCTAssertEqual(commands(in: merged, event: "PreCompact"), ["echo hi"])

        // hinomi の分が足されている
        XCTAssertTrue(stopCommands.contains("'\(hookPath)' event"))
        XCTAssertEqual(commands(in: merged, event: "PreToolUse"), ["'\(hookPath)' ask"])
        for event in ["SessionStart", "UserPromptSubmit", "Notification", "SessionEnd"] {
            XCTAssertEqual(commands(in: merged, event: event), ["'\(hookPath)' event"], event)
        }
    }

    func testPreToolUseEntryUsesMatcherAndTimeout() throws {
        let merged = HookInstaller.merged(into: [:], hookExecutable: hookPath, config: .default)
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["matcher"] as? String, HinomiConfig.default.permissionToolMatcher)
        let inner = try XCTUnwrap(groups[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner[0]["type"] as? String, "command")
        // 待ち時間 + 余裕。async は付けない（応答を待つ必要があるため）
        XCTAssertEqual(inner[0]["timeout"] as? Int, Int(HinomiConfig.default.clampedPermissionWait) + 10)
        XCTAssertNil(inner[0]["async"])

        // イベント系は async: true（セッションを一切待たせない）
        let stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let stopInner = try XCTUnwrap(stopGroups[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(stopInner[0]["async"] as? Bool, true)
        XCTAssertNil(stopGroups[0]["matcher"])
    }

    func testInstallIsIdempotent() {
        let once = HookInstaller.merged(into: [:], hookExecutable: hookPath, config: .default)
        let twice = HookInstaller.merged(into: once, hookExecutable: hookPath, config: .default)
        XCTAssertEqual(commands(in: twice, event: "Stop"), ["'\(hookPath)' event"])
        XCTAssertEqual(commands(in: twice, event: "PreToolUse"), ["'\(hookPath)' ask"])
    }

    func testUninstallRemovesOnlyOurs() {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "python3 keep-me.py"]]]],
            ],
        ]
        let merged = HookInstaller.merged(into: existing, hookExecutable: hookPath, config: .default)
        let cleaned = HookInstaller.removingOurs(from: merged)

        XCTAssertEqual(commands(in: cleaned, event: "Stop"), ["python3 keep-me.py"])
        // hinomi 専用に作られたイベントはキーごと消える
        let hooks = cleaned["hooks"] as? [String: Any] ?? [:]
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["SessionStart"])
        XCTAssertNil(hooks["Notification"])
    }

    func testUninstallOnUntouchedSettingsIsNoop() {
        let existing: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo a"]]]]]]
        let cleaned = HookInstaller.removingOurs(from: existing)
        XCTAssertEqual(commands(in: cleaned, event: "Stop"), ["echo a"])
    }

    func testRemovingOursDropsHooksKeyWhenEmpty() {
        let merged = HookInstaller.merged(into: [:], hookExecutable: hookPath, config: .default)
        let cleaned = HookInstaller.removingOurs(from: merged)
        XCTAssertNil(cleaned["hooks"])
    }

    func testCommandQuotesPathWithSpaces() {
        let path = "/Users/k/My Apps/hinomi.app/Contents/MacOS/hinomi-hook"
        XCTAssertEqual(HookInstaller.command(hookExecutable: path, mode: .ask), "'\(path)' ask")
    }

    func testPermissionPromptDisabledFallsBackToEventMode() {
        var config = HinomiConfig.default
        config.permissionPromptEnabled = false
        let merged = HookInstaller.merged(into: [:], hookExecutable: hookPath, config: config)
        XCTAssertEqual(commands(in: merged, event: "PreToolUse"), ["'\(hookPath)' event"])
    }

    // MARK: - 実ファイルへの書き込み（バックアップと非破壊性）

    func testInstallAndUninstallOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hinomi-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settingsURL = dir.appendingPathComponent("settings.json")
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep"}]}]}}"#
        try Data(original.utf8).write(to: settingsURL)

        let installer = HookInstaller(settingsURL: settingsURL, hookExecutable: hookPath, config: .default)
        XCTAssertFalse(installer.isInstalled())

        let installed = try installer.install()
        XCTAssertNotNil(installed.backupURL)
        XCTAssertTrue(installer.isInstalled())

        // バックアップは元の内容そのまま
        let backup = try XCTUnwrap(installed.backupURL)
        XCTAssertEqual(String(decoding: try Data(contentsOf: backup), as: UTF8.self), original)

        // 書き戻した JSON は読める形で、既存フックが生きている
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertEqual(written["model"] as? String, "opus")
        XCTAssertTrue(commands(in: written, event: "Stop").contains("echo keep"))

        _ = try installer.uninstall()
        XCTAssertFalse(installer.isInstalled())
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertEqual(commands(in: after, event: "Stop"), ["echo keep"])
        XCTAssertEqual(after["model"] as? String, "opus")
    }

    func testInstallOnMissingSettingsCreatesFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hinomi-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsURL = dir.appendingPathComponent("settings.json")

        let installer = HookInstaller(settingsURL: settingsURL, hookExecutable: hookPath, config: .default)
        let result = try installer.install()
        XCTAssertNil(result.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertTrue(installer.isInstalled())
    }

    func testUnreadableSettingsThrows() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hinomi-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsURL = dir.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: settingsURL)

        let installer = HookInstaller(settingsURL: settingsURL, hookExecutable: hookPath, config: .default)
        XCTAssertThrowsError(try installer.install())
    }
}
