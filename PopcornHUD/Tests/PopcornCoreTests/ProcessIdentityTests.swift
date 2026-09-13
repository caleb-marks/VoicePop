import XCTest
@testable import PopcornCore

final class ProcessIdentityTests: XCTestCase {
    func testLiveUnrelatedProcessDoesNotMatchEngine() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        try task.run()
        defer {
            if task.isRunning { task.terminate() }
            task.waitUntilExit()
        }
        XCTAssertTrue(ProcessIdentity.isRunning(pid: task.processIdentifier, executablePath: "/bin/sleep"))
        XCTAssertFalse(ProcessIdentity.isRunning(
            pid: task.processIdentifier,
            executablePath: "/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"
        ))
        task.terminate()
        task.waitUntilExit()
        XCTAssertFalse(ProcessIdentity.isRunning(pid: task.processIdentifier, executablePath: "/bin/sleep"))
    }

    func testInvalidPIDsAreRejected() {
        for pid: Int32 in [-1, 0, 1] {
            XCTAssertFalse(ProcessIdentity.isRunning(pid: pid, executablePath: "/bin/sleep"))
        }
    }
}

final class DaemonIdentityTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A copy of a system tool at `relativePath`, standing in for a Voxtype build at another location.
    private func launchCopy(of tool: String, at relativePath: String, _ args: [String]) throws -> Process {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: tool, toPath: url.path)
        // A moved platform binary is killed at launch; an ad-hoc signature makes the copy runnable.
        XCTAssertTrue(try ProcessRunner.run("/usr/bin/codesign", ["-f", "-s", "-", url.path], timeout: 20).succeeded)
        let p = Process()
        p.executableURL = url
        p.arguments = args
        try p.run()
        // Guard against a false pass through the lookup-failure path: the copy must be alive and named.
        usleep(50_000)
        XCTAssertTrue(p.isRunning, "copy at \(relativePath) did not stay running")
        XCTAssertEqual(ProcessIdentity.executablePath(pid: p.processIdentifier).map { URL(fileURLWithPath: $0).lastPathComponent },
                       url.lastPathComponent)
        return p
    }

    func testVoxtypeAtAnotherInstallLocationIsRecognized() throws {
        let brew = try launchCopy(of: "/bin/sleep", at: "homebrew/bin/voxtype", ["30"])
        let bundle = try launchCopy(of: "/bin/sleep", at: "Users/me/Applications/Voxtype.app/Contents/MacOS/voxtype-helper", ["30"])
        defer { [brew, bundle].forEach { $0.terminate(); $0.waitUntilExit() } }
        XCTAssertTrue(DaemonProcess.looksLikeVoxtype(brew.processIdentifier))
        XCTAssertTrue(DaemonProcess.looksLikeVoxtype(bundle.processIdentifier))
        XCTAssertTrue(DaemonProcess.isVoxtypeExecutable("/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"))
        XCTAssertTrue(DaemonProcess.isVoxtypeExecutable("/Users/dev/voxtype/target/release/voxtype"))
    }

    func testUnrelatedProcessBehindReusedPIDIsRejected() throws {
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate(); other.waitUntilExit() }
        XCTAssertFalse(DaemonProcess.looksLikeVoxtype(other.processIdentifier))
        XCTAssertFalse(DaemonProcess.isVoxtypeExecutable("/usr/local/bin/voxtype-notes"))
        XCTAssertFalse(DaemonProcess.isVoxtypeExecutable("/Applications/NotVoxtype.app/Contents/MacOS/x"))
    }

    func testLookupFailureTrustsLiveness() {
        XCTAssertTrue(DaemonProcess.looksLikeVoxtype(12345, executablePath: { _ in nil }))
        XCTAssertFalse(DaemonProcess.looksLikeVoxtype(12345, executablePath: { _ in "/bin/sleep" }))
    }

    func testDaemonInvocationIgnoresOneShotCommands() {
        XCTAssertTrue(DaemonProcess.isDaemonInvocation(["/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"]))
        XCTAssertTrue(DaemonProcess.isDaemonInvocation(["voxtype", "daemon"]))
        XCTAssertTrue(DaemonProcess.isDaemonInvocation(["voxtype", "-c", "/tmp/record.toml", "-v"]))
        XCTAssertFalse(DaemonProcess.isDaemonInvocation(["voxtype-bin", "record", "toggle"]))
        XCTAssertFalse(DaemonProcess.isDaemonInvocation(["voxtype-bin", "menubar"]))
        XCTAssertFalse(DaemonProcess.isDaemonInvocation(["voxtype", "--config", "x.toml", "info", "models"]))
    }

    func testLiveDaemonScanFindsProcessesWithoutPIDFiles() throws {
        // `bash -c …` (/bin/sh re-execs another shell) parses like `voxtype -c <config>`: a daemon invocation with no subcommand.
        // The trailing `:` keeps bash from exec-ing sleep, so the process stays `voxtype-bin`.
        let daemon = try launchCopy(of: "/bin/bash", at: "dev/voxtype-bin", ["-c", "sleep 30; :"])
        defer { daemon.terminate(); daemon.waitUntilExit() }
        XCTAssertEqual(ProcessIdentity.arguments(pid: daemon.processIdentifier)?.dropFirst().first, "-c")
        let pids = DaemonProcess.liveDaemonPIDs()
        XCTAssertTrue(pids.contains(daemon.processIdentifier))
        XCTAssertFalse(pids.contains(ProcessInfo.processInfo.processIdentifier))
    }
}

