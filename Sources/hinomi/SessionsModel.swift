import AppKit
import Combine
import HinomiCore

/// SessionStore（純粋モデル）を SwiftUI に流すための薄いラッパ。main スレッド専用。
final class SessionsModel: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var now: Date = Date()
    @Published var expanded: Bool = false
    /// 直近のイベントで光らせるセッション
    @Published private(set) var highlighted: String?

    let config: HinomiConfig

    /// 音・自動展開のトリガ
    var onEffect: ((SessionEffect, SessionInfo?) -> Void)?
    /// セッション一覧が変わった（ウィンドウの大きさ・表示可否を見直す）
    var onChange: (() -> Void)?

    private let store = SessionStore()
    private var answerHandlers: [String: (PermissionAnswer) -> Void] = [:]
    private var highlightClearWork: DispatchWorkItem?

    init(config: HinomiConfig) {
        self.config = config
    }

    var busyCount: Int { store.busyCount }

    /// socket から届いたメッセージを反映する（main スレッドで呼ばれる）
    func handle(_ message: HookMessage, respond: @escaping (PermissionAnswer) -> Void) {
        if message.mode == .ask {
            if message.isAutoApprovedByPermissionMode {
                // 自動許可モード（bypassPermissions / acceptEdits の編集系）は端末でも聞かれない。
                // 即「decision なし」を返してフックを待たせず、通常フローに流す。
                respond(.none)
            } else {
                answerHandlers[message.requestID] = respond
            }
        }
        let effect = store.apply(message)
        if effect != .none {
            highlight(sessionID: message.sessionID)
        }
        refresh()
        if effect != .none {
            onEffect?(effect, store.session(id: message.sessionID))
        }
    }

    /// notch の Allow / Deny が押された
    func answer(session: SessionInfo, with answer: PermissionAnswer) {
        guard let pending = session.pending else { return }
        answerHandlers.removeValue(forKey: pending.requestID)?(answer)
        store.clearPending(sessionID: session.id, newState: answer == .allow ? .working : .idle)
        refresh()
    }

    /// 行クリックでターミナルへ跳ぶ
    func jump(to session: SessionInfo) {
        _ = TerminalJump.activate(termProgram: session.termProgram)
    }

    /// 毎秒の更新（経過時間の再描画・期限切れの掃除）
    func tick() {
        now = Date()
        let expired = store.tidy(now: now, doneRetention: config.doneRetentionMinutes * 60)
        for requestID in expired {
            // 期限切れ = 決めなかった。フック側にも「decision なし」を返す
            answerHandlers.removeValue(forKey: requestID)?(.none)
        }
        refresh()
    }

    func clearAll() {
        store.removeAll()
        answerHandlers.removeAll()
        refresh()
    }

    private func highlight(sessionID: String) {
        highlighted = sessionID
        highlightClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.highlighted = nil
        }
        highlightClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func refresh() {
        let updated = store.ordered
        if updated != sessions {
            sessions = updated
            onChange?()
        }
    }
}
