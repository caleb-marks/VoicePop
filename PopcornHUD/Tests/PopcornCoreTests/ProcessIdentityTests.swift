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