final class DaemonRestartTests: XCTestCase {
    private let bundle = "/Applications/Voxtype.app"

    func testRestartRefusesWhenADaemonRunsFromAnotherInstall() {
        let brew = DaemonProcess.restartPlan(
            liveDaemons: [(101, "/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"), (202, "/opt/homebrew/Cellar/voxtype/1.0.1/bin/voxtype")],
            bundlePath: bundle
        )
        XCTAssertEqual(brew, .refuse(foreignPath: "/opt/homebrew/Cellar/voxtype/1.0.1/bin/voxtype"))
        XCTAssertEqual(DaemonProcess.restartPlan(liveDaemons: [(7, "/Users/me/Applications/Voxtype.app/Contents/MacOS/voxtype-bin")], bundlePath: bundle),
                       .refuse(foreignPath: "/Users/me/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"))
        // A look-alike bundle name is not the bundle.
        XCTAssertEqual(DaemonProcess.restartPlan(liveDaemons: [(8, "/Applications/Voxtype.app2/voxtype-bin")], bundlePath: bundle),
                       .refuse(foreignPath: "/Applications/Voxtype.app2/voxtype-bin"))
    }

    func testRestartTerminatesBundleDaemonsOrNothing() {
        XCTAssertEqual(DaemonProcess.restartPlan(liveDaemons: [], bundlePath: bundle), .terminate([]))
        XCTAssertEqual(DaemonProcess.restartPlan(
            liveDaemons: [(101, "/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"), (102, "/Applications/Voxtype.app/Contents/MacOS/voxtype-bin")],
            bundlePath: bundle + "/"
        ), .terminate([101, 102]))
    }

    private func spawn(_ exe: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        usleep(100_000) // let bash install its trap
        return p
    }

    func testTerminateStopsFixtureProcessesAndEscalatesToKill() throws {
        let polite = try spawn("/bin/sleep", ["30"])
        let stubborn = try spawn("/bin/bash", ["-c", "trap '' TERM; while :; do sleep 0.05; done"])
        defer { [polite, stubborn].forEach { if $0.isRunning { $0.terminate() } } }
        let start = Date()
        let survivors = DaemonProcess.terminate([polite.processIdentifier, stubborn.processIdentifier], grace: 0.3, killWait: 1)
        XCTAssertEqual(survivors, [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        polite.waitUntilExit()
        stubborn.waitUntilExit()
        XCTAssertEqual(polite.terminationReason, .uncaughtSignal)
        XCTAssertEqual(stubborn.terminationStatus, SIGKILL, "TERM was ignored, so KILL was required")
        XCTAssertEqual(DaemonProcess.terminate([]), [])
    }
}
