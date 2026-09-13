import Foundation
import PopcornCore

// timing-report [timing.log] [--voxtype-log ~/Library/Logs/voxtype/stdout.log] [--since 2026-09-12T20:00:00Z]
//
// Prints n / p50 / p95 / max per pipeline interval. Only timestamps and fixed event names are
// read from the Voxtype log; its message text (which can contain transcripts) is discarded.

@main
enum TimingReportMain {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return v
        }
        let voxtypePath = take("--voxtype-log")
        let since = take("--since").flatMap { TimingReport.parse(line: "\($0) mono=0 proc=x event=x")?.wall }
        let logPath = args.first ?? Timing.logURL.path

        let text = try String(contentsOfFile: logPath, encoding: .utf8)
        var events = text.split(whereSeparator: \.isNewline).compactMap { TimingReport.parse(line: String($0)) }
        var voxtype: [VoxtypeLogEvent] = []
        if let voxtypePath {
            let raw = try String(contentsOfFile: (voxtypePath as NSString).expandingTildeInPath, encoding: .utf8)
            voxtype = raw.split(whereSeparator: \.isNewline).compactMap { TimingReport.parseVoxtypeLog(line: String($0)) }
        }
        if let since {
            events = events.filter { $0.wall >= since }
            voxtype = voxtype.filter { $0.wall >= since }
        }
        print("# \(events.count) VoicePop events from \(logPath)" + (voxtypePath == nil ? "" : ", \(voxtype.count) Voxtype timestamps"))
        print(TimingReport.render(TimingReport.analyze(events: events, voxtype: voxtype)), terminator: "")
    }
}
