import Darwin
import Foundation

/// Kernel lookups about other processes. No subprocesses are launched.
public enum ProcessIdentity {
    /// Executable path of `pid`, or nil when it cannot be read (exited, or not permitted).
    public static func executablePath(pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), an unimportable C macro.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0 else { return nil }
        return String(cString: path)
    }

    /// argv of `pid` (argv[0] first), or nil when it cannot be read.
    public static func arguments(pid: Int32) -> [String]? {
        guard pid > 1 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        // Skip the saved executable path and its NUL padding.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// PIDs of every process visible to this user.
    public static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 1 }
    }

    /// True when `pid` is alive and runs exactly `executablePath` (symlinks resolved).
    public static func isRunning(pid: Int32, executablePath: String) -> Bool {
        guard pid > 1, kill(pid, 0) == 0, let actual = self.executablePath(pid: pid) else { return false }
        let expected = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        return URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == expected
    }
}
