import Darwin
import Foundation

public enum ProcessIdentity {
    /// A stale PID can belong to a different process after a restart.
    /// Query the kernel directly so checking identity never launches a subprocess.
    public static func isRunning(pid: Int32, executablePath: String) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), an unimportable C macro.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { return false }
        let actual = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
        let expected = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        return actual == expected
    }
}
