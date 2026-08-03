import AppKit
import HinomiCore

enum HinomiApp {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // Dock に出さない（Info.plist の LSUIElement と併せて二重に担保）
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config: HinomiConfig
    private let model: SessionsModel
    private var controller: NotchController?
    private var server: SocketServer?
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    override init() {
        config = HinomiConfig.load()
        model = SessionsModel(config: config)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HinomiPaths.ensureStateDir()

        let controller = NotchController(model: model)
        self.controller = controller

        model.onChange = { [weak controller] in controller?.contentChanged() }
        model.onEffect = { [weak self] effect, _ in self?.handle(effect: effect) }

        setUpStatusItem()
        startServer()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.model.tick()
        }
        controller.refreshVisibility()
        HinomiLog.write("hinomi \(hinomiVersion) 起動 (socket: \(HinomiPaths.socketPath))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        server?.stop()
        HinomiLog.write("hinomi 終了")
    }

    // MARK: - socket

    private func startServer() {
        let server = SocketServer(handler: { [weak self] message, respond in
            self?.model.handle(message, respond: respond)
        })
        do {
            try server.start()
            self.server = server
        } catch {
            HinomiLog.write("socket の待ち受けに失敗: \(error.localizedDescription)")
            alert(title: "hinomi を起動できませんでした",
                  body: """
                  \(HinomiPaths.socketPath) を待ち受けできませんでした。
                  既に hinomi が起動している可能性があります。

                  \(error.localizedDescription)
                  """)
            NSApp.terminate(nil)
        }
    }

    // MARK: - 効果音・自動展開

    private func handle(effect: SessionEffect) {
        switch effect {
        case .finished:
            play(config.doneSound)
            controller?.flash()
        case .permissionRequested:
            play(config.permissionSound)
            controller?.flash()
        case .inputNeeded:
            play(config.permissionSound)
            controller?.flash()
        case .none:
            break
        }
    }

    private func play(_ name: String) {
        guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.play()
    }

    // MARK: - メニューバー

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "flame", accessibilityDescription: "hinomi")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "hinomi \(hinomiVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(makeItem("オーバーレイの表示/非表示", #selector(toggleOverlay)))
        menu.addItem(makeItem("一覧をクリア", #selector(clearSessions)))
        let displayItem = NSMenuItem(title: "表示するディスプレイ", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu(title: "表示するディスプレイ")
        displayMenu.delegate = self   // 開くたびに接続中の画面一覧で作り直す
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("hooks を導入する…", #selector(installHooks)))
        menu.addItem(makeItem("hooks を外す…", #selector(uninstallHooks)))
        menu.addItem(makeItem("ログを表示", #selector(revealLog)))
        menu.addItem(makeItem("設定ファイルを開く", #selector(openConfig)))
        menu.addItem(.separator())
        menu.addItem(makeItem("hinomi を終了", #selector(quit)))
        item.menu = menu
        statusItem = item
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - 表示ディスプレイの選択

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "表示するディスプレイ" else { return }
        menu.removeAllItems()
        let current = controller?.preferredDisplay

        let auto = NSMenuItem(title: "自動（マウスのある画面）", action: #selector(selectDisplay(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = current == nil ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        for screen in NSScreen.screens {
            let name = screen.localizedName
            let item = NSMenuItem(title: name, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = current == name ? .on : .off
            menu.addItem(item)
        }
        // 選択中の画面がいま外れている場合も、選択を保持していることが見えるように出す
        if let current, !NSScreen.screens.contains(where: { $0.localizedName == current }) {
            let item = NSMenuItem(title: "\(current)（未接続）", action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = current
            item.state = .on
            menu.addItem(item)
        }
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String
        controller?.preferredDisplay = name
        config.preferredDisplay = name ?? ""
        try? config.save()
    }

    @objc private func toggleOverlay() {
        guard let controller else { return }
        controller.setHidden(!controller.isHidden)
    }

    @objc private func clearSessions() {
        model.clearAll()
    }

    @objc private func installHooks() {
        do {
            let hookPath = try CLI.resolveHookExecutable()
            let installer = HookInstaller(hookExecutable: hookPath, config: config)
            let result = try installer.install()
            alert(title: "hooks を導入しました",
                  body: """
                  \(result.settingsURL.path) に追記しました。
                  対象: \(result.events.joined(separator: ", "))
                  バックアップ: \(result.backupURL?.lastPathComponent ?? "（新規作成）")

                  既に開いている Claude Code には反映されません。開き直してください。
                  """)
        } catch {
            alert(title: "hooks の導入に失敗しました", body: error.localizedDescription)
        }
    }

    @objc private func uninstallHooks() {
        do {
            let installer = HookInstaller(hookExecutable: (try? CLI.resolveHookExecutable()) ?? "hinomi-hook",
                                          config: config)
            let result = try installer.uninstall()
            alert(title: "hooks を外しました",
                  body: """
                  \(result.settingsURL.path) から hinomi の分だけ除去しました。
                  バックアップ: \(result.backupURL?.lastPathComponent ?? "なし")
                  """)
        } catch {
            alert(title: "hooks の除去に失敗しました", body: error.localizedDescription)
        }
    }

    @objc private func revealLog() {
        HinomiPaths.ensureStateDir()
        if !FileManager.default.fileExists(atPath: HinomiPaths.logURL.path) {
            HinomiLog.write("ログを作成しました")
        }
        NSWorkspace.shared.activateFileViewerSelecting([HinomiPaths.logURL])
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: HinomiPaths.configURL.path) {
            try? config.save()
        }
        NSWorkspace.shared.open(HinomiPaths.configURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func alert(title: String, body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
