import Darwin
import Foundation
import XCTest
@testable import PopcornCore

/// Minimal HTTP/1.1 server on 127.0.0.1 with a configurable delay, standing in for Ollama.
final class FakeOllamaServer {
    let port: UInt16
    private let fd: Int32
    var delayMs: UInt32 = 0
    var status = 200
    var body = #"{"message":{"content":"Hello there."},"done_reason":"stop"}"#

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(sock, 8) == 0 else { throw NSError(domain: "FakeOllamaServer", code: Int(errno)) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        fd = sock
        let listenFD = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listenFD, nil, nil)
                guard c >= 0 else { return }
                guard let self else { Darwin.close(c); return }
                let (delay, status, body) = (self.delayMs, self.status, self.body)
                Thread.detachNewThread {
                    var buf = [UInt8](repeating: 0, count: 65536)
                    _ = read(c, &buf, buf.count)
                    usleep(delay * 1000)
                    let response = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    _ = response.withCString { write(c, $0, strlen($0)) }
                    Darwin.close(c)
                }
            }
        }
    }

    var endpoint: String { "http://127.0.0.1:\(port)" }

    func close() { Darwin.close(fd) }
}

final class OllamaFallbackTests: XCTestCase {
    private let input = "hello there"

    func testPolishesFromLocalServer() throws {
        let server = try FakeOllamaServer()
        defer { server.close() }
        let client = OllamaClient(endpoint: server.endpoint, model: "m", timeoutMs: 2000)
        XCTAssertTrue(client.isUp(timeoutMs: 1000))
        XCTAssertEqual(client.polishDetailed(text: input, glossary: [], examples: [], budgetMs: 2000), .polished("Hello there."))
    }

    func testSlowModelTimesOutWithinBudget() throws {
        let server = try FakeOllamaServer()
        defer { server.close() }
        server.delayMs = 1500
        let client = OllamaClient(endpoint: server.endpoint, model: "m", timeoutMs: 5000)
        let start = Date()
        let outcome = client.polishDetailed(text: input, glossary: [], examples: [], budgetMs: 300)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertNil(outcome.text)
        XCTAssertLessThan(elapsed, 0.8, "the budget bounds the wait so voxtype-clean can fall back to rules output")
    }

    func testNothingListeningIsUnavailableQuickly() throws {
        let server = try FakeOllamaServer()
        let endpoint = server.endpoint
        server.close() // port now refuses connections
        let client = OllamaClient(endpoint: endpoint, model: "m", timeoutMs: 2000)
        let start = Date()
        XCTAssertFalse(client.isUp(timeoutMs: 300))
        XCTAssertEqual(client.polishDetailed(text: input, glossary: [], examples: [], budgetMs: 1000), .unavailable)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testHTTPErrorsAndInvalidAnswersAreRejected() throws {
        let server = try FakeOllamaServer()
        defer { server.close() }
        let client = OllamaClient(endpoint: server.endpoint, model: "m", timeoutMs: 2000)
        server.status = 500
        XCTAssertEqual(client.polishDetailed(text: input, glossary: [], examples: [], budgetMs: 2000), .httpError(500))
        server.status = 200
        server.body = #"{"message":{"content":"line one\nline two"},"done_reason":"stop"}"#
        XCTAssertEqual(client.polishDetailed(text: input, glossary: [], examples: [], budgetMs: 2000), .rejected)
        server.body = #"{"message":{"content":"Hello there."},"done_reason":"length"}"#
        XCTAssertEqual(client.polishDetailed(text: input, glossary: [], examples: [], budgetMs: 2000), .rejected)
    }

    func testInjectedSenderAndNonLoopbackGuard() {
        var calls: [(String, Int)] = []
        let client = OllamaClient(endpoint: "http://localhost:11434", model: "m", timeoutMs: 3500) { request, timeout in
            calls.append((request.url!.path, timeout))
            return .timedOut
        }
        XCTAssertEqual(client.polishDetailed(text: input, glossary: [], examples: [], budgetMs: 1200), .timedOut)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "/api/chat")
        XCTAssertLessThanOrEqual(calls.first?.1 ?? .max, 1200)

        let remote = OllamaClient(endpoint: "http://example.com:11434", model: "m", timeoutMs: 3500) { _, _ in
            XCTFail("non-loopback endpoints must never be contacted")
            return .failed
        }
        XCTAssertEqual(remote.polishDetailed(text: input, glossary: [], examples: [], budgetMs: 1200), .invalidEndpoint)
        XCTAssertFalse(remote.isUp())
    }

    func testExhaustedBudgetSkipsTheRequest() {
        let client = OllamaClient(endpoint: "http://127.0.0.1:11434", model: "m", timeoutMs: 3500) { _, _ in
            XCTFail("no request once the budget is spent")
            return .failed
        }
        XCTAssertEqual(client.polishDetailed(text: input, glossary: [], examples: [], budgetMs: 0), .timedOut)
    }
}
