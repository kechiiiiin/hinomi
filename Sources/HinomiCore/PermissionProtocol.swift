import Foundation

/// notch でのユーザー判断。`none` は「無応答＝通常の端末フローに任せる」。
public enum PermissionAnswer: String, Equatable {
    case allow
    case deny
    case none
}

/// アプリ → hinomi-hook に返す1行 JSON。
public struct PermissionReply: Equatable {
    public var answer: PermissionAnswer
    public var reason: String?

    public init(answer: PermissionAnswer, reason: String? = nil) {
        self.answer = answer
        self.reason = reason
    }

    public func encoded() -> Data {
        var object: [String: Any] = ["decision": answer.rawValue]
        if let reason { object["reason"] = reason }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return data + Data("\n".utf8)
    }

    public init?(data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["decision"] as? String,
              let answer = PermissionAnswer(rawValue: raw) else { return nil }
        self.answer = answer
        self.reason = object["reason"] as? String
    }
}

/// hinomi-hook が stdout に出す Claude Code 向け JSON を組み立てる。
///
/// 公式仕様（https://code.claude.com/docs/en/hooks）:
/// - PermissionRequest Decision Control: `hookSpecificOutput.decision.behavior` に allow / deny
/// - PreToolUse Decision Control: `hookSpecificOutput.permissionDecision` に allow / deny / ask / defer
/// 無応答のときは **何も出力せず exit 0**（＝decision なし）とし、通常の許可フローに戻す。
public enum HookOutput {
    /// PermissionRequest 用。実際に許可を聞かれている場面での decision。
    public static func permissionRequestJSON(answer: PermissionAnswer) -> String? {
        guard answer != .none else { return nil }
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": answer.rawValue],
            ],
            "suppressOutput": true,
        ]
        return encode(object)
    }

    /// PreToolUse 用（旧方式の互換。settings.json に旧エントリが残っていても壊れないように）。
    public static func preToolUseJSON(answer: PermissionAnswer, reason: String) -> String? {
        guard answer != .none else { return nil }
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": answer.rawValue,
                "permissionDecisionReason": reason,
            ],
            "suppressOutput": true,
        ]
        return encode(object)
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
