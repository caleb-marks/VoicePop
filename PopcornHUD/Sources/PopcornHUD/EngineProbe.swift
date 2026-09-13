import Foundation
import PopcornCore

/// Read-only engine inspection for `DictationHealthMonitor`. Blocking; call off the main thread.
/// Uses only `voxtype-bin config get` / `info … --json`, a model-directory listing, and a read of
/// Voxtype's config file. Every child process is bounded by a timeout.
enum EngineProbe {
    static let modelsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/voxtype/models")
    static let configFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voxtype/config.toml")

    static func probe() -> EngineProbeResult {
        let bin = EngineControl.voxtypeBin
        var result = EngineProbeResult(binaryInstalled: FileManager.default.isExecutableFile(atPath: bin))
        guard result.binaryInstalled else { return result }

        let engine = run(bin, ["config", "get", "engine"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.configuredEngine = (engine?.isEmpty ?? true) ? nil : engine
        let key = (result.configuredEngine ?? "whisper") + ".model"
        let model = run(bin, ["config", "get", key])?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.configuredModel = (model?.isEmpty ?? true) ? nil : model
        if let model = result.configuredModel, model.hasPrefix("/") {
            result.configuredModelPathExists = FileManager.default.fileExists(atPath: model)
        }

        if let data = run(bin, ["info", "engines", "--json"])?.data(using: .utf8),
           let engines = try? JSONDecoder().decode([EngineJSON].self, from: data) {
            result.compiledEngines = Dictionary(engines.map { ($0.name, $0.compiled) }, uniquingKeysWith: { a, _ in a })
        }
        if let data = run(bin, ["info", "models", "--json"])?.data(using: .utf8),
           let models = try? JSONDecoder().decode(ModelsJSON.self, from: data) {
            result.catalog = models.engines.mapValues { engine in
                Dictionary(engine.models.map { ($0.name, $0.installed) }, uniquingKeysWith: { a, b in a || b })
            }
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path) {
            result.localModelEntries = Set(entries)
        }
        if let text = try? String(contentsOf: configFile, encoding: .utf8) {
            result.postProcessIsVoicePop = VoxtypeConfigScan.postProcessCommand(in: text)?.contains("voxtype-clean") ?? false
        }
        return result
    }

    /// Runs a child with stdout captured; nil on launch failure, non-zero exit, or timeout.
    static func run(_ bin: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do {
            try task.run()
        } catch {
            return nil
        }
        // Drain while the child runs so a full pipe cannot deadlock it.
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            _ = exited.wait(timeout: .now() + 1)
            _ = drained.wait(timeout: .now() + 1)
            Timing.event("probe.timeout", ["cmd": args.first ?? ""])
            return nil
        }
        guard drained.wait(timeout: .now() + 1) == .success, task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct EngineJSON: Decodable {
        let name: String
        let compiled: Bool
    }

    private struct ModelsJSON: Decodable {
        struct Engine: Decodable {
            struct Model: Decodable {
                let name: String
                let installed: Bool
            }
            let models: [Model]
        }
        let engines: [String: Engine]
    }
}
