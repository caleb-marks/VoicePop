import Darwin
import Foundation
import XCTest
@testable import PopcornCore

/// Isolated runtime directory + a `/bin/sleep` child standing in for the Voxtype daemon.
final class DaemonFixture {
    let base: URL
    let runtime: URL
    var statePath: String { runtime.appendingPathComponent("state").path }
    var pidPath: String { runtime.appendingPathComponent("pid").path }
    private(set) var child: Process?

    init(createRuntime: Bool = true) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-observer-\(UUID().uuidString)")
        runtime = base.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: createRuntime ? runtime : base, withIntermediateDirectories: true)
    }

    deinit { cleanup() }

    @discardableResult
    func launchDaemon(state: String? = "idle") throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        child = p
        if let state { writeState(state) }
        write(pidPath, "\(p.processIdentifier)\n")
        return p.processIdentifier
    }

    func killDaemon() {
        child?.terminate()
        child?.waitUntilExit()
        child = nil
    }

    /// Rust `fs::write` shape: truncate in place, then write.
    func writeState(_ s: String) { write(statePath, s) }

    func write(_ path: String, _ s: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        precondition(fd >= 0)
        _ = s.utf8CString.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count - 1) }
        close(fd)
    }

    func renameState(_ s: String) {
        let tmp = runtime.appendingPathComponent(".state-\(UUID().uuidString)").path
        write(tmp, s)
        precondition(rename(tmp, statePath) == 0)
    }

    func cleanup() {
        killDaemon()
        try? FileManager.default.removeItem(at: base)
    }
}

/// Collects main-queue deliveries.
final class StateRecorder {
    private(set) var values: [DaemonState] = []
    private(set) var offMain = 0

    func attach(_ observer: DaemonStateObserver) {
        observer.addListener { [self] state in
            if !Thread.isMainThread { offMain += 1 }
            values.append(state)
        }
    }
}

