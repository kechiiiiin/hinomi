import Foundation

public enum SessionState: String, Equatable {
    case awaitingPermission
    case awaitingInput
    case working
    case done
    case idle

    public var label: String {
        switch self {
        case .awaitingPermission: return "許可待ち"
        case .awaitingInput: return "入力待ち"
        case .working: return "実行中"
        case .done: return "完了"
        case .idle: return "待機"
        }
    }

    /// 一覧の並び順（小さいほど上）
    public var sortRank: Int {
        switch self {
        case .awaitingPermission: return 0
        case .awaitingInput: return 1
        case .working: return 2
        case .done: return 3
        case .idle: return 4
        }
    }
}

/// notch に Allow/Deny を出している最中の1件。
public struct PendingPermission: Equatable {
    public var requestID: String
    public var toolName: String
    public var summary: String
    public var requestedAt: Date
    public var expiresAt: Date

    public init(requestID: String, toolName: String, summary: String, requestedAt: Date, expiresAt: Date) {
        self.requestID = requestID
        self.toolName = toolName
        self.summary = summary
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }

    public func remainingSeconds(now: Date = Date()) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
    }
}

public struct SessionInfo: Identifiable, Equatable {
    public var id: String
    public var cwd: String?
    public var projectName: String
    public var termProgram: String?
    public var state: SessionState
    public var activity: String
    public var startedAt: Date
    public var lastEventAt: Date
    public var pending: PendingPermission?

    public func elapsedText(now: Date = Date()) -> String {
        SessionInfo.elapsedText(seconds: now.timeIntervalSince(lastEventAt))
    }

    public static func elapsedText(seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)秒" }
        if s < 3600 { return "\(s / 60)分" }
        if s < 86400 { return "\(s / 3600)時間" }
        return "\(s / 86400)日"
    }
}

/// 状態変化のうち、音・自動展開に値するもの。
public enum SessionEffect: Equatable {
    case none
    case finished
    case permissionRequested
    case inputNeeded
}

/// セッション一覧の純粋なモデル（Foundation のみ）。UI からは main スレッドで触る前提。
public final class SessionStore {
    private var storage: [String: SessionInfo] = [:]

    public init() {}

    public var ordered: [SessionInfo] {
        storage.values.sorted { lhs, rhs in
            if lhs.state.sortRank != rhs.state.sortRank {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            if lhs.lastEventAt != rhs.lastEventAt {
                return lhs.lastEventAt > rhs.lastEventAt
            }
            return lhs.id < rhs.id
        }
    }

    public var count: Int { storage.count }

    /// 完了・待機以外（＝今動いている、あるいは人を待たせている）数
    public var busyCount: Int {
        storage.values.filter { $0.state == .working || $0.state == .awaitingInput || $0.state == .awaitingPermission }.count
    }

    public func session(id: String) -> SessionInfo? { storage[id] }

    @discardableResult
    public func apply(_ message: HookMessage) -> SessionEffect {
        let now = message.receivedAt

        if message.kind == .sessionEnd {
            storage.removeValue(forKey: message.sessionID)
            return .none
        }

        var info = storage[message.sessionID] ?? SessionInfo(
            id: message.sessionID,
            cwd: message.cwd,
            projectName: message.projectName,
            termProgram: message.termProgram,
            state: .idle,
            activity: "セッション開始",
            startedAt: now,
            lastEventAt: now,
            pending: nil
        )

        if let cwd = message.cwd, !cwd.isEmpty {
            info.cwd = cwd
            info.projectName = message.projectName
        }
        if let term = message.termProgram, !term.isEmpty {
            info.termProgram = term
        }
        info.lastEventAt = now

        let previousState = info.state
        var effect = SessionEffect.none

        switch message.kind {
        case .sessionStart:
            info.state = .idle
            info.activity = "セッション開始"
            info.pending = nil

        case .userPromptSubmit:
            info.state = .working
            info.activity = "指示を処理中"
            info.pending = nil

        case .preToolUse:
            if message.mode == .ask {
                let summary = message.toolSummary ?? (message.toolName ?? "ツール")
                info.pending = PendingPermission(
                    requestID: message.requestID,
                    toolName: message.toolName ?? "ツール",
                    summary: summary,
                    requestedAt: now,
                    expiresAt: now.addingTimeInterval(max(1, message.waitSeconds))
                )
                info.state = .awaitingPermission
                info.activity = summary
                effect = .permissionRequested
            } else {
                info.state = .working
                info.activity = message.toolSummary ?? "ツール実行中"
            }

        case .postToolUse:
            if info.state != .awaitingPermission {
                info.state = .working
            }
            info.activity = message.toolSummary ?? info.activity

        case .notification:
            if message.isPermissionNotification {
                info.state = .awaitingPermission
                info.activity = message.message.map { HookMessage.condensed($0, limit: 72) } ?? "許可を求めています"
                effect = .permissionRequested
            } else if message.isInputNotification {
                info.state = .awaitingInput
                info.activity = message.message.map { HookMessage.condensed($0, limit: 72) } ?? "入力を待っています"
                if previousState != .awaitingInput { effect = .inputNeeded }
            } else if let text = message.message {
                info.activity = HookMessage.condensed(text, limit: 72)
            }

        case .stop:
            info.state = .done
            info.pending = nil
            info.activity = message.message.map { HookMessage.condensed($0, limit: 72) } ?? "完了"
            effect = .finished

        case .subagentStop:
            info.activity = "サブエージェント完了"

        case .sessionEnd, .other:
            break
        }

        storage[message.sessionID] = info
        return effect
    }

    /// notch でクリックされた／期限切れになったので Allow/Deny 表示を下げる。
    public func clearPending(sessionID: String, newState: SessionState?) {
        guard var info = storage[sessionID] else { return }
        info.pending = nil
        if let newState { info.state = newState }
        storage[sessionID] = info
    }

    /// 期限切れの許可待ちを畳み、古いセッションを掃除する。
    /// 戻り値は「期限切れになった pending の requestID 一覧」。
    @discardableResult
    public func tidy(now: Date = Date(), doneRetention: TimeInterval = 30 * 60,
                     staleAfter: TimeInterval = 12 * 3600) -> [String] {
        var expired: [String] = []
        for (id, var info) in storage {
            if let pending = info.pending, pending.expiresAt <= now {
                expired.append(pending.requestID)
                info.pending = nil
                if info.state == .awaitingPermission { info.state = .working }
                storage[id] = info
            }
            if info.state == .done, now.timeIntervalSince(info.lastEventAt) > doneRetention {
                storage.removeValue(forKey: id)
                continue
            }
            if now.timeIntervalSince(info.lastEventAt) > staleAfter {
                storage.removeValue(forKey: id)
            }
        }
        return expired
    }

    public func removeAll() { storage.removeAll() }
}
