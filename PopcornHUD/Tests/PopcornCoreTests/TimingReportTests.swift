import Foundation
import XCTest
@testable import PopcornCore

final class TimingReportTests: XCTestCase {
    func testLongRunningSinkRotatesByByteCount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-timing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("timing.log")
        let savedLimit = Timing.rotateBytes
        Timing.resetSinkForTesting()
        Timing.rotateBytes = 500
        defer {
            Timing.rotateBytes = savedLimit
            Timing.resetSinkForTesting()
            try? FileManager.default.removeItem(at: dir)
        }
        let line = String(repeating: "x", count: 99) + "\n"
        for _ in 0..<12 { Timing.append(line, to: url) } // 1200 bytes through one open sink
        let size = { (path: String) in ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? -1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".1"), "rotated without reopening the process")
        XCTAssertLessThanOrEqual(size(url.path), 600)
        XCTAssertGreaterThan(size(url.path + ".1"), 500)
    }

    func testSinkIsOwnerOnlyAndRotates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-timing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("logs/timing.log")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644])
        XCTAssertEqual(truncate(url.path, Timing.rotateBytes + 1), 0)
        let fd = Timing.openSink(url)
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(fd)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attrs[.size] as? NSNumber)?.intValue, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".1"))

        let fresh = dir.appendingPathComponent("new/timing.log")
        let fd2 = Timing.openSink(fresh)
        XCTAssertGreaterThanOrEqual(fd2, 0)
        close(fd2)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: fresh.deletingLastPathComponent().path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
