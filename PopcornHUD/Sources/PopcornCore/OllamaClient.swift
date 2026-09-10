import Foundation

public struct OllamaClient {
    public let endpoint: String
    public let model: String
    public let timeoutMs: Int

    public init(endpoint: String, model: String, timeoutMs: Int) {
        self.endpoint = endpoint
        self.model = model
        self.timeoutMs = timeoutMs
    }

    public init(prefs: LLMPrefs) {
        self.init(endpoint: prefs.endpoint, model: prefs.model, timeoutMs: prefs.timeoutMs)
    }

    public func isUp(timeoutMs: Int = 300) -> Bool {
        guard let url = URL(string: endpoint + "/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (_, response) = Self.send(request, timeoutMs: timeoutMs)
        guard let response else { return false }
        return (200...299).contains(response.statusCode)
    }

    public func warm() -> Bool {
        guard let url = URL(string: endpoint + "/api/generate") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "keep_alive": "5m",
        ])
        let (_, response) = Self.send(request, timeoutMs: 10_000)
        guard let response else { return false }
        return (200...299).contains(response.statusCode)
    }

    public func polish(text: String, glossary: [String], examples: [CorrectionEntry], budgetMs: Int? = nil) -> String? {
        guard let url = URL(string: endpoint + "/api/chat") else { return nil }
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

        func post(_ data: Data, timeoutMs: Int) -> (Data?, HTTPURLResponse?) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            return Self.send(request, timeoutMs: timeoutMs)
        }

        guard let firstBody = body(includeThink: true) else { return nil }
        var (data, response) = post(firstBody, timeoutMs: remaining())
        if response?.statusCode == 400, remaining() >= 1000, let retryBody = body(includeThink: false) {
            (data, response) = post(retryBody, timeoutMs: remaining())
        }
        guard let data,
              let response,
              (200...299).contains(response.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        if let reason = json["done_reason"] as? String, reason != "stop" {
            return nil
        }
        let cleaned = Self.sanitize(content)
        return Self.validate(input: text, output: cleaned, glossary: glossary) ? cleaned : nil
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
    }

    static func send(_ request: URLRequest, timeoutMs: Int) -> (Data?, HTTPURLResponse?) {
        var req = request
        req.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        let sem = DispatchSemaphore(value: 0)
        let box = SendBox()
        let task = URLSession.shared.dataTask(with: req) { d, r, _ in
            box.lock.lock()
            box.data = d
            box.response = r as? HTTPURLResponse
            box.lock.unlock()
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            task.cancel()
            return (nil, nil)
        }
        box.lock.lock()
        defer { box.lock.unlock() }
        return (box.data, box.response)
    }
}
