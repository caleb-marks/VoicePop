import CFNetwork
import Foundation

public struct OllamaClient {
    public let endpoint: String
    public let model: String
    public let timeoutMs: Int

    /// Result of one HTTP exchange, keeping timeouts distinct from refused connections.
    public enum SendResult {
        case response(Data?, HTTPURLResponse)
        case timedOut
        case failed
    }

    /// Performs a loopback-guarded request within `timeoutMs`. Injectable for tests.
    public typealias Sender = (URLRequest, Int) -> SendResult

    /// Why polishing did or did not replace the rules output. Never carries transcript text.
    public enum PolishOutcome: Equatable {
        case polished(String)
        case invalidEndpoint
        case unavailable
        case timedOut
        case httpError(Int)
        /// The model answered, but the answer failed validation or was cut off.
        case rejected

        public var text: String? {
            if case .polished(let t) = self { return t }
            return nil
        }

        /// Stable token for timing logs.
        public var timingName: String {
            switch self {
            case .polished: return "used"
            case .invalidEndpoint: return "invalid-endpoint"
            case .unavailable: return "unavailable"
            case .timedOut: return "timeout"
            case .httpError: return "http-error"
            case .rejected: return "rejected"
            }
        }
    }

    private let sender: Sender

    public init(endpoint: String, model: String, timeoutMs: Int, sender: Sender? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.timeoutMs = timeoutMs
        self.sender = sender ?? { Self.sendDetailed($0, timeoutMs: $1) }
    }

    public init(prefs: LLMPrefs) {
        self.init(endpoint: prefs.endpoint, model: prefs.model, timeoutMs: prefs.timeoutMs)
    }

