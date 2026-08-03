import Foundation

/// 直近の窓ごとのトークン合計。
public struct UsageTotals: Equatable {
    public var last5h: Int
    public var last7d: Int

    public static let zero = UsageTotals(last5h: 0, last7d: 0)

    public init(last5h: Int, last7d: Int) {
        self.last5h = last5h
        self.last7d = last7d
    }

    public var isZero: Bool { last5h == 0 && last7d == 0 }

    /// 「5h 12.3M / 7d 84.1M」。予算が設定されている窓だけ「5h 34%」に切り替える。
    public func summaryText(budget5h: Double = 0, budget7d: Double = 0) -> String {
        "5h \(UsageTotals.part(last5h, budget: budget5h)) / 7d \(UsageTotals.part(last7d, budget: budget7d))"
    }

    private static func part(_ tokens: Int, budget: Double) -> String {
        guard budget > 0 else { return compact(tokens) }
        return "\(Int((Double(tokens) / budget * 100).rounded()))%"
    }

    /// 12.3M / 845k / 1.5k / 512
    public static func compact(_ tokens: Int) -> String {
        let value = Double(tokens)
        // 999,500 以上は "%.1fM" が 1.0M 以上になる（"1000k" を出さないための境界）
        if value >= 999_500 { return String(format: "%.1fM", value / 1_000_000) }
        // 10k 未満は1桁小数（1,500 を "2k" にしない）。以上は整数 k で十分な精度
        if value >= 9_950 { return String(format: "%.0fk", value / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return "\(tokens)"
    }
}

/// `~/.claude/projects/*/*.jsonl`（transcript）を読んでトークン使用量をローカル集計する。
///
/// **見るのは transcript ファイルだけ。** Keychain・ネットワーク・OAuth トークンには触らない。
/// したがってこれは「Claude 側の quota の残り」ではなく、**手元のログから数えた使用量**。
///
/// 毎回の全再パースを避けるため、
/// 1. mtime が窓（7日）の内側のファイルだけ対象にする
/// 2. ファイルごとに前回読んだオフセットを覚えて、追記された分だけ読む
/// 3. 集計は 10 分粒度のバケットで持ち、窓から外れたバケットを捨てる
///
/// ⚠️ **スレッドセーフではない。** 単一の直列キューから触ること（UI を待たせないため background で）。
public final class UsageTracker {
    /// 「使った量」= 入力 + 出力 + キャッシュ書き込み。cache_read は読ませただけなので数えない
    public static let window5h: TimeInterval = 5 * 3600
    public static let window7d: TimeInterval = 7 * 86400

    private struct Cursor {
        var offset: UInt64
        var inode: UInt64
    }

    private let root: URL
    private let bucketSeconds: TimeInterval
    /// バケット番号 → トークン数
    private var buckets: [Int: Int] = [:]
    /// 二重計上を防ぐための uuid。バケットと同じ寿命なので窓外と一緒に落ちる
    private var seenByBucket: [Int: Set<String>] = [:]
    private var cursors: [String: Cursor] = [:]

    private let usageMarker = Data(#""output_tokens""#.utf8)
    private let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    public init(rootURL: URL = HinomiPaths.claudeProjectsURL, bucketSeconds: TimeInterval = 600) {
        self.root = rootURL
        self.bucketSeconds = max(1, bucketSeconds)
    }

    /// 追記分だけ読んで集計を更新する。初回は窓の内側のファイルを頭から読む（数秒かかりうる）。
    @discardableResult
    public func refresh(now: Date = Date()) -> UsageTotals {
        let files = candidateFiles(now: now)
        for url in files {
            ingest(fileAt: url)
        }
        prune(now: now, activePaths: Set(files.map(\.path)))
        return totals(now: now)
    }

    public func totals(now: Date = Date()) -> UsageTotals {
        UsageTotals(last5h: total(window: UsageTracker.window5h, now: now),
                    last7d: total(window: UsageTracker.window7d, now: now))
    }

    /// 窓に「かかっている」バケットを足す（境界のバケットは丸ごと含むので、最大で粒度ぶん多めに出る）
    public func total(window: TimeInterval, now: Date) -> Int {
        let cutoff = bucketKey(for: now.addingTimeInterval(-window))
        return buckets.reduce(into: 0) { sum, entry in
            if entry.key >= cutoff { sum += entry.value }
        }
    }

    // MARK: - ファイルの絞り込み

    /// 7日より古いファイルは、追記が無い＝窓に入るデータも無いので読まない
    private func candidateFiles(now: Date) -> [URL] {
        let cutoff = now.addingTimeInterval(-UsageTracker.window7d)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff else { continue }
            found.append(url)
        }
        return found
    }

    // MARK: - 増分読み

    private func ingest(fileAt url: URL) {
        let path = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let inode = (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? UInt64) ?? nil
        let size = (try? handle.seekToEnd()) ?? 0
        var cursor = cursors[path] ?? Cursor(offset: 0, inode: inode ?? 0)
        // 差し替え（inode 変化）・切り詰め・ローテートは頭から読み直す
        if cursor.inode != (inode ?? 0) || size < cursor.offset {
            cursor = Cursor(offset: 0, inode: inode ?? 0)
        }
        guard size > cursor.offset else {
            cursors[path] = cursor
            return
        }

        guard (try? handle.seek(toOffset: cursor.offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // 書き込み途中の末尾行は次回に回す（改行までを確定分とする）
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        cursor.offset += UInt64(complete.count)
        cursors[path] = cursor

        for line in complete.split(separator: 0x0A) {
            ingest(line: line)
        }
    }

    private func ingest(line: Data) {
        // usage を持つのは assistant の行だけ。大半は素通しなので先に安いふるいをかける
        guard line.count > 40, line.range(of: usageMarker) != nil else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let date = parseTimestamp(stamp) else { return }

        let tokens = intValue(usage, "input_tokens")
            + intValue(usage, "output_tokens")
            + intValue(usage, "cache_creation_input_tokens")
        guard tokens > 0 else { return }

        let key = bucketKey(for: date)
        // 同じ行が別ファイルへ写っていることがある（再開・分岐）ので uuid で一度だけ数える
        if let uuid = object["uuid"] as? String, !uuid.isEmpty {
            if seenByBucket[key]?.contains(uuid) == true { return }
            seenByBucket[key, default: []].insert(uuid)
        }
        buckets[key, default: 0] += tokens
    }

    private func intValue(_ object: [String: Any], _ key: String) -> Int {
        (object[key] as? NSNumber)?.intValue ?? 0
    }

    private func parseTimestamp(_ raw: String) -> Date? {
        isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw)
    }

    // MARK: - バケット

    private func bucketKey(for date: Date) -> Int {
        Int((date.timeIntervalSince1970 / bucketSeconds).rounded(.down))
    }

    private func prune(now: Date, activePaths: Set<String>? = nil) {
        let cutoff = bucketKey(for: now.addingTimeInterval(-UsageTracker.window7d))
        buckets = buckets.filter { $0.key >= cutoff }
        seenByBucket = seenByBucket.filter { $0.key >= cutoff }
        // 窓から外れたファイルのオフセット記憶も落とす（常駐で無限成長させない）
        if let activePaths {
            cursors = cursors.filter { activePaths.contains($0.key) }
        }
    }
}
