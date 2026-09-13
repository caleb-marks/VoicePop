import AppKit
import Foundation
import PopcornArt
import PopcornCore
import SwiftUI

/// `PopcornCapture --bench [--json out.json] [--frames N]`
///
/// Release-build cost of the popcorn HUD, measured in separate layers so a regression can be
/// attributed: simulation (`advance`, with collision broken out), the SimSnapshot → SceneInput
/// mapping, and offscreen Canvas rendering through `ImageRenderer` at 1× and 2×. The render
/// numbers include ImageRenderer's own bitmap setup; they are **not** window-server/compositor
/// frame times, and none of this is microphone-to-screen latency.
@MainActor
enum Bench {
    struct Stats: Codable {
        var n: Int
        var mean: Double
        var p50: Double
        var p95: Double
        var max: Double

        init(_ samples: [Double]) {
            let sorted = samples.sorted()
            n = sorted.count
            mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
            func pct(_ p: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
            }
            p50 = pct(0.50)
            p95 = pct(0.95)
            max = sorted.last ?? 0
        }

        var line: String {
            String(format: "p50 %7.3f  p95 %7.3f  max %7.3f  mean %7.3f  (n=%d)", p50, p95, max, mean, n)
        }
    }

    static func run(args: [String]) {
        var jsonPath: String?
        var frames = 2400
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--json" where i + 1 < args.count: jsonPath = args[i + 1]; i += 1
            case "--frames" where i + 1 < args.count: frames = Int(args[i + 1]) ?? frames; i += 1
            default: break
            }
            i += 1
        }

        // Ask for performance cores, like the HUD's main-thread display callback gets.
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

        var results: [String: Stats] = [:]
        var notes: [String: String] = [:]
        func record(_ key: String, _ samples: [Double]) {
            let s = Stats(samples)
            results[key] = s
            print("\(key.padding(toLength: 34, withPad: " ", startingAt: 0)) \(s.line)")
        }

        #if DEBUG
        print("WARNING: debug build; run with `swift run -c release …` for meaningful numbers")
        notes["build"] = "debug"
        #else
        notes["build"] = "release"
        #endif
        notes["machine"] = machineName()
        notes["units"] = "milliseconds"

        // MARK: One-time (measured before anything else draws) kernel sprite painting (cold cache), per display scale.
        for scale in [1.0, 2.0] {
            let t0 = uptimeMs()
            PopcornRenderer.prewarmKernelSprites(displayScale: scale)
            let ms = uptimeMs() - t0
            notes["sprites.coldPrewarm@\(Int(scale))x.ms"] = String(format: "%.1f", ms)
            print(String(format: "sprites.coldPrewarm@%dx  %.1f ms (one time)", Int(scale), ms))
        }

        // MARK: Simulation under sustained loud speech with accents.
        // 120 Hz display ticks (one fixed step each) and 60 Hz ticks (two steps each).
        func loudInput(_ tick: Int, hz: Int) -> (Float, Bool) {
            // 360 ms loud syllables separated by 60 ms dips, so every syllable is a fresh onset.
            let ms = tick * 1000 / hz
            let inDip = ms % 420 >= 360
            return (inDip ? 0.05 : 0.34, true)
        }
        var scenes: [PopcornRenderer.SceneInput] = []
        var liveCounts: [Double] = []
        for hz in [120, 60] {
            let sim = PopcornSim(seed: 2026)
            sim.allowSpawn = true
            let stepMs = 1000.0 / Double(hz)
            let warm = hz * 3
            var advanceMs: [Double] = [], collideMs: [Double] = [], integrateMs: [Double] = []
            var heapMs: [Double] = [], mapMs: [Double] = [], perStepMs: [Double] = []
            let total = hz == 120 ? frames : frames / 2
            for tick in 0..<(warm + total) {
                let mono = UInt64((Double(tick + 1) * stepMs).rounded())
                let (peak, fresh) = loudInput(tick, hz: hz)
                sim.timings = SimPhaseTimings()
                sim.collectTimings = tick >= warm
                let t0 = uptimeMs()
                let snap = sim.advance(toMonoMs: mono, peak: peak, peakFresh: fresh)
                let t1 = uptimeMs()
                let scene = PopcornRenderer.SceneInput(
                    snapshot: snap, label: "Recording", presentation: .recording,
                    reduceMotion: false, mascot: .popcorn
                )
                let t2 = uptimeMs()
                guard tick >= warm else { continue }
                advanceMs.append(t1 - t0)
                mapMs.append(t2 - t1)
                let t = sim.timings
                collideMs.append(Double(t.collideNs) / 1e6)
                integrateMs.append(Double(t.integrateNs) / 1e6)
                heapMs.append(Double(t.heapNs) / 1e6)
                if t.steps > 0 { perStepMs.append((t1 - t0) / Double(t.steps)) }
                if hz == 120 {
                    liveCounts.append(Double(sim.kernels.count))
                    if tick % 8 == 0 { scenes.append(scene) }
                }
            }
            record("sim.advance@\(hz)Hz", advanceMs)
            record("sim.perStep@\(hz)Hz", perStepMs)
            record("sim.collide@\(hz)Hz", collideMs)
            record("sim.integrate@\(hz)Hz", integrateMs)
            record("sim.heap@\(hz)Hz", heapMs)
            record("map.sceneInput@\(hz)Hz", mapMs)
        }
        record("population.live", liveCounts)

        // MARK: Forced full population: 120 bodies regardless of emission tuning.
        do {
            let sim = PopcornSim(seed: 77)
            sim.allowSpawn = true
            var advanceMs: [Double] = [], collideMs: [Double] = [], counts: [Double] = []
            var mono: UInt64 = 0
            var forcedScenes: [PopcornRenderer.SceneInput] = []
            for tick in 0..<(360 + frames) {
                mono += 8
                if sim.kernels.count < Tunables.maxKernels { sim.benchmarkFill(to: Tunables.maxKernels) }
                let (peak, fresh) = loudInput(tick, hz: 120)
                sim.timings = SimPhaseTimings()
                sim.collectTimings = tick >= 360
                let t0 = uptimeMs()
                let snap = sim.advance(toMonoMs: mono, peak: peak, peakFresh: fresh)
                let t1 = uptimeMs()
                guard tick >= 360 else { continue }
                if tick % 24 == 0, forcedScenes.count < 100 {
                    forcedScenes.append(PopcornRenderer.SceneInput(
                        snapshot: snap, label: "Recording", presentation: .recording,
                        reduceMotion: false, mascot: .popcorn
                    ))
                }
                advanceMs.append(t1 - t0)
                collideMs.append(Double(sim.timings.collideNs) / 1e6)
                counts.append(Double(sim.kernels.count))
            }
            record("sim.advance.forced120", advanceMs)
            record("sim.collide.forced120", collideMs)
            record("population.forced120", counts)
            for s in forcedScenes.prefix(10) { _ = renderCG(scene: s, scale: 2) }
            var ms: [Double] = []
            for s in forcedScenes {
                let t0 = uptimeMs()
                _ = renderCG(scene: s, scale: 2)
                ms.append(uptimeMs() - t0)
            }
            record("render.offscreen.forced120@2x", ms)
        }

        // MARK: Offscreen Canvas rendering of captured loud scenes.
        let renderScenes = Array(scenes.prefix(300))
        for scale in [1.0, 2.0] {
            for s in renderScenes.prefix(20) { _ = renderCG(scene: s, scale: scale) } // warm caches
            var ms: [Double] = []
            for s in renderScenes {
                let t0 = uptimeMs()
                _ = renderCG(scene: s, scale: scale)
                ms.append(uptimeMs() - t0)
            }
            record("render.offscreen@\(Int(scale))x", ms)
        }

        // Kernel drawing in isolation: 120 airborne vs 120 pile-detail kernels, one canvas each.
        for airborne in [true, false] {
            var ms: [Double] = []
            for rep in 0..<120 {
                let t0 = uptimeMs()
                _ = renderKernels(count: 120, airborne: airborne, seed: rep, scale: 2)
                ms.append(uptimeMs() - t0)
            }
            record("render.kernels120.\(airborne ? "airborne" : "pile")@2x", ms)
        }
        // Empty canvas at the same size: ImageRenderer's fixed cost, to subtract mentally.
        do {
            var ms: [Double] = []
            let empty = PopcornRenderer.SceneInput.still(label: "", presentation: .hidden, reduceMotion: true, mascot: .popcorn)
            for _ in 0..<120 {
                let t0 = uptimeMs()
                _ = renderCG(scene: empty, scale: 2)
                ms.append(uptimeMs() - t0)
            }
            record("render.emptyCanvas@2x", ms)
        }

        // Frame compute estimate: sim advance at 120 Hz + mapping + 2× offscreen render, paired per frame.
        if let adv = results["sim.advance@120Hz"], let map = results["map.sceneInput@120Hz"],
           let r2 = results["render.offscreen@2x"] {
            notes["frameCompute.p95.upperBound@2x"] = String(format: "%.3f", adv.p95 + map.p95 + r2.p95)
            print(String(format: "frame compute upper bound, loud (sum of p95s, 2x): %.3f ms", adv.p95 + map.p95 + r2.p95))
        }
        if let adv = results["sim.advance.forced120"], let r2 = results["render.offscreen.forced120@2x"] {
            notes["frameCompute.p95.upperBound.forced120@2x"] = String(format: "%.3f", adv.p95 + r2.p95)
            print(String(format: "frame compute upper bound, 120 bodies (sum of p95s, 2x): %.3f ms", adv.p95 + r2.p95))
        }

        if let jsonPath {
            struct Out: Codable { var notes: [String: String]; var results: [String: Stats] }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(Out(notes: notes, results: results)) {
                try? data.write(to: URL(fileURLWithPath: jsonPath))
                print("wrote \(jsonPath)")
            }
        }
    }

    /// Touch the bitmap so lazily-rasterized images are fully drawn inside the timed region.
    static func forcePixels(_ image: CGImage?) -> CGImage? {
        guard let image, let data = image.dataProvider?.data else { return image }
        _ = CFDataGetLength(data)
        return image
    }

    static func uptimeMs() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }

    static func machineName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func renderCG(scene: PopcornRenderer.SceneInput, scale: CGFloat) -> CGImage? {
        let view = Canvas { ctx, _ in PopcornRenderer.drawScene(ctx: &ctx, scene: scene) }
            .frame(width: Tunables.cardW, height: Tunables.cardH)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return forcePixels(renderer.cgImage)
    }

    static func renderKernels(count: Int, airborne: Bool, seed: Int, scale: CGFloat) -> CGImage? {
        let view = Canvas { ctx, _ in
            var rng = SeededRNG(seed: UInt64(seed + 1))
            for i in 0..<count {
                PopcornRenderer.drawKernel(
                    ctx: &ctx,
                    at: CGPoint(x: rng.next(in: 20...240), y: rng.next(in: 20...400)),
                    scale: CGFloat(rng.next(in: 0.72...1.08)), shape: i,
                    butter: CGFloat(rng.next(in: 0.06...0.4)), alpha: 1,
                    rot: CGFloat(rng.next(in: 0...6.28)), airborne: airborne
                )
            }
        }
        .frame(width: Tunables.cardW, height: Tunables.cardH)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return forcePixels(renderer.cgImage)
    }
}
