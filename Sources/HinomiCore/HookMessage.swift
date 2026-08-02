import Foundation

/// hinomi-hook がアプリに送るときのモード。
/// - event: 投げっぱなし（応答を待たない）
/// - ask:  PreToolUse の許可判断を notch に問い合わせ、応答を待つ
public enum HookMessageMode: String, Equatable {
    case event
    case ask
}

/// Claude Code の hook イベント種別（hinomi が扱うものだけ列挙）。
public enum HookEventKind: String, Equatable {
    case sessionStart
    case userPromptSubmit
    case preToolUse
    case postToolUse
    case notification
    case stop
    case subagentStop
    case sessionEnd
    case other

    public init(hookEventName: String) {
        switch hookEventName {
        case "SessionStart": self = .sessionStart
        case "UserPromptSubmit": self = .userPromptSubmit
        case "PreToolUse", "PermissionRequest": self = .preToolUse
        case "PostToolUse", "PostToolUseFailure", "PostToolBatch": self = .postToolUse
        case "Notification": self = .notification
        case "Stop", "StopFailure": self = .stop
        case "SubagentStop": self = .subagentStop
        case "SessionEnd": self = .sessionEnd
        default: self = .other
        }
    }
}

/// socket 経由で受け取る1メッセージ。
/// Claude Code の hook JSON（stdin）に hinomi-hook が envelope フィールドを足したもの。
public struct HookMessage: Equatable {
    public var mode: HookMessageMode
    public var requestID: String
    public var hookEventName: String
    public var kind: HookEventKind
    public var sessionID: String
    public var cwd: String?
    public var termProgram: String?
    public var termSessionID: String?
    public var toolName: String?
    public var toolCommand: String?
    public var toolFilePath: String?
    public var notificationType: String?
    public var message: String?
    public var source: String?
    public var endReason: String?
    public var permissionMode: String?
    public var waitSeconds: Double
    public var receivedAt: Date

    public init?(jsonData: Data, now: Date = Date()) {
        guard let object = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return nil
        }
        self.init(object: object, now: now)
    }

    public init?(object: [String: Any], now: Date = Date()) {
        let eventName = HookMessage.string(object, "hook_event_name")
        let modeRaw = HookMessage.string(object, "hinomi_mode")
        // hook イベント名も hinomi のモードも無いものは、hinomi 宛のメッセージとして扱わない
        if eventName == nil && modeRaw == nil { return nil }

        hookEventName = eventName ?? "Unknown"
        kind = HookEventKind(hookEventName: hookEventName)
        mode = HookMessageMode(rawValue: modeRaw ?? "event") ?? .event
        requestID = HookMessage.string(object, "hinomi_request_id") ?? UUID().uuidString
        sessionID = HookMessage.string(object, "session_id")
            ?? HookMessage.string(object, "hinomi_term_session_id")
            ?? "unknown"
        cwd = HookMessage.string(object, "cwd")
        termProgram = HookMessage.string(object, "hinomi_term_program")
        termSessionID = HookMessage.string(object, "hinomi_term_session_id")
        notificationType = HookMessage.string(object, "notification_type")
        message = HookMessage.string(object, "message")
            ?? HookMessage.string(object, "last_assistant_message")
        source = HookMessage.string(object, "source")
        endReason = HookMessage.string(object, "end_reason")
        permissionMode = HookMessage.string(object, "permission_mode")
        toolName = HookMessage.string(object, "tool_name")
        if let input = object["tool_input"] as? [String: Any] {
            toolCommand = HookMessage.string(input, "command")
            toolFilePath = HookMessage.string(input, "file_path")
                ?? HookMessage.string(input, "notebook_path")
        } else {
            toolCommand = nil
            toolFilePath = nil
        }
        waitSeconds = HookMessage.double(object, "hinomi_wait_seconds") ?? HinomiConfig.default.permissionWaitSeconds
        receivedAt = now
    }

    // MARK: - 派生プロパティ

    /// cwd の basename。無ければ "(不明)"
    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "(不明)" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// 「Bash: npm test」「Edit: index.ts」のような1行サマリ
    public var toolSummary: String? {
        guard let toolName, !toolName.isEmpty else { return nil }
        if let toolCommand, !toolCommand.isEmpty {
            return "\(toolName): \(HookMessage.condensed(toolCommand, limit: 72))"
        }
        if let toolFilePath, !toolFilePath.isEmpty {
            return "\(toolName): \(URL(fileURLWithPath: toolFilePath).lastPathComponent)"
        }
        return toolName
    }

    /// Notification のうち、許可を求めているもの
    public var isPermissionNotification: Bool {
        guard kind == .notification else { return false }
        if let notificationType, notificationType.lowercased().contains("permission") { return true }
        guard let message = message?.lowercased() else { return false }
        return message.contains("permission") || message.contains("approve")
    }

    /// Notification のうち、ユーザーの入力待ちを示すもの
    public var isInputNotification: Bool {
        guard kind == .notification, !isPermissionNotification else { return false }
        guard let notificationType else { return false }
        return notificationType == "idle_prompt"
            || notificationType == "agent_needs_input"
            || notificationType.contains("input")
    }

    // MARK: - パースヘルパ

    static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func double(_ object: [String: Any], _ key: String) -> Double? {
        guard let value = object[key] else { return nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// 改行と連続空白を潰して、長すぎる文字列を切る
    static func condensed(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}
