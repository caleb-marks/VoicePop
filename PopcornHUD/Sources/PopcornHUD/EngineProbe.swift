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

    /// Spawn results are reused while the binary, Voxtype's config file, and the models directory are
    /// unchanged (mtime + size), capped at `cacheTTL`. Every field except `configuredModelPathExists`
    /// derives from those three inputs, so an unchanged fingerprint means an unchanged answer.
    /// Before this, each probe spawned `voxtype-bin` four times, and probes fire on every app
    /// activation and daemon appear/disappear - several 28 MB process launches per dictation.
    static let cacheTTL: TimeInterval = 600

    private static let cacheLock = NSLock()
    private static var cached: (fingerprint: ProbeFingerprint, result: EngineProbeResult, at: Date)?

    /// Drop the cached probe so the next call spawns again (after setup, a model switch, etc.).
    static func invalidateCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cached = nil
    }

    static func probe() -> EngineProbeResult {
        let bin = EngineControl.voxtypeBin
        let fingerprint = ProbeFingerprint(paths: [bin, configFile.path, modelsDirectory.path])
        if var hit = cachedResult(for: fingerprint) {
            if let model = hit.configuredModel, model.hasPrefix("/") {
                hit.configuredModelPathExists = FileManager.default.fileExists(atPath: model)
            }
            Timing.event("probe.cached")
            return hit
        }
        let result = uncachedProbe(bin: bin)
        cacheLock.lock(); defer { cacheLock.unlock() }
        cached = (fingerprint, result, Date())
        return result
    }

    private static func cachedResult(for fingerprint: ProbeFingerprint) -> EngineProbeResult? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let cached, cached.fingerprint == fingerprint,
              Date().timeIntervalSince(cached.at) < cacheTTL else { return nil }
        return cached.result
    }

    private static func uncachedProbe(bin: String) -> EngineProbeResult {
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

    /// stdout of a read-only voxtype-bin call; nil on launch failure, non-zero exit, or timeout.
    static func run(_ bin: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        guard let result = try? ProcessRunner.run(bin, args, timeout: timeout, stderr: .discard) else { return nil }
        if result.timedOut { Timing.event("probe.timeout", ["cmd": args.first ?? ""]) }
        return result.succeeded ? result.stdoutText : nil
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
