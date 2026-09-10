import Foundation

public enum TextClean {
    public static let terminalMarkers = [
        "terminal", "iterm", "alacritty", "kitty", "ghostty", "warp", "wezterm",
    ]

    public static func isTerminal(_ app: String) -> Bool {
        let lower = app.lowercased()
        return terminalMarkers.contains { lower.contains($0) }
    }

    public static func clean(_ text: String, app: String) -> String {
        clean(text, app: app, style: .auto)
    }

    public static func clean(_ text: String, app: String, style: Style) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([,.;:!?\])}])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([(\[{])\s+"#, with: "$1", options: .regularExpression)
        guard !out.isEmpty else { return out }
        switch style {
        case .auto:
            // Terminals are verbatim only in Automatic; an explicit Casual/Formal choice wins.
            if isTerminal(app) { return out }
            let first = out.prefix(1).uppercased()
            out = first + out.dropFirst()
            return out
        case .casual:
            return applyCasual(out)
        case .formal:
            return applyFormalRules(out)
        }
    }

    public static func applyCasual(_ s: String) -> String {
        var out = s.lowercased()
        if out.hasSuffix(".") && !out.hasSuffix("..") {
            out.removeLast()
        }
        return out
    }

    public static func applyFormalRules(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let lower = s.lowercased()
        var out = s
        if !lower.hasPrefix("i.e.") && !lower.hasPrefix("e.g.") {
            out = String(s.prefix(1)).uppercased() + s.dropFirst()
        }
        if let re = try? NSRegularExpression(pattern: #"([.!?]\s+)(\p{L})"#) {
            let ns = out as NSString
            let matches = re.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() where match.numberOfRanges >= 3 {
                let punctRange = match.range(at: 1)
                if punctRange.location >= 3 {
                    let before = ns.substring(with: NSRange(location: punctRange.location - 3, length: 3)).lowercased()
                    if before == "i.e" || before == "e.g" { continue }
                }
                let letterRange = match.range(at: 2)
                if let swiftRange = Range(letterRange, in: out) {
                    out.replaceSubrange(swiftRange, with: out[swiftRange].uppercased())
                }
            }
        }
        out = out.replacingOccurrences(
            of: #"(?<![\p{L}\p{N}/-])(?<!\p{L}\.)i(?![\p{L}\p{N}/-])(?!\.\p{L})"#,
            with: "I",
            options: .regularExpression
        )
        guard let last = out.last else { return out }
        if last == "," || last == ";" || last == ":" {
            out.removeLast()
            out.append(".")
        } else if last.isLetter || last.isNumber || last == ")" || last == "]"
            || last == "\"" || last == "'" || last == "\u{201D}" || last == "\u{2019}"
        {
            out.append(".")
        }
        return out
    }
}