final class DaemonStateObserverTests: XCTestCase {
    private func makeObserver(
        _ f: DaemonFixture,
        validator: @escaping (Int32) -> Bool = { _ in true },
        open openForEvents: ((String) -> Int32)? = nil
    ) -> DaemonStateObserver {
        var config = DaemonStateObserver.Configuration(
            statePath: f.statePath, pidPath: f.pidPath, runtimeDirectory: f.runtime.path, pidValidator: validator
        )
        if let openForEvents { config.openForEvents = openForEvents }
        return DaemonStateObserver(configuration: config)
    }

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits until the latest delivered value equals `wanted`.
    private func waitFor(
        _ recorder: StateRecorder, _ wanted: DaemonState, timeout: Double = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if recorder.values.last == wanted { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("timed out waiting for \(wanted); got \(recorder.values)", file: file, line: line)
    }

    func testDeliversOnMainForEveryTransitionWithoutDuplicates() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "idle")
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        waitFor(r, .idle)
        for (raw, state) in [("recording", DaemonState.recording), ("transcribing", .transcribing),
                             ("streaming", .streaming), ("future", .other("future")), ("idle", .idle)] {
            f.writeState(raw)
            waitFor(r, state)
        }
        let count = r.values.count
        f.writeState("idle")
        spin(0.15)
        XCTAssertEqual(r.values.count, count, "rewriting the same state must not call listeners")
        XCTAssertEqual(r.offMain, 0)
        XCTAssertEqual(r.values, [.missing, .idle, .recording, .transcribing, .streaming, .other("future"), .idle])
    }

    func testTruncateThenWriteKeepsLastStateInsteadOfFlashingMissing() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "recording")
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        waitFor(r, .recording)
        XCTAssertEqual(truncate(f.statePath, 0), 0)
        spin(0.15)
        XCTAssertEqual(r.values.last, .recording)
        XCTAssertEqual(o.state, .recording)
        f.writeState("transcribing")
        waitFor(r, .transcribing)
        XCTAssertFalse(r.values.dropFirst().contains(.missing))
    }

    func testAtomicReplacementByRenameRebindsEachTime() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "idle")
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        waitFor(r, .idle)
        for raw in ["recording", "transcribing", "idle", "recording"] {
            f.renameState(raw)
            waitFor(r, .parse(raw))
        }
        // In-place writes after replacements still reach the new inode's source.
        f.writeState("transcribing")
        waitFor(r, .transcribing)
        XCTAssertEqual(o.diagnostics().fallbackWakeups, 0)
    }

    func testDeleteAndRecreateStateFile() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "recording")
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        waitFor(r, .recording)
        try FileManager.default.removeItem(atPath: f.statePath)
        waitFor(r, .missing)
        f.writeState("idle")
        waitFor(r, .idle)
    }

    func testRuntimeDirectoryRemovedAndRecreated() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "idle")
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        waitFor(r, .idle)
        try FileManager.default.removeItem(at: f.runtime)
        waitFor(r, .missing)
        try FileManager.default.createDirectory(at: f.runtime, withIntermediateDirectories: true)
        f.writeState("recording")
        f.write(f.pidPath, "\(f.child!.processIdentifier)")
        waitFor(r, .recording)
        XCTAssertTrue(o.diagnostics().healthy)
    }

    func testStartsBeforeRuntimeDirectoryExists() throws {
        let f = try DaemonFixture(createRuntime: false)
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        spin(0.1)
        XCTAssertEqual(r.values, [.missing])
        XCTAssertTrue(o.diagnostics().healthy, "parent directory watch needs no fallback polling")
        try FileManager.default.createDirectory(at: f.runtime, withIntermediateDirectories: true)
        try f.launchDaemon(state: "recording")
        waitFor(r, .recording)
    }

    func testDaemonExitGoesMissingAndNewDaemonRecovers() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "recording")
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        waitFor(r, .recording)

        f.killDaemon()
        waitFor(r, .missing)
        // The stale files the dead daemon left behind must not revive it.
        f.writeState("recording")
        spin(0.15)
        XCTAssertEqual(r.values.last, .missing)

        try f.launchDaemon(state: "idle")
        waitFor(r, .idle)
    }

    func testPIDChangeWithoutExitFollowsNewProcess() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "idle")
        let first = f.child!
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer {
            o.stop()
            first.terminate()
        }
        waitFor(r, .idle)
        let second = try f.launchDaemon(state: "recording") // rewrites PID file, old process still alive
        waitFor(r, .recording)
        first.terminate()
        first.waitUntilExit()
        spin(0.15)
        XCTAssertEqual(r.values.last, .recording, "exit of the replaced PID must not mark the new daemon missing")
        XCTAssertEqual(DaemonProcess.readPID(f.pidPath), second)
    }

    func testUnrelatedProcessBehindStalePIDIsNotTheDaemon() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "recording")
        let o = makeObserver(f, validator: { _ in false })
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        spin(0.15)
        XCTAssertEqual(r.values, [.missing])
        XCTAssertFalse(DaemonProcess.looksLikeVoxtype(f.child!.processIdentifier))
    }

    func testIdleUnchangedDoesNoReadsCallbacksOrTimers() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "idle")
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        waitFor(r, .idle)
        spin(0.05)
        let before = o.diagnostics()
        let count = r.values.count
        spin(0.5)
        let after = o.diagnostics()
        XCTAssertEqual(r.values.count, count)
        XCTAssertEqual(after.stateReads, before.stateReads)
        XCTAssertEqual(after.reconciles, before.reconciles)
        XCTAssertEqual(after.fallbackWakeups, 0)
        XCTAssertTrue(after.healthy)
        XCTAssertEqual(after.openDescriptors, 3)
        XCTAssertEqual(after.processSources, 1)
    }

    func testRegistrationFailureFallsBackWithBackoffThenStopsPolling() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "idle")
        let lock = NSLock()
        var failures = 4
        let o = makeObserver(f, open: { path in
            lock.lock()
            defer { lock.unlock() }
            if failures > 0 {
                failures -= 1
                return -1
            }
            return open(path, O_EVTONLY | O_CLOEXEC)
        })
        let r = StateRecorder()
        r.attach(o)
        o.start()
        defer { o.stop() }
        waitFor(r, .idle)
        let end = Date().addingTimeInterval(3)
        while Date() < end, !o.diagnostics().healthy || o.diagnostics().openDescriptors < 3 { spin(0.01) }
        let recovered = o.diagnostics()
        XCTAssertTrue(recovered.healthy)
        XCTAssertGreaterThan(recovered.fallbackWakeups, 0)
        spin(0.3)
        XCTAssertEqual(o.diagnostics().fallbackWakeups, recovered.fallbackWakeups, "no polling once healthy")
        f.writeState("recording")
        waitFor(r, .recording)
    }

    func testStopReleasesDescriptorsDropsQueuedDeliveriesAndRestarts() throws {
        let f = try DaemonFixture()
        try f.launchDaemon(state: "idle")
        let o = makeObserver(f)
        let r = StateRecorder()
        r.attach(o)
        let fdsBefore = openFDs()
        for _ in 0..<20 {
            o.start()
            o.waitUntilIdle()
            o.stop()
        }
        waitForDescriptors(o, 0)
        XCTAssertEqual(o.diagnostics().processSources, 0)

        o.start()
        waitFor(r, .idle)
        f.writeState("recording")
        // Stop before the main queue runs: the pending delivery must be discarded.
        let end = Date().addingTimeInterval(2)
        while Date() < end, o.state != .recording { usleep(1000) }
        o.stop()
        let count = r.values.count
        spin(0.1)
        XCTAssertEqual(r.values.count, count)

        o.start()
        waitFor(r, .recording)
        o.stop()
        waitForDescriptors(o, 0)
        spin(0.05)
        XCTAssertLessThanOrEqual(openFDs(), fdsBefore + 1)
    }

    private func waitForDescriptors(_ o: DaemonStateObserver, _ n: Int, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(2)
        while Date() < end, o.diagnostics().openDescriptors != n { spin(0.01) }
        XCTAssertEqual(o.diagnostics().openDescriptors, n, file: file, line: line)
    }

    private func openFDs() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }
}
