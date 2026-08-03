import XCTest
@testable import HinomiCore

final class TerminalJumpScriptTests: XCTestCase {
    private let iterm = "com.googlecode.iterm2"
    private let terminal = "com.apple.Terminal"

    func testITermScriptWalksSessionsAndSelects() throws {
        let script = try XCTUnwrap(TerminalJumpScript.script(bundleID: iterm, tty: "/dev/ttys003"))
        XCTAssertTrue(script.contains(#"tell application "iTerm2""#))
        XCTAssertTrue(script.contains("sessions of t"))
        XCTAssertTrue(script.contains(#"if tty of s is "/dev/ttys003" then"#))
        // window / tab / session を全部選んでから前面に出す
        XCTAssertTrue(script.contains("select w"))
        XCTAssertTrue(script.contains("select t"))
        XCTAssertTrue(script.contains("select s"))
        XCTAssertTrue(script.contains("activate"))
        // 見つかったかどうかを呼び出し側が判定できる
        XCTAssertTrue(script.contains("return true"))
        XCTAssertTrue(script.contains("return false"))
    }

    func testTerminalAppScriptSelectsTab() throws {
        let script = try XCTUnwrap(TerminalJumpScript.script(bundleID: terminal, tty: "/dev/ttys012"))
        XCTAssertTrue(script.contains(#"tell application "Terminal""#))
        XCTAssertTrue(script.contains(#"if tty of t is "/dev/ttys012" then"#))
        XCTAssertTrue(script.contains("set selected tab of w to t"))
        XCTAssertTrue(script.contains("set frontmost of w to true"))
    }

    func testAppleScriptUnsupportedTerminalsReturnNil() {
        for bundleID in ["com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
                         "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.warp.Warp-Stable"] {
            XCTAssertNil(TerminalJumpScript.script(bundleID: bundleID, tty: "/dev/ttys003"), bundleID)
        }
    }

    func testTTYValidation() {
        XCTAssertTrue(TerminalJumpScript.isPlausibleTTY("/dev/ttys003"))
        XCTAssertTrue(TerminalJumpScript.isPlausibleTTY("/dev/ttyp0"))
        XCTAssertFalse(TerminalJumpScript.isPlausibleTTY(""))
        XCTAssertFalse(TerminalJumpScript.isPlausibleTTY("/dev/null"))
        XCTAssertFalse(TerminalJumpScript.isPlausibleTTY("ttys003"))
        // 引用符・スペース・記号が混ざったものは通さない
        XCTAssertFalse(TerminalJumpScript.isPlausibleTTY(#"/dev/ttys003" & (do shell script "id")"#))
        XCTAssertFalse(TerminalJumpScript.isPlausibleTTY("/dev/ttys003; echo"))
        XCTAssertFalse(TerminalJumpScript.isPlausibleTTY("/dev/tty" + String(repeating: "s", count: 40)))
    }

    func testInjectionAttemptsAreRejectedBeforeBuilding() {
        // 危ない値はスクリプトを組み立てる前に弾く（二重の守り）
        XCTAssertNil(TerminalJumpScript.script(bundleID: iterm, tty: #"/dev/ttys003" & (do shell script "touch /tmp/pwn") & ""#))
        XCTAssertNil(TerminalJumpScript.script(bundleID: terminal, tty: #"a" or true or ""#))
    }

    func testEscapedLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(TerminalJumpScript.escapedLiteral("plain"), "plain")
        XCTAssertEqual(TerminalJumpScript.escapedLiteral(#"say "hi""#), #"say \"hi\""#)
        // バックスラッシュを先に潰すので、\" が \\\" になる（\ の後の " が生きない）
        XCTAssertEqual(TerminalJumpScript.escapedLiteral(#"a\"b"#), #"a\\\"b"#)
        XCTAssertEqual(TerminalJumpScript.escapedLiteral(#"c:\path"#), #"c:\\path"#)
    }
}

final class ControllingTTYTests: XCTestCase {
    func testCurrentReturnsNilOrPlausiblePath() {
        // CI・デスクトップアプリ起動では端末が無いので nil。取れた場合は形が正しいこと
        if let tty = ControllingTTY.current() {
            XCTAssertTrue(TerminalJumpScript.isPlausibleTTY(tty), tty)
        }
    }

    func testUnknownPidReturnsNil() {
        // 居ない pid を渡しても落ちない（fail-open）
        XCTAssertNil(ControllingTTY.current(startingAt: 999_999))
        XCTAssertNil(ControllingTTY.current(startingAt: getpid(), maxDepth: 0))
    }
}
