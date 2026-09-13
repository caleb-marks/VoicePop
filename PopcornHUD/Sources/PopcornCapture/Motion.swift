import AppKit
import Foundation
import PopcornArt
import PopcornCore
import SwiftUI

/// `PopcornCapture --motion <dir>`: evidence for judging pile motion, which stills cannot show.
///
/// - `motion-full.mp4` / `motion-full.gif`: the whole card at 2× through speech, a pause, speech
///   again, and the recording → transcribing collapse.
/// - `motion-heap.mp4`: the same run cropped to the pile at 4×.
/// - `sheet-*.png`: contact sheets of every 2nd frame over about one second, cropped to the pile,
///   for loud speech, accents, the pause ease-down, the collapse, and Reduce Motion.
/// - `heap-trace.csv`: per-frame displacement of every heap piece, plus heat and population.
@MainActor
enum MotionCapture {
    struct Phase {
        var name: String
        var seconds: Double
        var peak: Float
        var accents: Bool
        /// Drive with `SyntheticSpeech` syllables instead of a held level: real onsets and pauses.
        var speech: SyntheticIntensity? = nil
    }

    static let phases: [Phase] = [
        Phase(name: "normal", seconds: 1.5, peak: 0.12, accents: false),
        Phase(name: "loud", seconds: 2.5, peak: 0.28, accents: false),
        Phase(name: "accents", seconds: 2.0, peak: 0.28, accents: true),
        Phase(name: "syllables", seconds: 3.0, peak: 0, accents: false, speech: .energetic),
        Phase(name: "pause", seconds: 2.5, peak: 0.0, accents: false),
        Phase(name: "resume", seconds: 1.0, peak: 0.2, accents: false),
    ]

    /// Crop around the pile in scene points.
    static let heapCrop = CGRect(x: 50, y: 118, width: 160, height: 110)
    static let pileCrop = CGRect(x: 62, y: 138, width: 136, height: 88)

    static func run(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var scenes: [(phase: String, scene: PopcornRenderer.SceneInput)] = []
        var csv = "frame,phase,heat,kernels,settled"
        for i in HeapSeed.pieces.indices { csv += ",dx\(i),dy\(i),rot\(i)" }
        csv += "\n"

        let sim = PopcornSim(seed: 2026)
        sim.allowSpawn = true
        var mono: UInt64 = 0
        var frame = 0
        func log(_ phase: String, _ snap: SimSnapshot) {
            csv += "\(frame),\(phase),\(String(format: "%.4f", snap.heat)),\(snap.kernels.count),\(snap.kernels.filter(\.settled).count)"
            for i in HeapSeed.pieces.indices {
                let p = i < snap.heap.count ? snap.heap[i] : .rest
                csv += String(format: ",%.4f,%.4f,%.5f", p.dx, p.dy, p.rot)
            }
            csv += "\n"
            frame += 1
        }
        var speech = SyntheticSpeech(intensity: .energetic, seed: 7)
        for phase in phases {
            let steps = Int(phase.seconds * 60)
            for i in 0..<steps {
                mono += 16
                var peak = phase.peak
                var fresh = PopcornCapture.fresh(step: i, accents: phase.accents)
                if let intensity = phase.speech {
                    speech.intensity = intensity
                    (peak, fresh) = speech.sample(atMonoMs: mono)
                }
                let snap = sim.advance(toMonoMs: mono, peak: peak, peakFresh: fresh)
                scenes.append((phase.name, PopcornCapture.scene(snap)))
                log(phase.name, snap)
            }
        }
        for s in PopcornCapture.collapse(sim: sim, mono: &mono, mascot: .popcorn) {
            scenes.append(("collapse", s))
        }
        for _ in 0..<30 { scenes.append(("capsule", PopcornCapture.transcribingScene(mascot: .popcorn))) }
        try? csv.write(toFile: "\(outDir)/heap-trace.csv", atomically: true, encoding: .utf8)

        // Reduce Motion: same loud input, decorative motion suppressed.
        let reduced = PopcornSim(seed: 2026)
        reduced.allowSpawn = true
        reduced.reduceMotion = true
        var rm: [PopcornRenderer.SceneInput] = []
        var rmMono: UInt64 = 0
        for i in 0..<90 {
            rmMono += 16
            let snap = reduced.advance(toMonoMs: rmMono, peak: 0.28, peakFresh: i % 2 == 0)
            rm.append(PopcornCapture.scene(snap, reduceMotion: true))
        }

        func window(_ phase: String, skip: Int = 0, count: Int = 30) -> [PopcornRenderer.SceneInput] {
            let all = scenes.filter { $0.phase == phase }.map(\.scene)
            return Array(all.dropFirst(skip).prefix(count * 2)).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        }
        let collapseFrames = scenes.enumerated().filter { $0.element.phase == "collapse" }.map(\.offset)
        let collapseStart = max(0, (collapseFrames.first ?? 0) - 24)
        let aroundCollapse = Array(scenes[collapseStart..<min(scenes.count, collapseStart + 48)]).map(\.scene)
        saveSheet(window("loud", skip: 60), columns: 6, crop: heapCrop, scale: 3, to: "\(outDir)/sheet-loud.png")
        saveSheet(window("accents", skip: 30), columns: 6, crop: heapCrop, scale: 3, to: "\(outDir)/sheet-accents.png")
        saveSheet(window("pause", skip: 0, count: 60).enumerated().filter { $0.offset % 2 == 0 }.map(\.element),
                  columns: 6, crop: heapCrop, scale: 3, to: "\(outDir)/sheet-pause-every4th.png")
        saveSheet(aroundCollapse.enumerated().filter { $0.offset % 2 == 0 }.map(\.element), columns: 6,
                  crop: CGRect(x: 30, y: 60, width: 200, height: 330), scale: 2, to: "\(outDir)/sheet-collapse.png")
        // Pile only (airborne kernels hidden) so rocking, hops, and resting kernels are visible.
        func pileOnly(_ list: [PopcornRenderer.SceneInput]) -> [PopcornRenderer.SceneInput] {
            list.map { var s = $0; s.kernels = s.kernels.filter(\.settled); return s }
        }
        saveSheet(pileOnly(window("loud", skip: 60)), columns: 6, crop: pileCrop, scale: 4, to: "\(outDir)/sheet-loud-pileonly.png")
        saveSheet(pileOnly(window("syllables", skip: 30)), columns: 6, crop: pileCrop, scale: 4, to: "\(outDir)/sheet-syllables-pileonly.png")
        saveSheet(pileOnly(window("pause", skip: 0, count: 60).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)),
                  columns: 6, crop: pileCrop, scale: 4, to: "\(outDir)/sheet-pause-pileonly-every4th.png")
        // Decorative pieces alone, every frame for half a second of accents: rocking and hops.
        let heapOnly = window("syllables", skip: 60, count: 36).map { var s = $0; s.kernels = []; return s }
        saveSheet(heapOnly, columns: 6, crop: pileCrop, scale: 4, to: "\(outDir)/sheet-accents-heaponly.png")
        saveSheet(rm.enumerated().filter { $0.offset % 3 == 0 }.map(\.element), columns: 6,
                  crop: heapCrop, scale: 3, to: "\(outDir)/sheet-reducemotion.png")

