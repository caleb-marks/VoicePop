import Darwin
import Foundation
import XCTest
@testable import PopcornCore

/// A one-client-at-a-time Unix socket server standing in for Voxtype's audio.sock.
final class FakeAudioServer {
    let path: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var client: Int32 = -1
    private(set) var accepted = 0

    init(path: String) throws {
        self.path = path
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        precondition(bytes.count <= MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { c in
                for (i, b) in bytes.enumerated() { c[i] = b }
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(listenFD, 4) == 0 else { throw NSError(domain: "FakeAudioServer", code: Int(errno)) }
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                var on: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                guard let self else { close(c); return }
                self.lock.lock()
                if self.client >= 0 { close(self.client) }
                self.client = c
                self.accepted += 1
                self.lock.unlock()
            }
        }
    }

    var acceptedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    @discardableResult
    func send(peak: Float, count: Int = 1) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard client >= 0 else { return false }
        var bytes: [UInt8] = []
        for i in 0..<count { bytes += AudioFrame(seq: UInt32(i), min: -peak, max: peak, peakDbfs: -6).encode() }
        return bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) } == bytes.count
    }

    func dropClient() {
        lock.lock()
        if client >= 0 { close(client) }
        client = -1
        lock.unlock()
    }

    /// True once the reader closed its end.
    func clientClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard client >= 0 else { return true }
        var pfd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 0) > 0 else { return false }
        var b: UInt8 = 0
        return recv(client, &b, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    func shutdown() {
        dropClient()
        close(listenFD)
        listenFD = -1
        unlink(path)
    }

    deinit { if listenFD >= 0 { shutdown() } }
}

final class AudioLevelSocketTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        // sun_path is limited to 104 bytes, so keep the fixture path short.
        dir = NSTemporaryDirectory() + "vpa-\(UInt32.random(in: 0...UInt32.max))"
        XCTAssertEqual(mkdir(dir, 0o700), 0)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func eventually(_ timeout: Double = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            usleep(5000)
        }
        return condition()
    }

    func testFreshLevelsThenServerDisconnectReconnects() throws {
        let server = try FakeAudioServer(path: dir + "/audio.sock")
        defer { server.shutdown() }
        let reader = AudioLevelSocket(path: server.path, reconnectDelayMs: 20, staleMs: 250)
        reader.start()
        XCTAssertTrue(eventually { server.acceptedCount == 1 })
        XCTAssertTrue(eventually {
            server.send(peak: 0.5, count: 3)
            usleep(10_000)
            return reader.consumePeak().freshness == .fresh
        })
        let stats = reader.sessionStats()
        XCTAssertGreaterThanOrEqual(stats.frames, 3)
        XCTAssertEqual(stats.maxPeak, 0.5, accuracy: 0.001)

        // Microphone/device change: the daemon closes the stream.
        server.dropClient()
        XCTAssertTrue(eventually { reader.consumePeak().freshness == .unavailable })
        XCTAssertTrue(eventually { server.acceptedCount == 2 }, "reader reconnects after EOF")
        XCTAssertTrue(eventually {
            server.send(peak: 0.25)
            usleep(10_000)
            return reader.consumePeak().freshness == .fresh
        })
        XCTAssertEqual(reader.sessionStats().disconnects, 1)
        XCTAssertEqual(reader.sessionStats().connects, 2)
        reader.stop()
    }

    func testMissingSocketRetriesUntilDaemonCreatesIt() throws {
        let path = dir + "/audio.sock"
        let reader = AudioLevelSocket(path: path, reconnectDelayMs: 20, staleMs: 250)
        reader.start()
        usleep(80_000)
        XCTAssertEqual(reader.consumePeak().freshness, .unavailable)
        let server = try FakeAudioServer(path: path)
        defer { server.shutdown() }
        XCTAssertTrue(eventually { server.acceptedCount >= 1 })
        XCTAssertTrue(eventually {
            server.send(peak: 0.1)
            usleep(10_000)
            return reader.consumePeak().freshness == .fresh
        })
        reader.stop()
    }

    func testStaleLevelsBecomeUnavailableWithoutDisconnect() throws {
        let server = try FakeAudioServer(path: dir + "/audio.sock")
        defer { server.shutdown() }
        let reader = AudioLevelSocket(path: server.path, reconnectDelayMs: 20, staleMs: 60)
        reader.start()
        XCTAssertTrue(eventually {
            server.send(peak: 0.3)
            usleep(10_000)
            return reader.consumePeak().freshness == .fresh
        })
        XCTAssertEqual(reader.consumePeak().freshness, .held)
        usleep(120_000)
        XCTAssertEqual(reader.consumePeak().freshness, .unavailable)
        reader.stop()
    }

    func testStopClosesConnectionAndClearsLevels() throws {
        let server = try FakeAudioServer(path: dir + "/audio.sock")
        defer { server.shutdown() }
        let reader = AudioLevelSocket(path: server.path, reconnectDelayMs: 20, staleMs: 250)
        reader.start()
        XCTAssertTrue(eventually { server.acceptedCount == 1 })
        server.send(peak: 0.4)
        reader.stop()
        reader.waitUntilIdle()
        XCTAssertEqual(reader.consumePeak().freshness, .unavailable)
        XCTAssertTrue(eventually { server.clientClosed() })
        usleep(100_000)
        XCTAssertEqual(server.acceptedCount, 1, "no reconnect after stop")
    }

    func testOldestPacketTimeIsReportedForReactionLatency() {
        var hold = AudioLevelHold()
        hold.publish(peak: 0.2, monoMs: 1000)
        hold.publish(peak: 0.6, monoMs: 1010)
        let s = hold.consume(nowMs: 1012, staleMs: 250)
        XCTAssertEqual(s.freshness, .fresh)
        XCTAssertEqual(s.oldestPacketMonoMs, 1000)
        XCTAssertEqual(s.peak, 0.6)
        XCTAssertEqual(hold.consume(nowMs: 1014, staleMs: 250).oldestPacketMonoMs, 0)
    }
}
