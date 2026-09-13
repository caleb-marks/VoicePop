import AppKit
import Foundation
import PopcornArt
import PopcornCore
import SwiftUI

MainActor.assumeIsolated { PopcornCapture.main() }

/// Offscreen captures for docs/visuals, art review, motion review, and benchmarks.
///
///     PopcornCapture [out-dir] [popcorn|beagle]     documentation stills, GIF, and report
///     PopcornCapture --review <out-dir>             art review stills (1×/2×/4×, light/dark/busy)
///     PopcornCapture --motion <out-dir>             motion frames, contact sheets, MP4/GIF
///     PopcornCapture --bench [--json out] [--frames N]
///
/// Every scene is built with the production `SceneInput(snapshot:…)` mapping, so captures show
/// exactly what the HUD and the Settings preview draw.
@MainActor
struct PopcornCapture {
    static func main() {
        let _ = NSApplication.shared
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "--bench":
            Bench.run(args: Array(args.dropFirst()))
        case "--review":
            Review.run(outDir: args.dropFirst().first ?? "review")
        case "--motion":
            MotionCapture.run(outDir: args.dropFirst().first ?? "motion")
        default:
            let outDir = args.first ?? FileManager.default.currentDirectoryPath + "/docs/visuals"
            let mascot: Mascot = args.dropFirst().first == "beagle" ? .beagle : .popcorn
            captureDocs(outDir: outDir, mascot: mascot)
        }
    }

    /// The documented deterministic input: seed 2026, quiet → normal → loud → accents → silence.
    static let segments: [(label: String, seconds: Double, peak: Float, accents: Bool)] = [
        ("quiet", 2.0, 0.035, false),
        ("normal", 2.0, 0.12, false),
        ("loud", 3.0, 0.28, false),
        ("accents", 2.0, 0.28, true),
        ("silence", 1.0, 0.0, false),
    ]

    /// Display-rate (60 Hz) sample for step `i` of a segment: held levels with fresh packets every
    /// other frame, or sparse fresh packets for accents so each one reads as an onset.
    static func fresh(step i: Int, accents: Bool) -> Bool {
        accents ? (i % 11 == 0) : (i % 2 == 0)
    }

    static func scene(
        _ snap: SimSnapshot, reduceMotion: Bool = false, mascot: Mascot = .popcorn
    ) -> PopcornRenderer.SceneInput {
        PopcornRenderer.SceneInput(
            snapshot: snap, label: "Recording", presentation: .recording,
            reduceMotion: reduceMotion, mascot: mascot
        )
    }

    static func transcribingScene(mascot: Mascot) -> PopcornRenderer.SceneInput {
        .still(label: "Transcribing…", presentation: .transcribing, reduceMotion: true, mascot: mascot)
    }

    /// Loud input under Reduce Motion, through the real simulation path.
    static func reducedMotionSnapshot(peak: Float) -> SimSnapshot {
        let sim = PopcornSim(seed: 2026)
        sim.allowSpawn = true
        sim.reduceMotion = true
        var snap = sim.advance(toMonoMs: 0, peak: peak)
        var mono: UInt64 = 0
        for i in 0..<120 {
            mono += 16
            snap = sim.advance(toMonoMs: mono, peak: peak, peakFresh: i % 2 == 0)
        }
        return snap
    }

    static func captureDocs(outDir: String, mascot: Mascot) {
        let prefix = mascot == .beagle ? "beagle-" : "popcorn-"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // Popcorn keeps the existing 2× documentation stills and also emits native 1× copies;
        // beagle artifacts retain their established native scale.
        let scale: CGFloat = mascot == .beagle ? 1 : 2

        let sim = PopcornSim(seed: 2026)
        sim.allowSpawn = true
        var mono: UInt64 = 0
        var peakKernelCount = 0
        var loudScene = transcribingScene(mascot: mascot)

        let t0 = CFAbsoluteTimeGetCurrent()
        for (label, seconds, peak, accents) in segments {
            let steps = Int(seconds * 60)
            for i in 0..<steps {
                mono += 16
                let snap = sim.advance(toMonoMs: mono, peak: peak, peakFresh: fresh(step: i, accents: accents))
                peakKernelCount = max(peakKernelCount, sim.kernels.count)
                if i == steps - 1 || (label == "loud" && i == steps / 2) {
                    let frame = scene(snap, mascot: mascot)
                    if label == "loud" { loudScene = frame }
                    for bg in [Backdrop.light, .dark] {
                        let name = "\(prefix)\(label)-\(bg.rawValue)"
                        save(render(frame, bg: bg, scale: scale), to: "\(outDir)/\(name).png")
                        if mascot == .popcorn {
                            save(render(frame, bg: bg, scale: 1), to: "\(outDir)/\(name)-native1x.png")
                        } else {
                            save(render(frame, bg: bg, scale: 4), to: "\(outDir)/\(name)-review4x.png")
                        }
                    }
                    if mascot == .popcorn, label == "loud", i == steps - 1 {
                        save(render(frame, bg: .busy, scale: 1), to: "\(outDir)/\(prefix)\(label)-busy-native1x.png")
                    }
                }
            }
            print("segment \(label) kernels=\(sim.kernels.count) heat=\(String(format: "%.3f", sim.heat)) kick=\(String(format: "%.2f", sim.kick))")
        }
        let simMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        var specials: [(String, PopcornRenderer.SceneInput)]
        if mascot == .beagle {
            // Fixed levels (not simulated) keep the beagle stills comparable across renderer changes.
            func still(_ level: Double) -> PopcornRenderer.SceneInput {
                scene(SimSnapshot(kernels: [], heat: level, mood: level, kick: 0, phase: 0, bagVisible: 1, levelsUnavailable: false),
                      reduceMotion: true, mascot: .beagle)
            }
            specials = [("quiet-reducemotion", still(0.035)), ("loud-reducemotion", still(0.28))]
        } else {
            specials = [("loud-reducemotion", scene(reducedMotionSnapshot(peak: 0.28), reduceMotion: true, mascot: mascot))]
        }
        specials.append(("transcribing", transcribingScene(mascot: mascot)))
        for (name, frame) in specials {
            for bg in [Backdrop.light, .dark] {
                save(render(frame, bg: bg, scale: 1), to: "\(outDir)/\(prefix)\(name)-\(bg.rawValue).png")
                save(render(frame, bg: bg, scale: 4), to: "\(outDir)/\(prefix)\(name)-\(bg.rawValue)-review4x.png")
            }
        }

        var drawTimes: [Double] = []
        for _ in 0..<40 {
            let s = CFAbsoluteTimeGetCurrent()
            _ = render(loudScene, bg: .light, scale: scale)
            _ = render(loudScene, bg: .dark, scale: scale)
            drawTimes.append((CFAbsoluteTimeGetCurrent() - s) * 1000)
        }
        drawTimes.sort()
        let median = drawTimes[drawTimes.count / 2]
        let p95 = drawTimes[Int(Double(drawTimes.count - 1) * 0.95)]

        save(renderKernelSheet(scale: scale), to: "\(outDir)/kernel-preview.png")

        let movieDir = "\(outDir)/_frames"
        try? FileManager.default.removeItem(atPath: movieDir)
        try? FileManager.default.createDirectory(atPath: movieDir, withIntermediateDirectories: true)
        var frameIdx = 0
        for (frame, hudScale) in demoSequence(mascot: mascot) {
            save(render(frame, bg: .gray, scale: 1, hudScale: hudScale), to: String(format: "%@/f_%04d.png", movieDir, frameIdx))
            frameIdx += 1
        }
        let mp4 = "\(outDir)/\(prefix)polish.mp4"
        ffmpeg(["-y", "-framerate", "60", "-i", "\(movieDir)/f_%04d.png",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", mp4])
        if mascot == .popcorn {
            ffmpeg(["-y", "-framerate", "60", "-i", "\(movieDir)/f_%04d.png",
                    "-vf", "fps=20,split[s0][s1];[s0]palettegen=max_colors=192:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4",
                    "\(outDir)/demo-tub.gif"])
        }
        try? FileManager.default.removeItem(atPath: movieDir)

        writeReport(outDir: outDir, mascot: mascot, prefix: prefix, scale: scale,
                    peakKernelCount: peakKernelCount, simMs: simMs, median: median, p95: p95)
        print("wrote artifacts to \(outDir)")
        print("render median=\(median) p95=\(p95) ms kernels=\(sim.kernels.count)")
    }

    /// The README demo: the documented segments at 60 fps, then the recording → transcribing
    /// collapse driven the way `HUDController` drives it, then one second of the capsule.
    static func demoSequence(mascot: Mascot) -> [(PopcornRenderer.SceneInput, Double)] {
        var out: [(PopcornRenderer.SceneInput, Double)] = []
        let sim = PopcornSim(seed: 2026)
        sim.allowSpawn = true
        var mono: UInt64 = 0
        for (_, seconds, peak, accents) in segments {
            let steps = Int(seconds * 60)
            for i in 0..<steps {
                mono += 16
                out.append((scene(sim.advance(toMonoMs: mono, peak: peak, peakFresh: fresh(step: i, accents: accents)), mascot: mascot), 1))
            }
        }
        out.append(contentsOf: collapse(sim: sim, mono: &mono, mascot: mascot))
        for _ in 0..<60 { out.append((transcribingScene(mascot: mascot), capsuleHUDScale)) }
        return out
    }

    /// `HUDController`'s window scale for the frozen Transcribing capsule.
    static let capsuleHUDScale = 0.65

    /// Recording → transcribing, driven like `HUDController`: spawning stops, `bagVisible` eases
    /// from 1 to 0 over `Tunables.collapseMs`, and the window scale eases from 1 to 0.65.
    static func collapse(sim: PopcornSim, mono: inout UInt64, mascot: Mascot) -> [(PopcornRenderer.SceneInput, Double)] {
        sim.allowSpawn = false
        var out: [(PopcornRenderer.SceneInput, Double)] = []
        let frames = max(1, Int((Tunables.collapseMs / 1000 * 60).rounded(.up)))
        for f in 1...frames {
            mono += 16
            let t = min(1, Double(f) / Double(frames))
            let eased = 1 - pow(1 - t, 3)
            sim.setBagVisible(1 - eased)
            let snap = sim.advance(toMonoMs: mono, peak: 0)
            out.append((PopcornRenderer.SceneInput(
                snapshot: snap, label: "Transcribing…", presentation: .transcribing,
                reduceMotion: false, mascot: mascot
            ), 1 - (1 - capsuleHUDScale) * eased))
        }
        return out
    }

    static func writeReport(
        outDir: String, mascot: Mascot, prefix: String, scale: CGFloat,
        peakKernelCount: Int, simMs: Double, median: Double, p95: Double
    ) {
        let specialArtifacts = mascot == .beagle
            ? """
              - `beagle-quiet-reducemotion-light.png` / `beagle-quiet-reducemotion-dark.png`
              - `beagle-loud-reducemotion-light.png` / `beagle-loud-reducemotion-dark.png` (geometry must match quiet)
              - `beagle-transcribing-light.png` / `beagle-transcribing-dark.png` (capsule only)
              """
            : """
              - `popcorn-loud-reducemotion-light.png` / `popcorn-loud-reducemotion-dark.png` (simulated with Reduce Motion on: no pops, no pile motion)
              - `popcorn-transcribing-light.png` / `popcorn-transcribing-dark.png` (capsule only)
              - `popcorn-*-native1x.png` (native-scale copies) and `popcorn-loud-busy-native1x.png` (patterned backdrop)
              """

        let report = """
        # \(mascot == .beagle ? "Nandor" : "Popcorn") voice-polish verification - \(ISO8601DateFormatter().string(from: Date()))

        Production HUD remains Canvas-only. \(mascot == .beagle ? "Beagle" : "Popcorn") captures use the
        fixed 260×420 point scene and the production `SceneInput(snapshot:)` mapping; primary stills use \(String(format: "%.0f", scale))× documentation scale with native 1× copies where applicable. \(mascot == .beagle ? "The beagle path uses only dog geometry." : "Kernels are pre-rendered sprites under one scene-space light; the decorative pile is spring-simulated in `PopcornSim`.")

        ## Checks

        - Capture command: `PopcornCapture <output-directory> \(mascot == .beagle ? "beagle" : "popcorn")`.
        - Seed 2026 sequence: quiet 0.035 (2 s), normal 0.12 (2 s), loud 0.28 (3 s),
          accents (2 s), silence (1 s). Light and dark backgrounds.
        - Peak kernel count in capture: \(peakKernelCount) (cap \(Tunables.maxKernels)).
        - Sequence generation wall time (simulation, still rendering, and PNG writes): \(String(format: "%.1f", simMs)) ms.
        - Offscreen Canvas renders (\(String(format: "%.0f", scale))× light+dark pair): median \(String(format: "%.2f", median)) ms,
          95th \(String(format: "%.2f", p95)) ms. These are ImageRenderer measurements,
          **not** live display/compositor frame timings and **not** microphone-to-screen latency.
          Layered release numbers come from `PopcornCapture --bench`.
        - Packet-to-render path is one display tick after `consumePeak` (held level between
          packets; onset only on fresh). Mic → Voxtype → socket → HUD is unmeasured here.

        ## Visual artifacts

        - `\(prefix)quiet-light.png` / `\(prefix)quiet-dark.png` (\(String(format: "%.0f", scale))× documentation stills)
        - `\(prefix)normal-light.png` / `\(prefix)normal-dark.png`
        - `\(prefix)loud-light.png` / `\(prefix)loud-dark.png`
        - `\(prefix)accents-light.png` / `\(prefix)accents-dark.png`
        - `\(prefix)silence-light.png` / `\(prefix)silence-dark.png`
        \(specialArtifacts)
        - `kernel-preview.png` (kernel close-up, light and dark rows)
        - `\(prefix)polish.mp4`: 60 fps deterministic input demo, then the recording → transcribing collapse and one second of the capsule - **not** microphone footage.
        \(mascot == .popcorn ? "- `demo-tub.gif`: 20 fps README hero derived from the same deterministic frames." : "")

        ## Still required (live)

        Hold FN and speak quiet → normal → loud → accents → silence while the HUD is visible.
        Do not count synthetic input or captures that miss the HUD as a mic pass.
        Offscreen timings are not live compositor timings or microphone latency. System Reduce Motion,
        app switching, host-field insertion, and repeated microphone cycles remain manual checks.
        """
        let reportName = mascot == .beagle ? "beagle-polish-check.md" : "popcorn-polish-check.md"
        try? report.write(toFile: "\(outDir)/\(reportName)", atomically: true, encoding: .utf8)
    }

    // MARK: - Rendering helpers

    enum Backdrop: String, CaseIterable {
        case light, dark, gray, mid, busy
    }

    static func render(_ scene: PopcornRenderer.SceneInput, bg: Backdrop, scale: CGFloat, hudScale: Double = 1) -> NSImage {
        let view = CaptureView(scene: scene, bg: bg, hudScale: hudScale)
            .frame(width: Tunables.cardW, height: Tunables.cardH)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.nsImage ?? NSImage(size: NSSize(width: Tunables.cardW, height: Tunables.cardH))
    }

    static func renderKernelSheet(scale: CGFloat) -> NSImage {
        let view = KernelSheet()
            .frame(width: 520, height: 280)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.nsImage ?? NSImage(size: NSSize(width: 520, height: 280))
    }

    static func save(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    static func ffmpeg(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ffmpeg"] + arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

struct CaptureView: View {
    var scene: PopcornRenderer.SceneInput
    var bg: PopcornCapture.Backdrop
    /// `PopcornFrame.scale`, applied like `PopcornView`'s bottom-anchored `scaleEffect`.
    var hudScale: Double = 1

    var body: some View {
        Canvas { ctx, size in
            drawBackdrop(&ctx, size: size, bg: bg)
            if hudScale != 1 {
                ctx.translateBy(x: size.width / 2, y: size.height)
                ctx.scaleBy(x: hudScale, y: hudScale)
                ctx.translateBy(x: -size.width / 2, y: -size.height)
            }
            PopcornRenderer.drawScene(ctx: &ctx, scene: scene)
        }
    }
}

/// Backdrops for legibility checks. `busy` imitates a cluttered desktop: saturated window
/// chrome, mid-gray text lines, and hard light/dark edges crossing the tub and the kernel arc.
func drawBackdrop(_ ctx: inout GraphicsContext, size: CGSize, bg: PopcornCapture.Backdrop) {
    let full = Path(CGRect(origin: .zero, size: size))
    switch bg {
    case .light: ctx.fill(full, with: .color(.white))
    case .dark: ctx.fill(full, with: .color(.black))
    case .gray: ctx.fill(full, with: .color(Color(white: 0.92)))
    case .mid: ctx.fill(full, with: .color(Color(white: 0.5)))
    case .busy:
        ctx.fill(full, with: .linearGradient(
            Gradient(colors: [Color(red: 0.20, green: 0.42, blue: 0.70), Color(red: 0.93, green: 0.62, blue: 0.30)]),
            startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)
        ))
        let palette: [Color] = [
            Color(red: 0.96, green: 0.96, blue: 0.94), Color(red: 0.14, green: 0.15, blue: 0.17),
            Color(red: 0.84, green: 0.20, blue: 0.22), Color(red: 0.98, green: 0.84, blue: 0.40),
            Color(white: 0.55), Color(red: 0.30, green: 0.62, blue: 0.36),
        ]
        var rng = SeededRNG(seed: 99)
        for i in 0..<22 {
            let w = CGFloat(rng.next(in: 40...150)), h = CGFloat(rng.next(in: 20...110))
            let rect = CGRect(x: CGFloat(rng.next(in: -30...240)), y: CGFloat(rng.next(in: -20...400)), width: w, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(palette[i % palette.count]))
            for line in 0..<Int(h / 9) {
                let y = rect.minY + 6 + CGFloat(line) * 9
                ctx.fill(Path(CGRect(x: rect.minX + 6, y: y, width: w * CGFloat(rng.next(in: 0.3...0.8)), height: 2.5)),
                         with: .color(palette[(i + 1 + line) % palette.count].opacity(0.8)))
            }
        }
    }
}

private struct KernelSheet: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.94)))
            // Light row: shapes 0–5
            for shape in 0..<6 {
                let x = 50 + CGFloat(shape) * 80
                PopcornRenderer.drawKernel(
                    ctx: &ctx, at: CGPoint(x: x, y: 70),
                    scale: 1.6, shape: shape, butter: 0.10 + CGFloat(shape) * 0.055, alpha: 1, rot: 0, heat: 0
                )
            }
            // Dark band with shapes 6–11
            ctx.fill(Path(CGRect(x: 0, y: 140, width: size.width, height: 140)), with: .color(.black))
            for shape in 6..<KernelArt.templateCount {
                let col = shape - 6
                let x = 50 + CGFloat(col) * 80
                PopcornRenderer.drawKernel(
                    ctx: &ctx, at: CGPoint(x: x, y: 210),
                    scale: 1.6, shape: shape, butter: 0.36 - CGFloat(col) * 0.055, alpha: 1, rot: 0.15, heat: 0
                )
            }
        }
    }
}
