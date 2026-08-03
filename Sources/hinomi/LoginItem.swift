import Foundation
import ServiceManagement

/// ログイン時の自動起動（`SMAppService.mainApp`）。
///
/// システム設定 → 一般 → ログイン項目 に自分自身を登録する。
/// `.app` バンドルとして起動されていないとき（`.build/release/hinomi` を直に実行した等）は
/// 登録できないので、その旨をそのまま呼び出し元に投げる。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 「ユーザーの承認待ち」= 登録はしたが、システム設定でオフにされている状態
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "有効"
        case .requiresApproval: return "システム設定での承認待ち"
        case .notRegistered: return "未登録"
        case .notFound: return "登録先が見つかりません（.app として起動していない可能性）"
        @unknown default: return "不明"
        }
    }
}
