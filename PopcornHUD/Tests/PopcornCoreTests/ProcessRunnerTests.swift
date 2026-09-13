import Foundation
import XCTest
@testable import PopcornCore

final class ProcessRunnerTests: XCTestCase {
    func testCapturesLargeStdoutAndStderrWithoutDeadlock() throws {
        // 2 MB on each stream would block a child whose pipes are not drained concurrently.
        let r = try ProcessRunner.run("/bin/sh", ["-c", "head -c 2000000 /dev/zero; head -c 2000000 /dev/zero >&2; exit 3"], timeout: 10)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.status, 3)
        XCTAssertFalse(r.succeeded)
        XCTAssertEqual(r.stdout.count, 2_000_000)
        XCTAssertEqual(r.stderr.count, 2_000_000)
    }

    func testDiscardedOutputsStillLetChattyChildrenFinish() throws {
        let r = try ProcessRunner.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero; head -c 3000000 /dev/zero >&2"],
                                      timeout: 10, stdout: .discard, stderr: .discard)
        XCTAssertTrue(r.succeeded)
        XCTAssertTrue(r.stdout.isEmpty)
        XCTAssertTrue(r.stderr.isEmpty)
    }

    func testTimeoutTerminatesTheChild() throws {
        let start = Date()
        let r = try ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.3)
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testTimeoutEscalatesToKillWhenTermIsIgnored() throws {
        let start = Date()
        let r = try ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 3 & wait"], timeout: 0.2, stdout: .discard, stderr: .discard)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.5)
    }

    func testStdoutLinesStreamAsTheyArrive() throws {
        var lines: [String] = []
        let lock = NSLock()
        let r = try ProcessRunner.run("/bin/sh", ["-c", "printf 'a\\nb\\n'; sleep 0.05; printf 'c'"], timeout: 5) { line in
            lock.lock(); lines.append(line); lock.unlock()
        }
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(lines, ["a", "b", "c"])
        XCTAssertEqual(r.stdoutText, "a\nb\nc")
    }

    func testNoLinesAreDeliveredAfterReturn() throws {
        // A grandchild keeps stdout open and keeps printing after the child exits.
        var lines: [String] = []
        let lock = NSLock()
        let r = try ProcessRunner.run("/bin/bash", ["-c", "(for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo late$i; sleep 0.1; done) & echo early"],
                                      timeout: 5, stdout: .discard) { line in
            lock.lock(); lines.append(line); lock.unlock()
        }
        XCTAssertTrue(r.succeeded)
        lock.lock(); let atReturn = lines.count; lock.unlock()
        usleep(600_000)
        lock.lock(); let later = lines.count; lock.unlock()
        XCTAssertEqual(atReturn, later, "lines arriving after return must be dropped")
        XCTAssertEqual(lines.first, "early")
    }

    func testLaunchFailureThrows() {
        XCTAssertThrowsError(try ProcessRunner.run("/nonexistent/voxtype-bin", ["info"], timeout: 1))
        XCTAssertFalse(ProcessRunner.spawnDetached("/nonexistent/voxtype-bin"))
    }
}
