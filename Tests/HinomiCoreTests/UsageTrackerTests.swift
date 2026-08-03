import XCTest
@testable import HinomiCore

final class UsageTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hinomi-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("-w-proj"),
                                               withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - fake transcript

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// 実物と同じ形の1行（assistant のイベントに message.usage が付く）
    private func line(minutesAgo: Double,
                      input: Int = 0,
                      output: Int = 0,
                      cacheCreation: Int = 0,
                      cacheRead: Int = 0,
                      uuid: String = UUID().uuidString) -> String {
        let stamp = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(stamp)","sessionId":"s1","cwd":"/w/proj",\
        "message":{"role":"assistant","model":"claude","usage":{"input_tokens":\(input),\
        "output_tokens":\(output),"cache_creation_input_tokens":\(cacheCreation),\
        "cache_read_input_tokens":\(cacheRead),"service_tier":"standard"}}}
        """
    }

    private func write(_ lines: [String], to name: String = "a.jsonl", modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent("-w-proj/\(name)")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func tracker() -> UsageTracker {
        UsageTracker(rootURL: root, bucketSeconds: 600)
    }

    // MARK: - 集計

    func testSumsInputOutputAndCacheCreationButNotCacheRead() throws {
        _ = try write([line(minutesAgo: 5, input: 10, output: 100, cacheCreation: 1_000, cacheRead: 999_999)])
        let totals = tracker().refresh(now: now)
        XCTAssertEqual(totals.last5h, 1_110)
        XCTAssertEqual(totals.last7d, 1_110)
    }

    func testWindowsDropOlderEntries() throws {
        _ = try write([
            line(minutesAgo: 10, output: 1),          // 5h 窓の中
            line(minutesAgo: 4 * 60, output: 20),     // 5h 窓の中
            line(minutesAgo: 6 * 60, output: 300),    // 5h 窓の外・7d の中
            line(minutesAgo: 3 * 24 * 60, output: 4_000),
            line(minutesAgo: 9 * 24 * 60, output: 50_000),   // 7d 窓の外
        ])
        let totals = tracker().refresh(now: now)
        XCTAssertEqual(totals.last5h, 21)
        XCTAssertEqual(totals.last7d, 4_321)
    }

    func testOldFilesAreSkippedByMTime() throws {
        // mtime が 7 日より古いファイルは開かない（中身が新しく見えても対象外）
        _ = try write([line(minutesAgo: 1, output: 777)],
                      to: "stale.jsonl",
                      modified: now.addingTimeInterval(-9 * 86400))
        XCTAssertEqual(tracker().refresh(now: now), .zero)
    }

    func testIncrementalReadOnlyCountsAppendedLines() throws {
        let url = try write([line(minutesAgo: 1, output: 100)])
        let tracker = self.tracker()
        XCTAssertEqual(tracker.refresh(now: now).last5h, 100)
        // 追記が無ければ増えない（同じ行を読み直さない）
        XCTAssertEqual(tracker.refresh(now: now).last5h, 100)
        try append([line(minutesAgo: 1, output: 5)], to: url)
        XCTAssertEqual(tracker.refresh(now: now).last5h, 105)
    }

    func testPartialTrailingLineIsDeferredUntilComplete() throws {
        let url = try write([line(minutesAgo: 1, output: 100)])
        let tracker = self.tracker()
        XCTAssertEqual(tracker.refresh(now: now).last5h, 100)

        // 改行が来ていない書きかけの行は数えない
        let partial = line(minutesAgo: 1, output: 60, uuid: "later")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(partial.prefix(partial.count / 2).utf8))
        try handle.close()
        XCTAssertEqual(tracker.refresh(now: now).last5h, 100)

        // 残りと改行が来たら、その時点で丸ごと数える
        let rest = try FileHandle(forWritingTo: url)
        try rest.seekToEnd()
        try rest.write(contentsOf: Data((partial.dropFirst(partial.count / 2) + "\n").utf8))
        try rest.close()
        XCTAssertEqual(tracker.refresh(now: now).last5h, 160)
    }

    func testTruncatedFileIsReReadFromStart() throws {
        let url = try write([line(minutesAgo: 1, output: 100)])
        let tracker = self.tracker()
        XCTAssertEqual(tracker.refresh(now: now).last5h, 100)
        // ファイルが短くなった（差し替え・ローテート）ら頭から読み直す
        try Data((line(minutesAgo: 1, output: 7, uuid: "fresh") + "\n").utf8).write(to: url)
        XCTAssertEqual(tracker.refresh(now: now).last5h, 107)
    }

    func testSameUUIDIsNotCountedTwiceAcrossFiles() throws {
        let shared = line(minutesAgo: 1, output: 500, uuid: "dup-1")
        _ = try write([shared], to: "one.jsonl")
        _ = try write([shared], to: "two.jsonl")   // 再開・分岐で写された行
        XCTAssertEqual(tracker().refresh(now: now).last5h, 500)
    }

    func testGarbageAndUnrelatedLinesAreIgnored() throws {
        _ = try write([
            "これは JSON ではない",
            #"{"type":"user","uuid":"u1","timestamp":"2026-08-01T00:00:00.000Z","message":{"role":"user","content":"output_tokens って何"}}"#,
            #"{"type":"assistant","uuid":"u2","message":{"usage":{"output_tokens":10}}}"#,   // timestamp なし
            line(minutesAgo: 1, output: 3),
        ])
        XCTAssertEqual(tracker().refresh(now: now).last5h, 3)
    }

    func testMissingRootIsHarmless() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(UsageTracker(rootURL: missing).refresh(now: now), .zero)
    }

    // MARK: - 表示

    func testCompactFormatting() {
        XCTAssertEqual(UsageTotals.compact(0), "0")
        XCTAssertEqual(UsageTotals.compact(512), "512")
        XCTAssertEqual(UsageTotals.compact(1_500), "2k")
        XCTAssertEqual(UsageTotals.compact(845_000), "845k")
        XCTAssertEqual(UsageTotals.compact(12_345_678), "12.3M")
    }

    func testSummaryTextSwitchesToPercentPerWindow() {
        let totals = UsageTotals(last5h: 12_300_000, last7d: 84_100_000)
        XCTAssertEqual(totals.summaryText(), "5h 12.3M / 7d 84.1M")
        XCTAssertEqual(totals.summaryText(budget5h: 36_000_000), "5h 34% / 7d 84.1M")
        XCTAssertEqual(totals.summaryText(budget5h: 36_000_000, budget7d: 700_000_000), "5h 34% / 7d 12%")
        XCTAssertTrue(UsageTotals.zero.isZero)
    }
}
