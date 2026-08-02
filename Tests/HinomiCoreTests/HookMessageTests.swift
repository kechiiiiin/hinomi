import XCTest
@testable import HinomiCore

/// 公式仕様（https://code.claude.com/docs/en/hooks）の stdin JSON 形に沿ったサンプルでパースを検証する。
final class HookMessageTests: XCTestCase {

    private func message(_ json: String) -> HookMessage? {
        HookMessage(jsonData: Data(json.utf8))
    }

    func testSessionStartParsing() throws {
        let json = """
        {
          "session_id": "abc123",
          "transcript_path": "/tmp/t.jsonl",
          "cwd": "/Users/k/work/hinomi",
          "permission_mode": "default",
          "hook_event_name": "SessionStart",
          "source": "startup",
          "hinomi_mode": "event",
          "hinomi_request_id": "req-1",
          "hinomi_term_program": "iTerm.app"
        }
        """
        let m = try XCTUnwrap(message(json))
        XCTAssertEqual(m.kind, .sessionStart)
        XCTAssertEqual(m.mode, .event)
        XCTAssertEqual(m.sessionID, "abc123")
        XCTAssertEqual(m.projectName, "hinomi")
        XCTAssertEqual(m.source, "startup")
        XCTAssertEqual(m.permissionMode, "default")
        XCTAssertEqual(m.termProgram, "iTerm.app")
        XCTAssertEqual(m.requestID, "req-1")
    }

    func testPreToolUseBashParsing() throws {
        let json = """
        {
          "session_id": "s1",
          "cwd": "/Users/k/work/astro-blog",
          "hook_event_name": "PreToolUse",
          "tool_name": "Bash",
          "tool_use_id": "toolu_01",
          "tool_input": { "command": "npm   run\\nbuild", "description": "build" },
          "hinomi_mode": "ask",
          "hinomi_wait_seconds": 20
        }
        """
        let m = try XCTUnwrap(message(json))
        XCTAssertEqual(m.kind, .preToolUse)
        XCTAssertEqual(m.mode, .ask)
        XCTAssertEqual(m.toolName, "Bash")
        XCTAssertEqual(m.waitSeconds, 20)
        // 改行・連続空白は潰して1行サマリにする
        XCTAssertEqual(m.toolSummary, "Bash: npm run build")
        XCTAssertEqual(m.projectName, "astro-blog")
    }

    func testPreToolUseEditUsesFileBasename() throws {
        let json = """
        {
          "session_id": "s1",
          "hook_event_name": "PreToolUse",
          "tool_name": "Edit",
          "tool_input": { "file_path": "/Users/k/work/hinomi/Sources/hinomi/main.swift" },
          "hinomi_mode": "ask"
        }
        """
        let m = try XCTUnwrap(message(json))
        XCTAssertEqual(m.toolSummary, "Edit: main.swift")
        XCTAssertEqual(m.projectName, "(不明)")   // cwd 無し
    }

    func testNotificationPermissionDetection() throws {
        let permission = try XCTUnwrap(message("""
        {"session_id":"s","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}
        """))
        XCTAssertTrue(permission.isPermissionNotification)
        XCTAssertFalse(permission.isInputNotification)

        let idle = try XCTUnwrap(message("""
        {"session_id":"s","hook_event_name":"Notification","notification_type":"idle_prompt","message":"待っています"}
        """))
        XCTAssertFalse(idle.isPermissionNotification)
        XCTAssertTrue(idle.isInputNotification)

        let other = try XCTUnwrap(message("""
        {"session_id":"s","hook_event_name":"Notification","notification_type":"auth_success","message":"ok"}
        """))
        XCTAssertFalse(other.isPermissionNotification)
        XCTAssertFalse(other.isInputNotification)
    }

    func testStopAndSessionEndParsing() throws {
        let stop = try XCTUnwrap(message("""
        {"session_id":"s","hook_event_name":"Stop","stop_reason":"end_turn","last_assistant_message":"やりました"}
        """))
        XCTAssertEqual(stop.kind, .stop)
        XCTAssertEqual(stop.message, "やりました")

        let end = try XCTUnwrap(message("""
        {"session_id":"s","hook_event_name":"SessionEnd","end_reason":"logout"}
        """))
        XCTAssertEqual(end.kind, .sessionEnd)
        XCTAssertEqual(end.endReason, "logout")
    }

    func testUnknownEventStillParses() throws {
        let m = try XCTUnwrap(message(#"{"session_id":"s","hook_event_name":"PostCompact","trigger":"auto"}"#))
        XCTAssertEqual(m.kind, .other)
        XCTAssertEqual(m.hookEventName, "PostCompact")
        XCTAssertEqual(m.waitSeconds, HinomiConfig.default.permissionWaitSeconds)
    }

    func testMissingSessionIDFallsBack() throws {
        let m = try XCTUnwrap(message(#"{"hook_event_name":"Stop"}"#))
        XCTAssertEqual(m.sessionID, "unknown")
    }

    func testRejectsNonHookJSON() {
        XCTAssertNil(message(#"{"hello":"world"}"#))
        XCTAssertNil(HookMessage(jsonData: Data("not json".utf8)))
        XCTAssertNil(HookMessage(jsonData: Data("[1,2,3]".utf8)))
    }

    func testToolInputWrongTypeIsTolerated() throws {
        let m = try XCTUnwrap(message(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":"oops"}"#))
        XCTAssertEqual(m.toolSummary, "Bash")
    }

    func testCondensedTruncates() {
        let long = String(repeating: "a", count: 200)
        let result = HookMessage.condensed(long, limit: 20)
        XCTAssertEqual(result.count, 20)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testElapsedText() {
        XCTAssertEqual(SessionInfo.elapsedText(seconds: 5), "5秒")
        XCTAssertEqual(SessionInfo.elapsedText(seconds: 125), "2分")
        XCTAssertEqual(SessionInfo.elapsedText(seconds: 7300), "2時間")
        XCTAssertEqual(SessionInfo.elapsedText(seconds: 200_000), "2日")
    }
}
