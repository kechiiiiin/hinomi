import XCTest
@testable import HinomiCore

final class SessionStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func msg(_ json: String, offset: TimeInterval = 0) -> HookMessage {
        HookMessage(jsonData: Data(json.utf8), now: base.addingTimeInterval(offset))!
    }

    func testLifecycleTransitions() {
        let store = SessionStore()

        XCTAssertEqual(store.apply(msg(#"{"session_id":"s1","cwd":"/w/hinomi","hook_event_name":"SessionStart","source":"startup"}"#)), .none)
        XCTAssertEqual(store.session(id: "s1")?.state, .idle)
        XCTAssertEqual(store.session(id: "s1")?.projectName, "hinomi")

        XCTAssertEqual(store.apply(msg(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"やって"}"#, offset: 1)), .none)
        XCTAssertEqual(store.session(id: "s1")?.state, .working)

        XCTAssertEqual(store.apply(msg(#"{"session_id":"s1","hook_event_name":"Notification","notification_type":"idle_prompt"}"#, offset: 2)), .inputNeeded)
        XCTAssertEqual(store.session(id: "s1")?.state, .awaitingInput)

        XCTAssertEqual(store.apply(msg(#"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"完了しました"}"#, offset: 3)), .finished)
        XCTAssertEqual(store.session(id: "s1")?.state, .done)
        XCTAssertEqual(store.session(id: "s1")?.activity, "完了しました")

        XCTAssertEqual(store.apply(msg(#"{"session_id":"s1","hook_event_name":"SessionEnd","end_reason":"logout"}"#, offset: 4)), .none)
        XCTAssertNil(store.session(id: "s1"))
        XCTAssertEqual(store.count, 0)
    }

    func testAskCreatesPendingPermission() {
        let store = SessionStore()
        let effect = store.apply(msg("""
        {"session_id":"s2","cwd":"/w/blog","hook_event_name":"PreToolUse","tool_name":"Bash",
         "tool_input":{"command":"rm -rf build"},"hinomi_mode":"ask","hinomi_request_id":"r9","hinomi_wait_seconds":15}
        """))
        XCTAssertEqual(effect, .permissionRequested)
        let session = store.session(id: "s2")
        XCTAssertEqual(session?.state, .awaitingPermission)
        XCTAssertEqual(session?.pending?.requestID, "r9")
        XCTAssertEqual(session?.pending?.summary, "Bash: rm -rf build")
        XCTAssertEqual(session?.pending?.expiresAt, base.addingTimeInterval(15))
        XCTAssertEqual(session?.pending?.remainingSeconds(now: base.addingTimeInterval(5)), 10)
    }

    func testUserPromptBecomesTitle() {
        let store = SessionStore()
        store.apply(msg(#"{"session_id":"s1","cwd":"/w/hinomi","hook_event_name":"UserPromptSubmit","prompt":"ノッチの位置を直して\nお願い"}"#))
        XCTAssertEqual(store.session(id: "s1")?.title, "ノッチの位置を直して お願い")
        // 次のプロンプトで上書き（＝いまのタスクを示す）
        store.apply(msg(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"タイトルを表示して"}"#, offset: 1))
        XCTAssertEqual(store.session(id: "s1")?.title, "タイトルを表示して")
        // prompt の無いイベントではタイトルを消さない
        store.apply(msg(#"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"できました"}"#, offset: 2))
        XCTAssertEqual(store.session(id: "s1")?.title, "タイトルを表示して")
    }

    func testPermissionRequestAskCreatesPending() {
        let store = SessionStore()
        // 実際に許可を聞かれる場面でだけ発火する PermissionRequest が ask の正
        let effect = store.apply(msg("""
        {"session_id":"s6","hook_event_name":"PermissionRequest","tool_name":"WebFetch",
         "tool_input":{"url":"https://example.com"},"hinomi_mode":"ask","hinomi_request_id":"r10","hinomi_wait_seconds":15}
        """))
        XCTAssertEqual(effect, .permissionRequested)
        XCTAssertEqual(store.session(id: "s6")?.state, .awaitingPermission)
        XCTAssertEqual(store.session(id: "s6")?.pending?.requestID, "r10")
    }

    func testAppTitleWinsOverPromptTitle() {
        let store = SessionStore()
        store.apply(msg(#"{"session_id":"cli-1","cwd":"/w/jinsei","hook_event_name":"UserPromptSubmit","prompt":"変更した"}"#))
        XCTAssertEqual(store.session(id: "cli-1")?.displayTitle, "変更した")
        XCTAssertTrue(store.setAppTitles(["cli-1": "hinomi の改修"]))
        XCTAssertEqual(store.session(id: "cli-1")?.displayTitle, "hinomi の改修")
        // 同じ内容なら「変化なし」
        XCTAssertFalse(store.setAppTitles(["cli-1": "hinomi の改修"]))
    }

    func testTitleLookupReadsDesktopSessionFiles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hinomi-title-tests-\(UUID().uuidString)/a/b")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        try Data(#"{"sessionId":"local_x","cliSessionId":"cli-9","title":"買い物リスト整理"}"#.utf8)
            .write(to: dir.appendingPathComponent("local_x.json"))
        try Data(#"{"cliSessionId":"","title":"無視される"}"#.utf8)
            .write(to: dir.appendingPathComponent("local_y.json"))
        let lookup = SessionTitleLookup(rootURL: dir.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(lookup.titlesByCLISessionID(), ["cli-9": "買い物リスト整理"])
    }

    func testEventModePreToolUseDoesNotCreatePending() {
        let store = SessionStore()
        let effect = store.apply(msg(#"{"session_id":"s3","hook_event_name":"PreToolUse","tool_name":"Read","hinomi_mode":"event"}"#))
        XCTAssertEqual(effect, .none)
        XCTAssertEqual(store.session(id: "s3")?.state, .working)
        XCTAssertNil(store.session(id: "s3")?.pending)
    }

    func testClearPending() {
        let store = SessionStore()
        store.apply(msg(#"{"session_id":"s4","hook_event_name":"PreToolUse","tool_name":"Bash","hinomi_mode":"ask"}"#))
        store.clearPending(sessionID: "s4", newState: .working)
        XCTAssertNil(store.session(id: "s4")?.pending)
        XCTAssertEqual(store.session(id: "s4")?.state, .working)
    }

    func testRemoveSingleSession() {
        let store = SessionStore()
        store.apply(msg(#"{"session_id":"keep","hook_event_name":"UserPromptSubmit"}"#))
        store.apply(msg(#"{"session_id":"gone","hook_event_name":"Stop"}"#, offset: 1))

        XCTAssertTrue(store.remove(sessionID: "gone"))
        XCTAssertNil(store.session(id: "gone"))
        XCTAssertNotNil(store.session(id: "keep"))
        XCTAssertEqual(store.count, 1)
        // 居ないものを消しても壊れない
        XCTAssertFalse(store.remove(sessionID: "gone"))
        XCTAssertFalse(store.remove(sessionID: "知らない"))
    }

    func testTidyExpiresPendingAndDropsOldSessions() {
        let store = SessionStore()
        store.apply(msg(#"{"session_id":"a","hook_event_name":"PreToolUse","tool_name":"Bash","hinomi_mode":"ask","hinomi_request_id":"rr","hinomi_wait_seconds":10}"#))
        store.apply(msg(#"{"session_id":"b","hook_event_name":"Stop"}"#))

        // 期限前は何も起きない
        XCTAssertEqual(store.tidy(now: base.addingTimeInterval(5), doneRetention: 1800), [])
        XCTAssertNotNil(store.session(id: "a")?.pending)

        // 期限後は pending を畳んで requestID を返す
        XCTAssertEqual(store.tidy(now: base.addingTimeInterval(11), doneRetention: 1800), ["rr"])
        XCTAssertNil(store.session(id: "a")?.pending)
        XCTAssertEqual(store.session(id: "a")?.state, .working)

        // 完了セッションは保持時間を過ぎたら消える
        store.tidy(now: base.addingTimeInterval(3600), doneRetention: 1800)
        XCTAssertNil(store.session(id: "b"))
        XCTAssertNotNil(store.session(id: "a"))

        // 古すぎるセッションも消える
        store.tidy(now: base.addingTimeInterval(13 * 3600), doneRetention: 1800)
        XCTAssertNil(store.session(id: "a"))
    }

    func testOrderingPutsWaitingFirst() {
        let store = SessionStore()
        store.apply(msg(#"{"session_id":"working","hook_event_name":"UserPromptSubmit"}"#, offset: 10))
        store.apply(msg(#"{"session_id":"done","hook_event_name":"Stop"}"#, offset: 20))
        store.apply(msg(#"{"session_id":"perm","hook_event_name":"PreToolUse","tool_name":"Bash","hinomi_mode":"ask"}"#, offset: 1))
        store.apply(msg(#"{"session_id":"input","hook_event_name":"Notification","notification_type":"agent_needs_input"}"#, offset: 2))

        XCTAssertEqual(store.ordered.map(\.id), ["perm", "input", "working", "done"])
        XCTAssertEqual(store.busyCount, 3)
    }

    func testCwdAndTerminalAreRememberedAcrossEvents() {
        let store = SessionStore()
        store.apply(msg(#"{"session_id":"s","cwd":"/w/hinomi","hook_event_name":"SessionStart","hinomi_term_program":"ghostty","hinomi_tty":"/dev/ttys003"}"#))
        // 後続イベントに cwd / term / tty が無くても保持される
        store.apply(msg(#"{"session_id":"s","hook_event_name":"Stop"}"#, offset: 1))
        XCTAssertEqual(store.session(id: "s")?.projectName, "hinomi")
        XCTAssertEqual(store.session(id: "s")?.termProgram, "ghostty")
        XCTAssertEqual(store.session(id: "s")?.tty, "/dev/ttys003")
    }
}
