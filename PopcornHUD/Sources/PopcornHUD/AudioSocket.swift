import Foundation
import Darwin
import PopcornCore

/// Nonblocking Unix-socket reader for Voxtype audio.sock.
final class AudioSocketReader {
    private let path: String
    private let queue = DispatchQueue(label: "com.caleb.voicepop.audio", qos: .userInteractive)

    private var generation: UInt64 = 0
    private var active = false
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var reconnectTimer: DispatchSourceTimer?
    private var buffer = AudioFrameBuffer()
    private var connectedLogged = false
    private var readBuf = [UInt8](repeating: 0, count: 4096)

    private let lock = NSLock()
    private var hold = AudioLevelHold()

    init(path: String = Paths.audioSock) {
        self.path = path
    }

    deinit {
        // Cancel any armed sources on the audio queue so cancel handlers
        // (which own the fd) run before this object disappears.
        queue.sync {
            active = false
            generation &+= 1
            cancelReconnect()
            teardownFD()
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.active { return }
            self.active = true
            self.generation &+= 1
            let gen = self.generation
            self.buffer.reset()
            self.clearSnapshotLocked()
            self.connectedLogged = false
            self.connect(gen: gen)
            Timing.log("audio start gen=\(gen)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            let gen = self.generation
            self.active = false
            self.generation &+= 1
            self.cancelReconnect()
            self.teardownFD()
            self.buffer.reset()
            self.clearSnapshotLocked()
            Timing.log("audio stop prevGen=\(gen)")
        }
    }

    /// Consume levels for one display tick. Distinguishes fresh / held / unavailable.
    func consumePeak() -> AudioLevelSample {
        lock.lock()
        defer { lock.unlock() }
        return hold.consume(nowMs: Timing.nowMs(), staleMs: UInt64(Tunables.staleAudioMs))
    }

    private func clearSnapshotLocked() {
        lock.lock()
        hold.reset()
        lock.unlock()
    }

    private func connect(gen: UInt64) {
        guard active, gen == generation else { return }
        teardownFD()
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            scheduleReconnect(gen: gen)
            return
        }
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

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
        src.setEventHandler { [weak self] in
            self?.finishConnect(gen: gen)
        }
        writeSource = src
        src.resume()
    }

    private func finishConnect(gen: UInt64) {
        // Do not cancel the write source here — teardownFD owns it on failure,
        // and on success we hand the fd to the read source without closing.
        guard active, gen == generation, fd >= 0 else {
            teardownFD()
            return
        }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        let ok = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0
        if !ok {
            teardownFD()
            scheduleReconnect(gen: gen)
            return
        }

        // Success: drop the write source without closing the fd, then arm read.
        writeSource?.cancel()
        writeSource = nil
        armReadSource(gen: gen)
        markConnected()
    }

    private func armReadSource(gen: UInt64) {
        guard fd >= 0 else { return }
        // Cancel any prior read source without closing — teardownFD owns close.
        readSource?.cancel()
        readSource = nil
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.onReadable(gen: gen)
        }
        readSource = src
        src.resume()
    }

    private func markConnected() {
        cancelReconnect()
        if !connectedLogged {
            connectedLogged = true
            fputs("audio connected\n", stderr)
        }
        lock.lock()
        hold.snapshot.connected = true
        lock.unlock()
    }

    private func onReadable(gen: UInt64) {
        guard active, gen == generation, fd >= 0 else { return }
        while true {
            let n = readBuf.withUnsafeMutableBytes { raw -> Int in
                Int(read(fd, raw.baseAddress, raw.count))
            }
            if n > 0 {
                let frames = readBuf.withUnsafeBufferPointer { buf in
                    self.buffer.append(UnsafeBufferPointer(start: buf.baseAddress, count: n))
                }
                publish(frames: frames, gen: gen)
            } else if n == 0 {
                teardownFD()
                scheduleReconnect(gen: gen)
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno == EINTR {
                continue
            } else {
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
        for f in frames {
            maxPeak = Swift.max(maxPeak, f.peak)
        }
        lock.lock()
        hold.publish(peak: maxPeak, monoMs: now)
        lock.unlock()
        Timing.log("frame peak=\(maxPeak) ms=\(now)")
    }

    private func scheduleReconnect(gen: UInt64) {
        guard active, gen == generation else { return }
        cancelReconnect()
        lock.lock()
        hold.markDisconnected()
        lock.unlock()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .never)
        t.setEventHandler { [weak self] in
            self?.connect(gen: gen)
        }
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
            read.setCancelHandler {
                if doomed >= 0 { close(doomed) }
            }
            read.cancel()
        } else if let write {
            write.setCancelHandler {
                if doomed >= 0 { close(doomed) }
            }
            write.cancel()
        } else if doomed >= 0 {
            close(doomed)
        }
    }
}
