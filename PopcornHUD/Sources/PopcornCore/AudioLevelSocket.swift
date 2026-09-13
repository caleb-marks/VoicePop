import Darwin
import Dispatch
import Foundation

/// Nonblocking Unix-socket reader for Voxtype's `audio.sock` level frames.
///
/// While started it stays connected, reconnecting every `reconnectDelayMs` after EOF, errors, or a
/// missing socket (device change, daemon restart). Readers call `consumePeak()` once per display
/// tick. Generation fencing makes late callbacks from a previous start/stop harmless.
public final class AudioLevelSocket {
    /// Per-start counters for health evidence (e.g. a recording whose frames were all exactly zero).
    public struct SessionStats: Equatable, Sendable {
        public var frames = 0
        public var maxPeak: Float = 0
        public var connects = 0
        public var disconnects = 0
        public init() {}
    }

    private let path: String
    private let reconnectDelayMs: Int
    private let staleMs: UInt64
    private let queue = DispatchQueue(label: "com.caleb.voicepop.audio", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()

    // Queue-confined.
    private var generation: UInt64 = 0
    private var active = false
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var reconnectTimer: DispatchSourceTimer?
    private var buffer = AudioFrameBuffer()
    private var connected = false
    private var readBuf = [UInt8](repeating: 0, count: 4096)

    // Shared with the display tick.
    private let lock = NSLock()
    private var hold = AudioLevelHold()
    private var stats = SessionStats()

    public init(path: String = Paths.audioSock, reconnectDelayMs: Int = 250, staleMs: UInt64 = UInt64(Tunables.staleAudioMs)) {
        self.path = path
        self.reconnectDelayMs = reconnectDelayMs
        self.staleMs = staleMs
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        // Cancel armed sources so cancel handlers (which own the fd) run. The last release can
        // happen inside a handler on the audio queue, where `queue.sync` would deadlock.
        let teardown = {
            self.active = false
            self.generation &+= 1
            self.cancelReconnect()
            self.teardownFD()
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { teardown() } else { queue.sync(execute: teardown) }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.active else { return }
            self.active = true
            self.generation &+= 1
            self.buffer.reset()
            self.lock.lock()
            self.hold.reset()
            self.stats = SessionStats()
            self.lock.unlock()
            self.connected = false
            self.connect(gen: self.generation)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.active = false
            self.generation &+= 1
            self.cancelReconnect()
            self.teardownFD()
            self.buffer.reset()
            self.lock.lock()
            self.hold.reset()
            self.lock.unlock()
        }
    }

    /// Waits for queued start/stop work (tests).
    public func waitUntilIdle() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    /// Consume levels for one display tick. Distinguishes fresh / held / unavailable.
    public func consumePeak(nowMs: UInt64 = Timing.nowMs()) -> AudioLevelSample {
        lock.lock()
        defer { lock.unlock() }
        return hold.consume(nowMs: nowMs, staleMs: staleMs)
    }

    /// Counters since the last `start()`.
    public func sessionStats() -> SessionStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    // MARK: - Connection

    private func connect(gen: UInt64) {
        guard active, gen == generation else { return }
        teardownFD()
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            scheduleReconnect(gen: gen)
            return
        }
        _ = fcntl(sock, F_SETFD, FD_CLOEXEC)
        _ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL, 0) | O_NONBLOCK)
        var on: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(sock)
            scheduleReconnect(gen: gen)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cPtr in
                for (i, b) in pathBytes.enumerated() { cPtr[i] = b }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 || errno == EISCONN {
            fd = sock
            armReadSource(gen: gen)
            markConnected()
            return
        }
        if errno == EINPROGRESS {
            fd = sock
            armWriteSourceForConnect(gen: gen)
            return
        }
        close(sock)
        scheduleReconnect(gen: gen)
    }

    private func armWriteSourceForConnect(gen: UInt64) {
        guard fd >= 0, writeSource == nil else { return }
        let src = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.finishConnect(gen: gen) }
        writeSource = src
        src.resume()
    }

    private func finishConnect(gen: UInt64) {
        guard active, gen == generation, fd >= 0 else {
            teardownFD()
            return
        }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else {
            teardownFD()
            scheduleReconnect(gen: gen)
            return
        }
        // Drop the write source without closing the fd, then arm read.
        writeSource?.cancel()
        writeSource = nil
        armReadSource(gen: gen)
        markConnected()
    }

    private func armReadSource(gen: UInt64) {
        guard fd >= 0 else { return }
        readSource?.cancel()
        readSource = nil
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.onReadable(gen: gen) }
        readSource = src
        src.resume()
    }

    private func markConnected() {
        cancelReconnect()
        connected = true
        lock.lock()
        hold.snapshot.connected = true
        stats.connects += 1
        lock.unlock()
        Timing.event("audio.connect")
    }

    private func onReadable(gen: UInt64) {
        guard active, gen == generation, fd >= 0 else { return }
        while true {
            let n = readBuf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let frames = readBuf.withUnsafeBufferPointer {
                    buffer.append(UnsafeBufferPointer(start: $0.baseAddress, count: n))
                }
                publish(frames: frames, gen: gen)
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if n < 0, errno == EINTR {
                continue
            } else {
                // EOF or error: the daemon closed the stream (stop, device change, restart).
                teardownFD()
                scheduleReconnect(gen: gen)
                return
            }
        }
    }

    private func publish(frames: [AudioFrame], gen: UInt64) {
        guard active, gen == generation, !frames.isEmpty else { return }
        let now = Timing.nowMs()
        var maxPeak: Float = 0
        for f in frames { maxPeak = Swift.max(maxPeak, f.peak) }
        lock.lock()
        hold.publish(peak: maxPeak, monoMs: now)
        stats.frames += frames.count
        stats.maxPeak = Swift.max(stats.maxPeak, maxPeak)
        lock.unlock()
    }

    private func scheduleReconnect(gen: UInt64) {
        guard active, gen == generation else { return }
        cancelReconnect()
        lock.lock()
        hold.markDisconnected()
        if connected { stats.disconnects += 1 }
        lock.unlock()
        if connected { Timing.event("audio.disconnect") }
        connected = false
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(reconnectDelayMs), repeating: .never)
        t.setEventHandler { [weak self] in self?.connect(gen: gen) }
        reconnectTimer = t
        t.resume()
    }

    private func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    private func teardownFD() {
        let doomed = fd
        fd = -1
        let read = readSource
        let write = writeSource
        readSource = nil
        writeSource = nil
        if let read {
            write?.cancel()
            read.setCancelHandler { if doomed >= 0 { close(doomed) } }
            read.cancel()
        } else if let write {
            write.setCancelHandler { if doomed >= 0 { close(doomed) } }
            write.cancel()
        } else if doomed >= 0 {
            close(doomed)
        }
    }
}
