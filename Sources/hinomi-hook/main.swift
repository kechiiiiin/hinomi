import Foundation
import HinomiCore

// hinomi-hook: Claude Code の hook から呼ばれる極小クライアント。
//
//   hinomi-hook event   ... stdin の hook JSON を hinomi へ投げるだけ（応答を待たない）
//   hinomi-hook ask     ... PreToolUse の許可を notch に問い合わせ、決まれば
//                           permissionDecision JSON を stdout に出す
//
// 原則: **絶対に Claude Code のセッションを壊さない**。
// アプリが居ない・socket が無い・失敗した——どの場合も exit 0 で無言終了し、通常フローに任せる。

let arguments = Array(CommandLine.arguments.dropFirst())
let modeRaw = arguments.first ?? "event"

if modeRaw == "--help" || modeRaw == "-h" {
    print("""
    usage: hinomi-hook <event|ask>

      event  stdin の hook JSON を hinomi へ送る（応答待ちなし）
      ask    PreToolUse の許可を notch に問い合わせ、決まれば decision JSON を出力する

    socket: \(HinomiPaths.socketPath)
    """)
    exit(0)
}

let mode = HookMessageMode(rawValue: modeRaw) ?? .event
let config = HinomiConfig.load()
let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let payload = HookEnvelope.build(stdin: stdinData, mode: mode, config: config)

switch mode {
case .event:
    _ = SocketClient.send(payload, expectReply: false, timeout: 2)
    exit(0)

case .ask:
    guard config.permissionPromptEnabled else { exit(0) }
    let wait = config.clampedPermissionWait
    let result = SocketClient.send(payload, expectReply: true, timeout: wait + 2)
    guard case .delivered(let reply) = result,
          let reply,
          let parsed = PermissionReply(data: reply) else {
        // 無応答 / アプリ不在 → 何も出力しない（decision なし）＝通常の許可フローへ
        exit(0)
    }
    // 出力形式はイベントで変わる。正は PermissionRequest（実際に許可を聞かれている場面のみ発火）。
    // PreToolUse は旧エントリが settings.json に残っていた場合の互換。
    let eventName = HookEnvelope.eventName(stdin: stdinData) ?? "PermissionRequest"
    let json: String?
    if eventName == "PreToolUse" {
        json = HookOutput.preToolUseJSON(
            answer: parsed.answer,
            reason: parsed.reason ?? "hinomi: notch で選択されました")
    } else {
        json = HookOutput.permissionRequestJSON(answer: parsed.answer)
    }
    if let json { print(json) }
    exit(0)
}