        let framesDir = "\(outDir)/_frames"
        let heapDir = "\(outDir)/_heap"
        for dir in [framesDir, heapDir] {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        for (i, s) in scenes.enumerated() {
            PopcornCapture.save(PopcornCapture.render(s.scene, bg: .gray, scale: 2), to: String(format: "%@/f_%04d.png", framesDir, i))
            if let img = renderCrop(s.scene, crop: heapCrop, scale: 4) {
                PopcornCapture.save(img, to: String(format: "%@/f_%04d.png", heapDir, i))
            }
        }
        PopcornCapture.ffmpeg(["-y", "-framerate", "60", "-i", "\(framesDir)/f_%04d.png",
                               "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "16", "\(outDir)/motion-full.mp4"])
        PopcornCapture.ffmpeg(["-y", "-framerate", "60", "-i", "\(heapDir)/f_%04d.png",
                               "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "16", "\(outDir)/motion-heap.mp4"])
        PopcornCapture.ffmpeg(["-y", "-framerate", "60", "-i", "\(framesDir)/f_%04d.png",
                               "-vf", "fps=30,scale=260:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=200:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4",
                               "\(outDir)/motion-full.gif"])
        for dir in [framesDir, heapDir] { try? FileManager.default.removeItem(atPath: dir) }
        print("wrote motion captures to \(outDir) (\(scenes.count) frames)")
    }

    static func renderCrop(_ scene: PopcornRenderer.SceneInput, crop: CGRect, scale: CGFloat) -> NSImage? {
        let view = Canvas { ctx, size in
            drawBackdrop(&ctx, size: size, bg: .gray)
            ctx.translateBy(x: -crop.minX, y: -crop.minY)
            PopcornRenderer.drawScene(ctx: &ctx, scene: scene)
        }
        .frame(width: crop.width, height: crop.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.nsImage
    }

    static func saveSheet(_ scenes: [PopcornRenderer.SceneInput], columns: Int, crop: CGRect, scale: CGFloat, to path: String) {
        guard !scenes.isEmpty else { return }
        let rows = (scenes.count + columns - 1) / columns
        let gap: CGFloat = 2
        let w = crop.width * CGFloat(columns) + gap * CGFloat(columns - 1)
        let h = crop.height * CGFloat(rows) + gap * CGFloat(rows - 1)
        let view = Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.3)))
            for (i, scene) in scenes.enumerated() {
                let col = CGFloat(i % columns), row = CGFloat(i / columns)
                var cell = ctx
                let origin = CGPoint(x: col * (crop.width + gap), y: row * (crop.height + gap))
                cell.clip(to: Path(CGRect(origin: origin, size: crop.size)))
                cell.translateBy(x: origin.x - crop.minX, y: origin.y - crop.minY)
                cell.fill(Path(crop), with: .color(Color(white: 0.92)))
                PopcornRenderer.drawScene(ctx: &cell, scene: scene)
                ctx.draw(Text("\(i)").font(.system(size: 7)).foregroundColor(.black.opacity(0.6)),
                         at: CGPoint(x: origin.x + 3, y: origin.y + 3), anchor: .topLeading)
            }
        }
        .frame(width: w, height: h)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        if let img = renderer.nsImage { PopcornCapture.save(img, to: path) }
    }
}
