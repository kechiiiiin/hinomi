import Darwin
import Foundation

/// 自分（またはその祖先）の制御端末を `/dev/ttys003` の形で引く。
///
/// hook プロセスは `claude` の子として起動されるので、制御端末はそのまま継承されている。
/// hook の stdin はパイプなので `ttyname(0)` では取れない——プロセスの制御端末
/// （`proc_bsdinfo.e_tdev`）を libproc で見るのが確実。
///
/// デスクトップアプリから起動された Claude Code のように端末を持たない場合は nil。
/// **取れなくても構わない**（精密ジャンプを諦めてアプリのアクティベートに落ちるだけ）。
public enum ControllingTTY {
    /// 自分から親を辿って、最初に見つかった制御端末のデバイスパス。無ければ nil。
    public static func current(startingAt pid: pid_t = getpid(), maxDepth: Int = 12) -> String? {
        var pid = pid
        for _ in 0..<maxDepth {
            guard let info = bsdInfo(pid) else { return nil }
            if let path = devicePath(forDev: info.e_tdev) { return path }
            let parent = pid_t(info.pbi_ppid)
            if parent <= 1 || parent == pid { return nil }
            pid = parent
        }
        return nil
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return written == size ? info : nil
    }

    /// dev_t → `/dev/ttys003`。端末を持たないプロセスは NODEV（-1）や 0 になる。
    private static func devicePath(forDev dev: UInt32) -> String? {
        guard dev != 0, dev != UInt32(bitPattern: -1) else { return nil }
        guard let name = devname(dev_t(dev), S_IFCHR) else { return nil }
        let path = "/dev/" + String(cString: name)
        return TerminalJumpScript.isPlausibleTTY(path) ? path : nil
    }
}
