import AppKit
import HinomiCore
import SwiftUI

/// 画面上部中央（ノッチ位置）に貼り付く borderless パネルの面倒を見る。
///
/// - `.nonactivatingPanel` なので、クリックしてもターミナルからフォーカスを奪わない
/// - 全 Space / フルスクリーンの上に出す
/// - 上端を画面最上部に合わせ、メニューバー（ノッチ）の高さに重ねて表示する
final class NotchController {
    private let model: SessionsModel
    private let panel: NSPanel
    private let container: TrackingContainerView
    private var hosting: NSHostingView<NotchView>!
    private var collapseWork: DispatchWorkItem?
    private var hidden = false

    /// 表示先ディスプレイ名（NSScreen.localizedName）。nil / 見つからない場合はマウスのある画面
    var preferredDisplay: String? {
        didSet { layout() }
    }

    init(model: SessionsModel) {
        self.model = model
        let preferred = model.config.preferredDisplay
        self.preferredDisplay = preferred.isEmpty ? nil : preferred

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: NotchLayout.collapsedSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false

        container = TrackingContainerView()
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        hosting = NSHostingView(rootView: NotchView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        container.onEnter = { [weak self] in self?.mouseEntered() }
        container.onExit = { [weak self] in self?.mouseExited() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        layout()
    }

    // MARK: - 表示制御

    /// セッションの有無に応じて出す／引っ込める
    func refreshVisibility() {
        let shouldShow = !hidden && (!model.sessions.isEmpty || model.config.showWhenEmpty)
        if shouldShow {
            layout()
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    var isHidden: Bool { hidden }

    func setHidden(_ value: Bool) {
        hidden = value
        if value {
            model.pinned = false   // 隠すときはピンも解く（次に出したとき固まって見えないように）
            setExpanded(false)
            panel.orderOut(nil)
        } else {
            refreshVisibility()
        }
    }

    func setExpanded(_ value: Bool) {
        guard model.expanded != value else { return }
        model.expanded = value
        layout()
    }

    /// 通知すべきイベントが来たので一時的に開く
    func flash() {
        guard !hidden else { return }
        refreshVisibility()
        setExpanded(true)
        scheduleCollapse(after: max(2, model.config.autoExpandSeconds))
    }

    /// セッション一覧が変わったので大きさを合わせる
    func contentChanged() {
        refreshVisibility()
        if model.expanded { layout() }
    }

    // MARK: - レイアウト

    func layout() {
        let size = model.expanded
            ? NotchLayout.expandedSize(rowCount: max(model.sessions.count, 1))
            : NotchLayout.collapsedSize

        let screen = currentScreen
        let frame = screen.frame
        // メニューバー（ノッチ）に重ねる: 上端を画面最上部にぴったり付ける。
        // panel.level = .statusBar はメニューバーより上なので、バーの上に描ける。
        let origin = CGPoint(x: (frame.midX - size.width / 2).rounded(),
                             y: (frame.maxY - size.height).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private var currentScreen: NSScreen {
        // 指定ディスプレイが繋がっていればそれを使う（外れている間は自動にフォールバック）
        if let preferredDisplay,
           let hit = NSScreen.screens.first(where: { $0.localizedName == preferredDisplay }) {
            return hit
        }
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return hit }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    @objc private func screensChanged() {
        layout()
    }

    // MARK: - ホバー

    private func mouseEntered() {
        collapseWork?.cancel()
        setExpanded(true)
    }

    private func mouseExited() {
        scheduleCollapse(after: 0.4)
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // ピン留め中／マウスがまだ乗っているなら畳まない。
            // 畳まずに再スケジュールしておくので、ピンを外せば次の回で自然に畳まれる
            if self.model.pinned || self.panel.frame.contains(NSEvent.mouseLocation) {
                self.scheduleCollapse(after: 0.6)
                return
            }
            self.setExpanded(false)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// ホバーを拾うだけの NSView。アプリが非アクティブでも反応させるため `.activeAlways`。
/// （行のホバー検知でも使うので継承を許してある: NotchView の PassthroughTrackingView）
class TrackingContainerView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
