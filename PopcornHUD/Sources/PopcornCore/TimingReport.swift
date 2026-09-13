import Foundation

/// One line of the VoicePop timing log (see `Timing`).
public struct TimingLogEvent: Equatable, Sendable {
    public var wall: Date
    public var monoMs: Double
    public var proc: String
    public var name: String
    public var fields: [String: String]

    public init(wall: Date, monoMs: Double, proc: String, name: String, fields: [String: String] = [:]) {
        self.wall = wall
        self.monoMs = monoMs
        self.proc = proc
        self.name = name
        self.fields = fields
    }
}

/// Timestamp-only facts from Voxtype's own daemon log. Everything after the fixed message
/// prefix (which can include transcript text) is discarded while parsing.
public struct VoxtypeLogEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case recordingStarted, recordingStopped, typed
    }

    public var wall: Date
    public var kind: Kind

    public init(wall: Date, kind: Kind) {
        self.wall = wall
        self.kind = kind
    }
}

/// Turns timing logs into per-interval p50/p95. Pure; used by `Benchmarks/timing-report`.
public enum TimingReport {
    public struct Row: Equatable, Sendable {
        public var name: String
        public var unit: String
        public var values: [Double]

        public var p50: Double { TimingReport.percentile(values, 0.50) }
        public var p95: Double { TimingReport.percentile(values, 0.95) }
        public var max: Double { values.max() ?? .nan }
    }

    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
    }

    // MARK: Parsing

    public static func parse(line: String) -> TimingLogEvent? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4, let wall = parseWall(String(parts[0])) else { return nil }
        var fields: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        guard let mono = fields.removeValue(forKey: "mono").flatMap(Double.init),
              let proc = fields.removeValue(forKey: "proc"),
              let name = fields.removeValue(forKey: "event")
        else { return nil }
        return TimingLogEvent(wall: wall, monoMs: mono, proc: proc, name: name, fields: fields)
    }

    public static func parseVoxtypeLog(line: String) -> VoxtypeLogEvent? {
        // "<timestamp> <LEVEL> <message>": match only the start of the message.
        let parts = stripANSI(line).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        let message = parts[2]
        let kind: VoxtypeLogEvent.Kind
        if message.hasPrefix("Recording started") {
            kind = .recordingStarted
        } else if message.hasPrefix("Recording stopped") {
            kind = .recordingStopped
        } else if message.hasPrefix("Text typed via ") {
            kind = .typed
        } else {
            return nil
        }
        guard let wall = parseWall(String(parts[0])) else { return nil }
        return VoxtypeLogEvent(wall: wall, kind: kind)
    }

    static func stripANSI(_ s: String) -> String {
        var out = ""
        var inEscape = false
        for ch in s {
            if inEscape {
                if ch.isLetter { inEscape = false }
                continue
            }
            if ch == "\u{1B}" {
                inEscape = true
                continue
            }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// ISO-8601 UTC with any number of fractional digits (VoicePop writes ms, Voxtype µs).
    static func parseWall(_ s: String) -> Date? {
        guard s.hasSuffix("Z"), s.count >= 20 else { return nil }
        let body = s.dropLast()
        let (whole, frac): (Substring, Substring) = {
            if let dot = body.firstIndex(of: ".") {
                return (body[..<dot], body[body.index(after: dot)...])
            }
            return (body, "")
        }()
        guard let base = wholeFormatter.date(from: String(whole) + "Z") else { return nil }
        guard !frac.isEmpty else { return base }
        guard frac.allSatisfy(\.isNumber), let digits = Double("0." + frac) else { return nil }
        return base.addingTimeInterval(digits)
    }

    private static let wholeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Analysis

    public static func analyze(events unsorted: [TimingLogEvent], voxtype: [VoxtypeLogEvent] = []) -> [Row] {
        let events = unsorted.sorted { $0.monoMs < $1.monoMs }
        var rows: [String: Row] = [:]
        var order: [String] = []
        func add(_ name: String, _ value: Double, unit: String = "ms") {
            guard value.isFinite, value >= 0 else { return }
            if rows[name] == nil {
                rows[name] = Row(name: name, unit: unit, values: [])
                order.append(name)
            }
            rows[name]?.values.append(value)
        }
        func daemon(_ kind: VoxtypeLogEvent.Kind, from: Date, to: Date, latest: Bool) -> VoxtypeLogEvent? {
            let hits = voxtype.filter { $0.kind == kind && $0.wall >= from && $0.wall <= to }
            return latest ? hits.max { $0.wall < $1.wall } : hits.min { $0.wall < $1.wall }
        }

        let hot: Set<String> = ["recording", "streaming"]
        var lastRequest: Double?
        var recStart: TimingLogEvent?
        var daemonStart: Date?
        var delivered = false, visible = false, framed = false
        var release: (event: TimingLogEvent, durationMs: Double)?
        var cleanStart: TimingLogEvent?
        var lastCleanDone: TimingLogEvent?

        for e in events {
            switch (e.proc, e.name) {
            case (_, "record.request"):
                lastRequest = e.monoMs

            case ("hud", "state.observed"):
                let from = e.fields["from"] ?? "", to = e.fields["to"] ?? ""
                if hot.contains(to), !hot.contains(from) {
                    recStart = e
                    delivered = false; visible = false; framed = false
                    release = nil; cleanStart = nil
                    if let r = lastRequest, e.monoMs - r <= 3000 {
                        add("menu request → recording state observed", e.monoMs - r)
                    }
                    lastRequest = nil
                    daemonStart = daemon(.recordingStarted, from: e.wall.addingTimeInterval(-3), to: e.wall.addingTimeInterval(0.05), latest: true)?.wall
                    if let d = daemonStart {
                        add("Voxtype 'Recording started' → state observed (wall clock)", e.wall.timeIntervalSince(d) * 1000)
                    }
                } else if hot.contains(from), !hot.contains(to), let start = recStart {
                    let duration = e.monoMs - start.monoMs
                    release = (e, duration)
                    add("recording duration", duration)
                    if let stop = daemon(.recordingStopped, from: e.wall.addingTimeInterval(-3), to: e.wall.addingTimeInterval(0.05), latest: true) {
                        add("Voxtype 'Recording stopped' → state left recording (wall clock)", e.wall.timeIntervalSince(stop.wall) * 1000)
                    }
                    recStart = nil
                }

            case ("hud", "state.delivered"):
                if let start = recStart, !delivered, hot.contains(e.fields["state"] ?? "") {
                    delivered = true
                    add("recording state observed → main-queue delivery", e.monoMs - start.monoMs)
                }

            case ("hud", "hud.visible"):
                if let start = recStart, !visible {
                    visible = true
                    add("recording state observed → first visible publish", e.monoMs - start.monoMs)
                }

            case ("hud", "hud.frame"):
                if let start = recStart, !framed {
                    framed = true
                    add("recording state observed → first frame tick after publish", e.monoMs - start.monoMs)
                    if let d = daemonStart {
                        add("Voxtype 'Recording started' → first frame tick (wall clock)", e.wall.timeIntervalSince(d) * 1000)
                    }
                }

            case ("hud", "audio.react"):
                if let v = e.fields["ms"].flatMap(Double.init) { add("fresh audio packet → HUD publish", v) }

            case ("hud", "hud.publish"):
                if let v = e.fields["us"].flatMap(Double.init) { add("HUD view publish (rootView assignment)", v, unit: "µs") }

            case ("hud", "hud.tick"):
                if let v = e.fields["us"].flatMap(Double.init) { add("HUD tick main-thread work", v, unit: "µs") }

            case ("clean", "clean.start"):
                cleanStart = e
                if let r = release {
                    add("state left recording → voxtype-clean start (recognition done)", e.monoMs - r.event.monoMs)
                }

            case ("clean", "clean.done"):
                let llm = e.fields["llm"] ?? "unknown"
                lastCleanDone = e
                if let s = cleanStart {
                    add("voxtype-clean start → text ready [llm=\(llm)]", e.monoMs - s.monoMs)
                }
                if let r = release {
                    add("state left recording → text ready [llm=\(llm)]", e.monoMs - r.event.monoMs)
                    if (3000...10_000).contains(r.durationMs) {
                        add("3–10 s utterance: state left recording → text ready [llm=\(llm)]", e.monoMs - r.event.monoMs)
                    }
                    release = nil
                }
                cleanStart = nil
                if let typed = daemon(.typed, from: e.wall.addingTimeInterval(-0.05), to: e.wall.addingTimeInterval(10), latest: false) {
                    add("text ready → Voxtype reports keystrokes posted (NOT verified insertion; wall clock)", typed.wall.timeIntervalSince(e.wall) * 1000)
                }

            case ("hud", "transcript.ready"):
                if let d = lastCleanDone {
                    add("text ready → HUD notified", e.monoMs - d.monoMs)
                    lastCleanDone = nil
                }

            default:
                break
            }
        }
        return order.compactMap { rows[$0] }
    }

    public static func render(_ rows: [Row]) -> String {
        func f(_ v: Double) -> String { v.isFinite ? String(format: "%.1f", v) : "-" }
        var out = String(format: "%-86@ %5@ %9@ %9@ %9@\n", "interval" as NSString, "n" as NSString,
                         "p50" as NSString, "p95" as NSString, "max" as NSString)
        for r in rows {
            out += String(format: "%-86@ %5d %9@ %9@ %9@\n", "\(r.name) (\(r.unit))" as NSString, r.values.count,
                          f(r.p50) as NSString, f(r.p95) as NSString, f(r.max) as NSString)
        }
        return out
    }
}
