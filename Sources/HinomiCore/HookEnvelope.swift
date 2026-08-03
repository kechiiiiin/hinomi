import Foundation

/// Claude Code の hook stdin JSON に、hinomi が必要な情報を足して包む。
///
/// 足すのは `hinomi_` 接頭辞のキーだけなので、元の hook JSON のフィールドは壊さない。
public enum HookEnvelope {
    /// stdin の hook JSON から hook_event_name だけを取り出す（出力形式の選択に使う）。
    public static func eventName(stdin data: Data) -> String? {
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return parsed["hook_event_name"] as? String
    }

    public static func build(stdin data: Data,
                             mode: HookMessageMode,
                             config: HinomiConfig,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             requestID: String = UUID().uuidString,
                             tty: String? = ControllingTTY.current(),
                             now: Date = Date()) -> Data {
        var object: [String: Any]
        if let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object = parsed
        } else {
            // JSON として読めなかった場合も、イベント自体は落とさず生テキストを添えて送る
            object = ["hinomi_raw_stdin": String(decoding: data, as: UTF8.self)]
        }

        object["hinomi_mode"] = mode.rawValue
        object["hinomi_request_id"] = requestID
        object["hinomi_sent_at"] = now.timeIntervalSince1970
        object["hinomi_pid"] = Int(getpid())
        if let term = environment["TERM_PROGRAM"], !term.isEmpty {
            object["hinomi_term_program"] = term
        }
        if let session = environment["TERM_SESSION_ID"], !session.isEmpty {
            object["hinomi_term_session_id"] = session
        }
        // 制御端末（タブ単位のジャンプに使う）。端末を持たない起動では単に付かない
        if let tty, !tty.isEmpty {
            object["hinomi_tty"] = tty
        }
        if mode == .ask {
            object["hinomi_wait_seconds"] = config.clampedPermissionWait
        }

        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return data
        }
        return Data(#"{"hinomi_mode":"event"}"#.utf8)
    }
}
