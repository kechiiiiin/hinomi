import XCTest
@testable import HinomiCore

final class HookOutputTests: XCTestCase {
    func testAllowJSONMatchesOfficialShape() throws {
        let json = try XCTUnwrap(HookOutput.preToolUseJSON(answer: .allow, reason: "notch で許可"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(specific["permissionDecision"] as? String, "allow")
        XCTAssertEqual(specific["permissionDecisionReason"] as? String, "notch で許可")
    }

    func testDenyJSON() throws {
        let json = try XCTUnwrap(HookOutput.preToolUseJSON(answer: .deny, reason: "だめ"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
    }

    func testNoneProducesNoOutput() {
        // 無応答のときは何も出さない（＝decision なしで通常フローへ）
        XCTAssertNil(HookOutput.preToolUseJSON(answer: .none, reason: "無応答"))
        XCTAssertNil(HookOutput.permissionRequestJSON(answer: .none))
    }

    func testPermissionRequestJSONMatchesOfficialShape() throws {
        // 公式: hookSpecificOutput.decision.behavior に allow / deny
        let json = try XCTUnwrap(HookOutput.permissionRequestJSON(answer: .allow))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(specific["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")

        let deny = try XCTUnwrap(HookOutput.permissionRequestJSON(answer: .deny))
        XCTAssertTrue(deny.contains(#""behavior":"deny""#))
    }

    func testPermissionReplyRoundTrip() throws {
        let reply = PermissionReply(answer: .deny, reason: "理由")
        let encoded = reply.encoded()
        XCTAssertEqual(encoded.last, 0x0A)
        let decoded = try XCTUnwrap(PermissionReply(data: encoded))
        XCTAssertEqual(decoded, reply)
        XCTAssertNil(PermissionReply(data: Data(#"{"decision":"maybe"}"#.utf8)))
        XCTAssertNil(PermissionReply(data: Data("garbage".utf8)))
    }
}

final class HookEnvelopeTests: XCTestCase {
    func testEnvelopeAddsFieldsWithoutBreakingOriginal() throws {
        let stdin = Data(#"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        let built = HookEnvelope.build(stdin: stdin,
                                      mode: .ask,
                                      config: .default,
                                      environment: ["TERM_PROGRAM": "ghostty", "TERM_SESSION_ID": "w0t1"],
                                      requestID: "req-42",
                                      now: Date(timeIntervalSince1970: 100))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: built) as? [String: Any])
        XCTAssertEqual(object["session_id"] as? String, "s1")
        XCTAssertEqual(object["hook_event_name"] as? String, "PreToolUse")
        XCTAssertNotNil(object["tool_input"] as? [String: Any])
        XCTAssertEqual(object["hinomi_mode"] as? String, "ask")
        XCTAssertEqual(object["hinomi_request_id"] as? String, "req-42")
        XCTAssertEqual(object["hinomi_term_program"] as? String, "ghostty")
        XCTAssertEqual(object["hinomi_term_session_id"] as? String, "w0t1")
        XCTAssertEqual(object["hinomi_wait_seconds"] as? Double, HinomiConfig.default.clampedPermissionWait)
        XCTAssertEqual(object["hinomi_sent_at"] as? Double, 100)

        // 組み立てたものがそのまま HookMessage に戻る
        let message = try XCTUnwrap(HookMessage(jsonData: built))
        XCTAssertEqual(message.mode, .ask)
        XCTAssertEqual(message.termProgram, "ghostty")
        XCTAssertEqual(message.requestID, "req-42")
    }

    func testEventModeOmitsWaitSeconds() throws {
        let built = HookEnvelope.build(stdin: Data(#"{"hook_event_name":"Stop"}"#.utf8),
                                      mode: .event, config: .default, environment: [:])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: built) as? [String: Any])
        XCTAssertNil(object["hinomi_wait_seconds"])
        XCTAssertNil(object["hinomi_term_program"])
    }

    func testNonJSONStdinIsWrapped() throws {
        let built = HookEnvelope.build(stdin: Data("not json at all".utf8),
                                      mode: .event, config: .default, environment: [:])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: built) as? [String: Any])
        XCTAssertEqual(object["hinomi_raw_stdin"] as? String, "not json at all")
        XCTAssertNotNil(HookMessage(jsonData: built))   // hinomi_mode があるので受け取れる
    }
}

final class HinomiConfigTests: XCTestCase {
    func testPartialConfigUsesDefaults() throws {
        let json = Data(#"{"permissionWaitSeconds": 30}"#.utf8)
        let config = try JSONDecoder().decode(HinomiConfig.self, from: json)
        XCTAssertEqual(config.permissionWaitSeconds, 30)
        XCTAssertEqual(config.doneSound, HinomiConfig.default.doneSound)
        XCTAssertEqual(config.permissionToolMatcher, HinomiConfig.default.permissionToolMatcher)
    }

    func testWaitIsClamped() {
        var config = HinomiConfig.default
        config.permissionWaitSeconds = 9999
        XCTAssertEqual(config.clampedPermissionWait, 120)
        config.permissionWaitSeconds = 0
        XCTAssertEqual(config.clampedPermissionWait, 1)
    }

    func testLoadMissingFileReturnsDefault() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nope-\(UUID().uuidString).json")
        XCTAssertEqual(HinomiConfig.load(from: missing), .default)
    }
}

final class TerminalCatalogTests: XCTestCase {
    func testKnownTerminals() {
        XCTAssertEqual(TerminalCatalog.terminal(forTermProgram: "iTerm.app")?.bundleID, "com.googlecode.iterm2")
        XCTAssertEqual(TerminalCatalog.terminal(forTermProgram: "Apple_Terminal")?.bundleID, "com.apple.Terminal")
        XCTAssertEqual(TerminalCatalog.terminal(forTermProgram: "ghostty")?.bundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(TerminalCatalog.terminal(forTermProgram: "WezTerm")?.bundleID, "com.github.wez.wezterm")
        XCTAssertEqual(TerminalCatalog.terminal(forTermProgram: "kitty")?.bundleID, "net.kovidgoyal.kitty")
        XCTAssertEqual(TerminalCatalog.shortName(forTermProgram: "iTerm.app"), "iTerm2")
    }

    func testUnknownTerminal() {
        XCTAssertNil(TerminalCatalog.terminal(forTermProgram: "tmux"))
        XCTAssertNil(TerminalCatalog.terminal(forTermProgram: nil))
        XCTAssertEqual(TerminalCatalog.shortName(forTermProgram: "SomethingNew.app"), "SomethingNew")
    }
}

/// socket の往復（サーバ起動 → クライアント送信 → 応答）を実際に通す。
final class SocketRoundTripTests: XCTestCase {
    private func tempSocketPath() -> String {
        // sockaddr_un の長さ制限があるので短いパスを使う
        "/tmp/hinomi-test-\(UUID().uuidString.prefix(8)).sock"
    }

    func testEventDelivery() throws {
        let path = tempSocketPath()
        let received = expectation(description: "event received")
        var delivered: HookMessage?

        let server = SocketServer(path: path) { message, _ in
            delivered = message
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let payload = Data(#"{"session_id":"sock1","hook_event_name":"Stop","hinomi_mode":"event"}"#.utf8)
        let result = SocketClient.send(payload, to: path, expectReply: false, timeout: 2)
        XCTAssertEqual(result, .delivered(nil))
        wait(for: [received], timeout: 5)
        XCTAssertEqual(delivered?.sessionID, "sock1")
        XCTAssertEqual(delivered?.kind, .stop)
        XCTAssertTrue(SocketClient.isAppListening(path: path))
    }

    func testAskGetsAnswer() throws {
        let path = tempSocketPath()
        let asked = expectation(description: "asked")

        let server = SocketServer(path: path) { message, respond in
            XCTAssertEqual(message.mode, .ask)
            asked.fulfill()
            respond(.deny)
        }
        try server.start()
        defer { server.stop() }

        let payload = Data("""
        {"session_id":"sock2","hook_event_name":"PreToolUse","tool_name":"Bash","hinomi_mode":"ask","hinomi_wait_seconds":5}
        """.utf8)

        var reply: PermissionReply?
        let done = expectation(description: "reply")
        DispatchQueue.global().async {
            if case .delivered(let data) = SocketClient.send(payload, to: path, expectReply: true, timeout: 8),
               let data {
                reply = PermissionReply(data: data)
            }
            done.fulfill()
        }
        wait(for: [asked, done], timeout: 10)
        XCTAssertEqual(reply?.answer, .deny)
    }

    func testAskTimesOutToNone() throws {
        let path = tempSocketPath()
        let server = SocketServer(path: path) { _, _ in /* 応答しない */ }
        try server.start()
        defer { server.stop() }

        let payload = Data("""
        {"session_id":"sock3","hook_event_name":"PreToolUse","hinomi_mode":"ask","hinomi_wait_seconds":1}
        """.utf8)

        var reply: PermissionReply?
        let done = expectation(description: "reply")
        DispatchQueue.global().async {
            if case .delivered(let data) = SocketClient.send(payload, to: path, expectReply: true, timeout: 6),
               let data {
                reply = PermissionReply(data: data)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(reply?.answer, PermissionAnswer.none)
    }

    func testClientReportsUnavailableWithoutServer() {
        let result = SocketClient.send(Data("{}".utf8),
                                       to: "/tmp/hinomi-does-not-exist-\(UUID().uuidString).sock",
                                       expectReply: true,
                                       timeout: 1)
        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(SocketClient.isAppListening(path: "/tmp/hinomi-nope.sock"))
    }
}
