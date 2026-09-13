import XCTest
@testable import PopcornCore

final class ProbeFingerprintTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testStableWhileInputsUnchanged() throws {
        let file = try tempFile("engine = \"parakeet\"\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let a = ProbeFingerprint(paths: [file.path, "/definitely/missing/path"])
        let b = ProbeFingerprint(paths: [file.path, "/definitely/missing/path"])
        XCTAssertEqual(a, b)
    }

    func testChangesWhenFileContentSizeChanges() throws {
        let file = try tempFile("engine = \"parakeet\"\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let before = ProbeFingerprint(paths: [file.path])
        try "engine = \"whisper\"\n# edited\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(before, ProbeFingerprint(paths: [file.path]))
    }

    func testChangesWhenMissingFileAppears() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missing = ProbeFingerprint(paths: [url.path])
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotEqual(missing, ProbeFingerprint(paths: [url.path]))
    }

    func testOrderMatters() throws {
        let a = try tempFile("a"), b = try tempFile("b")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        XCTAssertNotEqual(ProbeFingerprint(paths: [a.path, b.path]), ProbeFingerprint(paths: [b.path, a.path]))
    }
}
