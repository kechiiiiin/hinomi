import Foundation

/// Claude Code デスクトップアプリが付けるセッションタイトルを引く。
///
/// `~/Library/Application Support/Claude/claude-code-sessions/**/*.json` に
/// `{ "cliSessionId": <hooks が見る session_id>, "title": <表示タイトル> }` が入っている。
/// ターミナル起動のセッションにはこのファイルが無いので、その場合は直近プロンプトが
/// タイトル代わりになる（SessionInfo.displayTitle 参照）。
public struct SessionTitleLookup {
    public let rootURL: URL

    public init(rootURL: URL = SessionTitleLookup.defaultRoot) {
        self.rootURL = rootURL
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// cliSessionId → title の写像を作る。ファイルは数十件・数KB想定なので全走査でよい。
    public func titlesByCLISessionID() -> [String: String] {
        var result: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return result }
        for case let url as URL in enumerator {
            guard url.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cliID = object["cliSessionId"] as? String, !cliID.isEmpty,
                  let title = object["title"] as? String, !title.isEmpty else { continue }
            result[cliID] = title
        }
        return result
    }
}
