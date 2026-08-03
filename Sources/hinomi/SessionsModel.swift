import AppKit
import Combine
import HinomiCore

/// SessionStore（純粋モデル）を SwiftUI に流すための薄いラッパ。main スレッド専用。
final class SessionsModel: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var now: Date = Date()
    @Published var expanded: Bool = false
    /// ピン留め中は、ホバーが外れてもイベント後も畳まない（永続化しない＝再起動で解除）
    @Published var pinned: Bool = false
    /// 直近のイベントで光らせるセッション
    @Published private(set) var highlighted: String?
    /// transcript から数えたトークン使用量（60秒ごとに background で更新）
    @Published private(set) var usage: UsageTotals = .zero

    let config: HinomiConfig

    /// 音・自動展開のトリガ
    var onEffect: ((SessionEffect, SessionInfo?) -> Void)?
    /// セッション一覧が変わった（ウィンドウの大きさ・表示可否を見直す）
    var onChange: (() -> Void)?

    private let store = SessionStore()
    private var answerHandlers: [String: (PermissionAnswer) -> Void] = [:]
    private var highlightClearWork: DispatchWorkItem?
    private let titleLookup = SessionTitleLookup()
    private var lastTitleRefresh = Date.distantPast
    /// UsageTracker はスレッドセーフではないので、このキューの中だけで触る
    private let usageTracker = UsageTracker()
    private let usageQueue = DispatchQueue(label: "app.hinomi.usage", qos: .utility)
    private var lastUsageRefresh = Date.distantPast
    private var usageRefreshing = false

    init(config: HinomiConfig) {
        self.config = config
    }

    var busyCount: Int { store.busyCount }

    /// socket から届いたメッセージを反映する（main スレッドで呼ばれる）
    func handle(_ message: HookMessage, respond: @escaping (PermissionAnswer) -> Void) {
        if message.mode == .ask {
            answerHandlers[message.requestID] = respond
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

    /// 行クリックでターミナルへ跳ぶ（tty が分かっていればタブ／ペインまで）
    func jump(to session: SessionInfo) {
        _ = TerminalJump.activate(termProgram: session.termProgram, tty: session.tty)
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
        refreshAppTitlesIfNeeded()
        refreshUsageIfNeeded()
    }

    /// 使用量の集計は 60 秒ごと・background で。初回の全走査も含めて UI を待たせない
    private func refreshUsageIfNeeded() {
        guard config.usageEnabled, !usageRefreshing,
              Date().timeIntervalSince(lastUsageRefresh) > 60 else { return }
        lastUsageRefresh = Date()
        usageRefreshing = true
        usageQueue.async { [weak self] in
            guard let self else { return }
            let totals = self.usageTracker.refresh()
            DispatchQueue.main.async {
                self.usageRefreshing = false
                if self.usage != totals { self.usage = totals }
            }
        }
    }

    /// デスクトップアプリのセッションタイトルを定期的に引き直す（ファイル数十件の走査なので軽い）
    private func refreshAppTitlesIfNeeded() {
        guard !store.ordered.isEmpty,
              Date().timeIntervalSince(lastTitleRefresh) > 15 else { return }
        lastTitleRefresh = Date()
        let lookup = titleLookup
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let titles = lookup.titlesByCLISessionID()
            guard !titles.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.store.setAppTitles(titles) { self.refresh() }
            }
        }
    }

    /// 完了・待機の行の × が押された（見終わったものを1件だけ片付ける）
    func remove(session: SessionInfo) {
        // 許可待ちのまま消すとフック側が待ち続けるので、先に「決めなかった」を返す
        if let pending = session.pending {
            answerHandlers.removeValue(forKey: pending.requestID)?(.none)
        }
        store.remove(sessionID: session.id)
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
