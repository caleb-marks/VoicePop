import Foundation

enum VoxtypeModel {
    static let bin = "/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"

    struct Choice: Equatable {
        let id: String
        let title: String
    }

    static let catalog: [Choice] = [
        Choice(id: "parakeet-tdt-0.6b-v3-int8", title: "Parakeet"),
        Choice(id: "tiny.en", title: "Tiny"),
        Choice(id: "base.en", title: "Base"),
        Choice(id: "small.en", title: "Small"),
        Choice(id: "medium.en", title: "Medium"),
        Choice(id: "large-v3-turbo", title: "Large turbo"),
    ]

    static func engine(for model: String) -> String {
        model.hasPrefix("parakeet") ? "parakeet" : "whisper"
    }

    static let nameGlossary = "VoicePop, Voxtype, Nandor, Ghostty, SkillBridge, NVIDIA Parakeet, Codex, Claude Code, Rust, Cursor."

    static func title(for id: String) -> String {
        catalog.first { $0.id == id }?.title ?? id
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

    static func download(_ name: String) throws {
        _ = try run([
            "setup", "--download", "--model", name,
            "--progress-format", "json", "--quiet",
        ])
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
