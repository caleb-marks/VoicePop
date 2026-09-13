import Darwin
import Foundation

/// The one way VoicePop runs child processes. Blocking calls must stay off the main thread.
///
/// Guarantees:
/// - stdout and stderr are always drained concurrently (captured) or sent to /dev/null (discarded),
///   so a chatty child can never block on a full pipe;
/// - with a timeout the child gets SIGTERM, then SIGKILL one second later, and the call returns
///   with `timedOut == true`;
/// - stdin is /dev/null.
public enum ProcessRunner {
    public enum Output: Sendable {
        case capture
        case discard
    }

    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        public var timedOut: Bool

        public var succeeded: Bool { !timedOut && status == 0 }
        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    public struct LaunchError: Error, LocalizedError {
        public let executable: String
        public let underlying: Error
        public var errorDescription: String? { "Could not run \(executable): \(underlying.localizedDescription)" }
    }

    /// Runs `executable` to completion (or timeout). Throws only when the process cannot launch.
    ///
    /// - Parameters:
    ///   - timeout: nil waits indefinitely.
    ///   - onStdoutLine: called for each complete stdout line as it arrives (on a reader thread),
    ///     e.g. JSON progress; stdout is still captured when `stdout == .capture`. No call happens
    ///     after `run` returns: a line in flight finishes first, later lines are dropped (a
    ///     grandchild holding the pipe open cannot deliver progress after completion).
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval? = nil,
        stdout: Output = .capture,
        stderr: Output = .capture,
        environment: [String: String]? = nil,
        onStdoutLine: ((String) -> Void)? = nil
    ) throws -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let environment { task.environment = environment }
        task.standardInput = FileHandle.nullDevice

        let group = DispatchGroup()
        let outBox = DataBox()
        let errBox = DataBox()
        let gate = LineGate()
        let wantsOut = stdout == .capture || onStdoutLine != nil
        let outPipe = wantsOut ? Pipe() : nil
        let errPipe = stderr == .capture ? Pipe() : nil
        task.standardOutput = outPipe ?? FileHandle.nullDevice
        task.standardError = errPipe ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do {
            try task.run()
        } catch {
            throw LaunchError(executable: executable, underlying: error)
        }
        // The parent's write ends must close so readers see EOF when the child exits.
        try? outPipe?.fileHandleForWriting.close()
        try? errPipe?.fileHandleForWriting.close()

        if let outPipe {
            drain(outPipe.fileHandleForReading, into: outBox, keep: stdout == .capture, lines: onStdoutLine.map { gate.wrap($0) }, group: group)
        }
        if let errPipe {
            drain(errPipe.fileHandleForReading, into: errBox, keep: true, lines: nil, group: group)
        }

        var timedOut = false
        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                task.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut {
                    kill(task.processIdentifier, SIGKILL)
                    exited.wait()
                }
            }
        } else {
            exited.wait()
        }
        // A grandchild can inherit the pipes and keep them open; return what was read after a
        // short wait instead of blocking on it (the reader thread finishes when the pipe closes).
        _ = group.wait(timeout: .now() + 1)
        gate.close()
        return Result(status: task.terminationStatus, stdout: outBox.data, stderr: errBox.data, timedOut: timedOut)
    }

    /// Fire-and-forget with both outputs discarded. Returns false when the launch fails.
    @discardableResult
    public static func spawnDetached(_ executable: String, _ arguments: [String] = []) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            return true
        } catch {
            return false
        }
    }

    /// Delivers lines until closed; `close()` waits for a delivery in progress.
    private final class LineGate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true

        func wrap(_ deliver: @escaping (String) -> Void) -> (String) -> Void {
            { [self] line in
                lock.lock()
                defer { lock.unlock() }
                if open { deliver(line) }
            }
        }

        func close() {
            lock.lock()
            open = false
            lock.unlock()
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        func append(_ chunk: Data) {
            lock.lock()
            storage.append(chunk)
            lock.unlock()
        }
    }

    private static func drain(
        _ handle: FileHandle,
        into box: DataBox,
        keep: Bool,
        lines: ((String) -> Void)?,
        group: DispatchGroup
    ) {
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            var pending = Data()
            let fd = handle.fileDescriptor
            var buf = [UInt8](repeating: 0, count: 16_384)
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                let chunk = Data(buf[0..<n])
                if keep { box.append(chunk) }
                guard let lines else { continue }
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    lines(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...nl)
                }
            }
            if let lines, !pending.isEmpty { lines(String(decoding: pending, as: UTF8.self)) }
        }
    }
}
