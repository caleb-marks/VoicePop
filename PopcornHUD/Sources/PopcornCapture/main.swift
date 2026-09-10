import AppKit
import Foundation
import PopcornArt
import PopcornCore
import SwiftUI

/// Offscreen quiet→normal→loud→accents→silence capture for docs/visuals.
@main
@MainActor
struct PopcornCapture {
    static func main() {
        let _ = NSApplication.shared
        let args = Array(CommandLine.arguments.dropFirst())
        let outDir = args.first
            ?? FileManager.default.currentDirectoryPath + "/docs/visuals"
        let mascot: Mascot = args.dropFirst().first == "beagle" ? .beagle : .popcorn
        let prefix = mascot == .beagle ? "beagle-" : "popcorn-"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let scale: CGFloat = mascot == .beagle ? 1 : 2

        let segments: [(label: String, seconds: Double, peak: Float, accents: Bool)] = [
            ("quiet", 2.0, 0.035, false),
            ("normal", 2.0, 0.12, false),
            ("loud", 3.0, 0.28, false),
            ("accents", 2.0, 0.28, true),
            ("silence", 1.0, 0.0, false),
        ]

        let sim = PopcornSim(seed: 2026)
        sim.allowSpawn = true
        var mono: UInt64 = 0
        var frames: [(String, NSImage)] = []

        let t0 = CFAbsoluteTimeGetCurrent()
        for (label, seconds, peak, accents) in segments {
            let steps = Int(seconds * 60)
            for i in 0..<steps {
                mono += 16
                let fresh: Bool
                if accents {
                    fresh = (i % 11 == 0)
                } else {
                    fresh = (i % 2 == 0)
                }
                let snap = sim.advance(toMonoMs: mono, peak: peak, peakFresh: fresh)
                if i == steps - 1 || (label == "loud" && i == steps / 2) {
                    let frame = CaptureFrame(
                        heat: snap.heat, mood: snap.mood, kick: snap.kick, phase: snap.phase,
                        kernels: snap.kernels, reduceMotion: false, mascot: mascot
                    )
                    for bgName in ["light", "dark"] {
                        let bg = bgName == "dark" ? NSColor.black : NSColor.white
                        let actual = render(frame: frame, bg: bg, scale: scale)
                        let actualName = "\(prefix)\(label)-\(bgName).png"
                        save(actual, to: "\(outDir)/\(actualName)")
                        frames.append((actualName, actual))
                        if mascot == .beagle {
                            save(render(frame: frame, bg: bg, scale: 4), to: "\(outDir)/\(prefix)\(label)-\(bgName)-review4x.png")
                        }
                    }
                }
            }
            print("segment \(label) kernels=\(sim.kernels.count) heat=\(String(format: "%.3f", sim.heat)) kick=\(String(format: "%.2f", sim.kick))")
        }
        let simMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        if mascot == .beagle {
            let quietFrame = CaptureFrame(heat: 0.035, mood: 0.035, kick: 0, phase: 0, kernels: [], reduceMotion: true, mascot: .beagle)
            let loudReduced = CaptureFrame(heat: 0.28, mood: 0.28, kick: 0, phase: 0, kernels: [], reduceMotion: true, mascot: .beagle)
            let transcribing = CaptureFrame(heat: 0, mood: 0, kick: 0, phase: 0, kernels: [], reduceMotion: true, mascot: .beagle, presentation: .transcribing, label: "Transcribing…")
            for (name, frame) in [("quiet-reducemotion", quietFrame), ("loud-reducemotion", loudReduced), ("transcribing", transcribing)] {
                for bgName in ["light", "dark"] {
                    let bg = bgName == "dark" ? NSColor.black : NSColor.white
                    save(render(frame: frame, bg: bg, scale: 1), to: "\(outDir)/beagle-\(name)-\(bgName).png")
                    save(render(frame: frame, bg: bg, scale: 4), to: "\(outDir)/beagle-\(name)-\(bgName)-review4x.png")
                }
            }
            _ = quietFrame
        }

        let loud = CaptureFrame(
            heat: sim.heat, mood: sim.mood, kick: sim.kick, phase: sim.phase,
            kernels: sim.kernels, reduceMotion: false, mascot: mascot
        )
        var drawTimes: [Double] = []
        for _ in 0..<40 {
            let s = CFAbsoluteTimeGetCurrent()
            _ = render(frame: loud, bg: .white, scale: scale)
            _ = render(frame: loud, bg: .black, scale: scale)
            drawTimes.append((CFAbsoluteTimeGetCurrent() - s) * 1000)
        }
        drawTimes.sort()
        let median = drawTimes[drawTimes.count / 2]
        let p95 = drawTimes[Int(Double(drawTimes.count - 1) * 0.95)]

        let preview = renderKernelSheet(scale: scale)
        save(preview, to: "\(outDir)/kernel-preview.png")

        let movieDir = "\(outDir)/_frames"
        try? FileManager.default.removeItem(atPath: movieDir)
        try? FileManager.default.createDirectory(atPath: movieDir, withIntermediateDirectories: true)
        let movieSim = PopcornSim(seed: 2026)
        movieSim.allowSpawn = true
        var m: UInt64 = 0
        var frameIdx = 0
        for (label, seconds, peak, accents) in segments {
            let steps = Int(seconds * 60)
            for i in 0..<steps {
                m += 16
                let fresh = accents ? (i % 11 == 0) : (i % 2 == 0)
                let snap = movieSim.advance(toMonoMs: m, peak: peak, peakFresh: fresh)
                let frame = CaptureFrame(
                    heat: snap.heat, mood: snap.mood, kick: snap.kick, phase: snap.phase,
                    kernels: snap.kernels, reduceMotion: false, mascot: mascot
                )
                let img = render(frame: frame, bg: NSColor(calibratedWhite: 0.92, alpha: 1), scale: 1)
                let path = String(format: "%@/f_%04d.png", movieDir, frameIdx)
                save(img, to: path)
                frameIdx += 1
            }
            _ = label
        }
        let mp4 = "\(outDir)/\(prefix)polish.mp4"
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ffmpeg.arguments = [
            "ffmpeg", "-y", "-framerate", "60",
            "-i", "\(movieDir)/f_%04d.png",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", mp4,
        ]
        ffmpeg.standardOutput = FileHandle.nullDevice
        ffmpeg.standardError = FileHandle.nullDevice
        try? ffmpeg.run()
        ffmpeg.waitUntilExit()
        try? FileManager.default.removeItem(atPath: movieDir)

        let report = """
        # \(mascot == .beagle ? "Nandor" : "Popcorn") voice-polish verification - \(ISO8601DateFormatter().string(from: Date()))

        Production HUD remains Canvas-only. Beagle captures use the fixed 260×420 point scene at
        actual size and 4× review scale; the beagle path uses only dog geometry and restrained motion.

        ## Checks

        - `swift test --package-path PopcornHUD`: KernelArt hull/lobes + prior physics tests.
        - `swift build --package-path PopcornHUD -c release`: passes.
        - Dated 2026-09-06: then installed `bin/PopcornHUD` + LaunchAgent. Superseded by VoicePop.app.
        - Seed 2026 sequence: quiet 0.035 (2 s), normal 0.12 (2 s), loud 0.28 (3 s),
          accents (2 s), silence (1 s). Light and dark backgrounds.
        - Peak kernel count in capture: \(sim.kernels.count) (cap 120).
        - Full sequence wall time (sim only path above): \(String(format: "%.1f", simMs)) ms.
        - Offscreen Canvas renders (2× light+dark pair): median \(String(format: "%.2f", median)) ms,
          95th \(String(format: "%.2f", p95)) ms. These are ImageRenderer measurements,
          **not** live display/compositor frame timings and **not** microphone-to-screen latency.
        - Packet-to-render path is one display tick after `consumePeak` (held level between
          packets; onset only on fresh). Mic → Voxtype → socket → HUD is unmeasured here.

        ## Visual artifacts

        - `\(prefix)quiet-light.png` / `\(prefix)quiet-dark.png` (actual size)
        - `\(prefix)normal-light.png` / `\(prefix)normal-dark.png`
        - `\(prefix)loud-light.png` / `\(prefix)loud-dark.png`
        - `\(prefix)accents-light.png` / `\(prefix)accents-dark.png`
        - `\(prefix)silence-light.png` / `\(prefix)silence-dark.png`
        - `beagle-quiet-reducemotion-light.png` / `beagle-quiet-reducemotion-dark.png`
        - `beagle-loud-reducemotion-light.png` / `beagle-loud-reducemotion-dark.png` (geometry must match quiet)
        - `beagle-transcribing-light.png` / `beagle-transcribing-dark.png` (capsule only)
        - `kernel-preview.png` (legacy popcorn route)
        - `\(prefix)polish.mp4`: 60 fps deterministic input demo - **not** microphone footage.

        ## Still required (live)

        Hold FN and speak quiet → normal → loud → accents → silence while the HUD is visible.
        Do not count synthetic input or captures that miss the HUD as a mic pass.
        Offscreen timings are not live compositor timings or microphone latency. System Reduce Motion,
        app switching, host-field insertion, and repeated microphone cycles remain manual checks.
        """
        let reportName = mascot == .beagle ? "beagle-polish-check.md" : "popcorn-polish-check.md"
        try? report.write(toFile: "\(outDir)/\(reportName)", atomically: true, encoding: .utf8)
        print("wrote artifacts to \(outDir)")
        print("render median=\(median) p95=\(p95) ms kernels=\(sim.kernels.count)")
        _ = frames
    }

