import Foundation
import PopcornCore

/// A live install path a test can swap for a fixture-driven one, so the Settings Dictation tab's
/// download/switch UI can be exercised without ever spawning `voxtype-bin` or touching the
/// network (the polish worktree must not download models or `config set` for real).
protocol ModelInstallRunning: Sendable {
    func download(_ name: String, onEvent: @escaping @Sendable (ModelDownloadEvent) -> Void) throws
    func setModel(_ name: String) throws
}

struct LiveModelInstallRunner: ModelInstallRunning {
    func download(_ name: String, onEvent: @escaping @Sendable (ModelDownloadEvent) -> Void) throws {
        try VoxtypeModel.streamDownload(name, onEvent: onEvent)
    }
    func setModel(_ name: String) throws {
        try VoxtypeModel.setModel(name)
    }
}

enum VoxtypeModel {
    static let bin = "/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"

    struct Choice: Equatable {
        let id: String
        let title: String
        let summary: String
        let approxSizeGB: Double
    }

    static let catalog: [Choice] = [
        Choice(id: "parakeet-tdt-0.6b-v3-int8", title: "Parakeet",
               summary: "Default. Fast and multilingual.", approxSizeGB: 2.4),
        Choice(id: "tiny.en", title: "Tiny",
               summary: "Whisper, smallest and fastest; least accurate.", approxSizeGB: 0.08),
        Choice(id: "base.en", title: "Base",
               summary: "Whisper, quick with modest accuracy.", approxSizeGB: 0.15),
        Choice(id: "small.en", title: "Small",
               summary: "Whisper, balances speed and accuracy.", approxSizeGB: 0.5),
        Choice(id: "medium.en", title: "Medium",
               summary: "Whisper, slower but more accurate.", approxSizeGB: 1.5),
        Choice(id: "large-v3-turbo", title: "Large turbo",
               summary: "Whisper, most accurate; slower to load.", approxSizeGB: 1.6),
    ]

    static func engine(for model: String) -> String {
        model.hasPrefix("parakeet") ? "parakeet" : "whisper"
    }

    static let nameGlossary = "VoicePop, Voxtype, Ghostty, NVIDIA Parakeet, Codex, Claude Code, Rust, Cursor."

    /// True when `id` (an installed/current model name from the engine, possibly with a
    /// packaging suffix such as `-prepacked`) refers to the same model as `catalogID`. One
    /// definition, shared with health probes and setup: `PopcornCore.ModelIdentity`.
    static func matches(_ id: String?, catalogID: String) -> Bool {
        guard let id else { return false }
        return ModelIdentity.same(id, catalogID)
    }

    static func title(for id: String) -> String {
        catalog.first { matches(id, catalogID: $0.id) }?.title ?? id
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func currentModel() -> String? {
        let engine = (try? run(["config", "get", "engine"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "whisper"
        let key = engine == "parakeet" ? "parakeet.model" : "whisper.model"
        guard let out = try? run(["config", "get", key]) else { return nil }
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func installedNames() -> Set<String> {
        guard let out = try? run(["info", "models", "--json"]),
              let data = out.data(using: .utf8),
              let info = try? JSONDecoder().decode(ModelsJSON.self, from: data)
        else { return [] }
        return Set(info.engines.values.flatMap { $0.models.filter(\.installed).map(\.name) })
    }

    /// Streams parsed download progress events as they arrive. Line parsing lives in
    /// `PopcornCore.ModelDownloadProgress`, unit-tested against fixture lines. Drains stderr (to
    /// avoid the child blocking on a full pipe - L-5) and keeps the last parsed JSON error, which
    /// is more specific than a bare exit status.
    static func streamDownload(_ name: String, onEvent: @escaping @Sendable (ModelDownloadEvent) -> Void) throws {
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            throw Failure(message: "Voxtype is not installed at \(bin)")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = ["setup", "--download", "--model", name, "--progress-format", "json", "--quiet"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        var buffer = Data()
        let lastErrorLock = NSLock()
        var lastError: String?
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
            while let range = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                guard let line = String(data: lineData, encoding: .utf8),
                      let event = ModelDownloadProgress.parse(line: line) else { continue }
                if case .failure(let message) = event {
                    lastErrorLock.lock(); lastError = message; lastErrorLock.unlock()
                }
                onEvent(event)
            }
        }
        // Drain stderr on its own queue so a chatty child never blocks on a full pipe.
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }
        do {
            try task.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            throw Failure(message: error.localizedDescription)
        }
        task.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errGroup.wait()
        if task.terminationStatus != 0 {
            lastErrorLock.lock(); let detail = lastError; lastErrorLock.unlock()
            throw Failure(message: detail ?? "Model download failed (\(task.terminationStatus)).")
        }
    }

    static func setModel(_ name: String) throws {
        let engine = engine(for: name)
        _ = try run(["config", "set", "engine", engine])
        _ = try run(["config", "set", "\(engine).model", name])
    }

    static func setNameGlossary() throws {
        _ = try run(["config", "set", "whisper.initial_prompt", nameGlossary])
    }

    static func warm() {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("voicepop-warm.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", "ready"]
        say.standardOutput = FileHandle.nullDevice
        say.standardError = FileHandle.nullDevice
        do {
            try say.run()
            say.waitUntilExit()
            _ = try run(["transcribe", wav.path])
        } catch {
            fputs("VoicePop: warm failed: \(error)\n", stderr)
        }
        try? FileManager.default.removeItem(at: wav)
    }

    @discardableResult
    private static func run(_ args: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            throw Failure(message: "Voxtype is not installed at \(bin)")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        // Drain both pipes before waitUntilExit. Waiting first deadlocks when
        // the child fills a pipe (e.g. `info models --json` or `transcribe`).
        let errGroup = DispatchGroup()
        var stderr = ""
        errGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            errGroup.leave()
        }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        errGroup.wait()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "voxtype \(args.joined(separator: " ")) failed (\(task.terminationStatus))" : detail)
        }
        return stdout
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