    public static func isLoopbackURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              let rawHost = components.host?.lowercased()
        else { return false }

        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        var parsed: [Int] = []
        for octet in octets {
            guard !octet.isEmpty,
                  (octet.count == 1 || octet.first != "0"),
                  octet.allSatisfy(\.isNumber),
                  let value = Int(octet),
                  (0...255).contains(value)
            else { return false }
            parsed.append(value)
        }
        return parsed.first == 127
    }

    static func requestURL(endpoint: String, path: String) -> URL? {
        guard var components = URLComponents(string: endpoint),
              components.query == nil,
              components.fragment == nil,
              let base = components.url,
              isLoopbackURL(base)
        else { return nil }
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let prefix = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = prefix + suffix
        guard let result = components.url, isLoopbackURL(result) else { return nil }
        return result
    }

    static func guardedRedirect(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, isLoopbackURL(url) else { return nil }
        return request
    }

    public func isUp(timeoutMs: Int = 300) -> Bool {
        guard let url = Self.requestURL(endpoint: endpoint, path: "/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard case .response(_, let response) = sender(request, timeoutMs) else { return false }
        return (200...299).contains(response.statusCode)
    }

    public func warm() -> Bool {
        guard let url = Self.requestURL(endpoint: endpoint, path: "/api/generate") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "keep_alive": "5m",
        ])
        guard case .response(_, let response) = sender(request, 10_000) else { return false }
        return (200...299).contains(response.statusCode)
    }

    public func polish(text: String, glossary: [String], examples: [CorrectionEntry], budgetMs: Int? = nil) -> String? {
        polishDetailed(text: text, glossary: glossary, examples: examples, budgetMs: budgetMs).text
    }

    /// Bounded by `budgetMs` (or `timeoutMs`): a slow or missing model yields a non-`.polished`
    /// outcome in time for the caller to fall back to its rules output.
    public func polishDetailed(text: String, glossary: [String], examples: [CorrectionEntry], budgetMs: Int? = nil) -> PolishOutcome {
        guard let url = Self.requestURL(endpoint: endpoint, path: "/api/chat") else { return .invalidEndpoint }
        let system = Self.systemPrompt(glossary: glossary, examples: examples)
        func body(includeThink: Bool) -> Data? {
            var obj: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": text],
                ],
                "stream": false,
                "keep_alive": "5m",
                "options": ["temperature": 0, "num_predict": 256],
            ]
            if includeThink { obj["think"] = false }
            return try? JSONSerialization.data(withJSONObject: obj)
        }

        let start = Date()
        func remaining() -> Int {
            if let budgetMs {
                return max(0, budgetMs - Int(Date().timeIntervalSince(start) * 1000))
            }
            return timeoutMs
        }

        func post(_ data: Data, timeoutMs: Int) -> SendResult {
            guard timeoutMs > 0 else { return .timedOut }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            return sender(request, timeoutMs)
        }

        guard let firstBody = body(includeThink: true) else { return .rejected }
        var result = post(firstBody, timeoutMs: remaining())
        if case .response(_, let r) = result, r.statusCode == 400, remaining() >= 1000,
           let retryBody = body(includeThink: false) {
            result = post(retryBody, timeoutMs: remaining())
        }
        let data: Data?
        switch result {
        case .timedOut: return .timedOut
        case .failed: return .unavailable
        case .response(let d, let r):
            guard (200...299).contains(r.statusCode) else { return .httpError(r.statusCode) }
            data = d
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return .rejected }
        if let reason = json["done_reason"] as? String, reason != "stop" {
            return .rejected
        }
        let cleaned = Self.sanitize(content)
        return Self.validate(input: text, output: cleaned, glossary: glossary) ? .polished(cleaned) : .rejected
    }

    public static func systemPrompt(glossary: [String], examples: [CorrectionEntry]) -> String {
        var parts = [
            "You clean up dictated speech-to-text into formal written English. Return only the corrected text on one line, with no quotes, no explanation, and no markdown. Preserve the speaker's words, order, and meaning; do not paraphrase, summarize, add, or remove content. Fix only speech-recognition errors, capitalization, and punctuation. Use complete sentences with standard capitalization and end punctuation.",
        ]
        if !glossary.isEmpty {
            parts.append("Always spell these terms exactly as written: " + glossary.joined(separator: ", "))
        }
        if !examples.isEmpty {
            parts.append("Examples of this speaker's own corrections, before -> after:")
            for e in examples {
                parts.append("\"\(e.typed)\" -> \"\(e.corrected)\"")
            }
        }
        return parts.joined(separator: "\n")
    }

    public static func sanitize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let re = try? NSRegularExpression(pattern: #"<think>[\s\S]*?</think>"#, options: .caseInsensitive) {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "")
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs: [(Character, Character)] = [
            ("\"", "\""),
            ("\u{201C}", "\u{201D}"),
            ("'", "'"),
            ("\u{2018}", "\u{2019}"),
        ]
        for (left, right) in pairs {
            if out.count >= 2, out.first == left, out.last == right {
                let interior = out.dropFirst().dropLast()
                if !interior.contains(left) && !interior.contains(right) {
                    out.removeFirst()
                    out.removeLast()
                    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }
        return out
    }

    public static func validate(input: String, output: String, glossary: [String]) -> Bool {
        if output.isEmpty { return false }
        if output.contains("\n") || output.contains("```") { return false }
        let inWords = input.split(whereSeparator: \.isWhitespace)
        let outWords = output.split(whereSeparator: \.isWhitespace)
        if inWords.count <= 3 {
            if output.count < input.count / 2 || output.count > input.count + 8 { return false }
        } else {
            let denom = Double(inWords.count)
            let ratio = Double(outWords.count) / denom
            if ratio < 0.6 || ratio > 1.6 { return false }
        }
        for term in glossary {
            let present = input.range(of: term, options: .caseInsensitive) != nil
            if present, output.range(of: term, options: .caseInsensitive) == nil {
                return false
            }
        }
        return true
    }

    private final class SendBox {
        let lock = NSLock()
        var data: Data?
        var response: HTTPURLResponse?
        var timedOut = false
    }

    static func send(_ request: URLRequest, timeoutMs: Int) -> (Data?, HTTPURLResponse?) {
        if case .response(let data, let response) = sendDetailed(request, timeoutMs: timeoutMs) {
            return (data, response)
        }
        return (nil, nil)
    }

    public static func sendDetailed(_ request: URLRequest, timeoutMs: Int) -> SendResult {
        var req = request
        guard let url = req.url, isLoopbackURL(url) else { return .failed }
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        let sem = DispatchSemaphore(value: 0)
        let box = SendBox()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
        ]
        let session = URLSession(configuration: configuration, delegate: LoopbackRedirectGuard(), delegateQueue: nil)
        let task = session.dataTask(with: req) { d, r, e in
            box.lock.lock()
            box.data = d
            box.response = r as? HTTPURLResponse
            box.timedOut = (e as? URLError)?.code == .timedOut
            box.lock.unlock()
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return .timedOut
        }
        session.finishTasksAndInvalidate()
        box.lock.lock()
        defer { box.lock.unlock() }
        if let response = box.response { return .response(box.data, response) }
        return box.timedOut ? .timedOut : .failed
    }
}

private final class LoopbackRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(OllamaClient.guardedRedirect(request))
    }
}