    struct CaptureFrame {
        var heat: Double
        var mood: Double
        var kick: Double
        var phase: Double
        var kernels: [KernelBody]
        var reduceMotion: Bool
        var mascot: Mascot = .popcorn
        var presentation: HUDPresentation = .recording
        var label: String = "Recording"
    }

    static func scene(from frame: CaptureFrame) -> PopcornRenderer.SceneInput {
        let draws = frame.kernels.map {
            PopcornRenderer.KernelDraw(
                front: $0.front, settled: $0.settled,
                x: CGFloat($0.x), y: CGFloat($0.y), scale: CGFloat($0.scale),
                rot: CGFloat($0.rot), shape: $0.shape, butter: CGFloat($0.butter), alpha: $0.alpha
            )
        }
        return PopcornRenderer.SceneInput(
            heat: frame.heat,
            kick: frame.kick,
            bobPhase: frame.phase,
            label: frame.label,
            detail: "",
            presentation: frame.presentation,
            reduceMotion: frame.reduceMotion,
            bagVisible: 1,
            kernels: draws,
            showRecordingDot: true,
            mood: frame.mood,
           
            mascot: frame.mascot
        )
    }

    static func render(frame: CaptureFrame, bg: NSColor, scale: CGFloat) -> NSImage {
        let view = CaptureView(scene: scene(from: frame), bg: Color(nsColor: bg))
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
}

private struct CaptureView: View {
    var scene: PopcornRenderer.SceneInput
    var bg: Color

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
            PopcornRenderer.drawScene(ctx: &ctx, scene: scene)
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
                    scale: 1.6, shape: shape, butter: 0.28, alpha: 1, rot: 0, heat: 0
                )
            }
            // Dark band with shapes 6–11
            ctx.fill(Path(CGRect(x: 0, y: 140, width: size.width, height: 140)), with: .color(.black))
            for shape in 6..<KernelArt.templateCount {
                let col = shape - 6
                let x = 50 + CGFloat(col) * 80
                PopcornRenderer.drawKernel(
                    ctx: &ctx, at: CGPoint(x: x, y: 210),
                    scale: 1.6, shape: shape, butter: 0.28, alpha: 1, rot: 0.15, heat: 0
                )
            }
        }
    }
}
