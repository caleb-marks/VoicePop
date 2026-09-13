import AppKit
import Foundation
import PopcornArt
import PopcornCore
import SwiftUI

/// `PopcornCapture --review <dir>`: the documented seed-2026 frames on every backdrop at native
/// 1×, the 2× documentation scale, and a 4× inspection scale, plus Reduce Motion, transcribing,
/// and the kernel sheet. File names match `docs/visuals/` so before/after sheets pair up.
@MainActor
enum Review {
    static func run(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var stills: [(String, PopcornRenderer.SceneInput)] = []
        let sim = PopcornSim(seed: 2026)
        sim.allowSpawn = true
        var mono: UInt64 = 0
        for (label, seconds, peak, accents) in PopcornCapture.segments {
            let steps = Int(seconds * 60)
            for i in 0..<steps {
                mono += 16
                let snap = sim.advance(toMonoMs: mono, peak: peak, peakFresh: PopcornCapture.fresh(step: i, accents: accents))
                if i == steps - 1 { stills.append((label, PopcornCapture.scene(snap))) }
                if label == "loud", i == steps / 2 { stills.append(("loudhalf", PopcornCapture.scene(snap))) }
            }
        }
        stills.append(("loud-reducemotion", PopcornCapture.scene(PopcornCapture.reducedMotionSnapshot(peak: 0.28), reduceMotion: true)))
        stills.append(("transcribing", PopcornCapture.transcribingScene(mascot: .popcorn)))
        // Status-chrome edge cases: the "Audio levels unavailable" detail line under the capsule
        // (drawn on a plate so it survives busy/dark backdrops), and an unusual daemon-state
        // label that must truncate inside the capsule instead of spilling past it.
        if let lastRecording = stills.first(where: { $0.0 == "normal" })?.1 {
            var withDetail = lastRecording
            withDetail.detail = "Audio levels unavailable"
            stills.append(("detail", withDetail))
            var longLabel = lastRecording
            longLabel.label = "Waiting For Microphone Device Permission"
            stills.append(("longlabel", longLabel))
        }

        for (name, scene) in stills {
            for bg in PopcornCapture.Backdrop.allCases {
                PopcornCapture.save(PopcornCapture.render(scene, bg: bg, scale: 1), to: "\(outDir)/popcorn-\(name)-\(bg.rawValue)-native1x.png")
            }
            for bg in [PopcornCapture.Backdrop.light, .dark] {
                PopcornCapture.save(PopcornCapture.render(scene, bg: bg, scale: 2), to: "\(outDir)/popcorn-\(name)-\(bg.rawValue).png")
                PopcornCapture.save(PopcornCapture.render(scene, bg: bg, scale: 4), to: "\(outDir)/popcorn-\(name)-\(bg.rawValue)-review4x.png")
            }
        }
        PopcornCapture.save(PopcornCapture.renderKernelSheet(scale: 2), to: "\(outDir)/kernel-preview.png")
        PopcornCapture.save(PopcornCapture.renderKernelSheet(scale: 4), to: "\(outDir)/kernel-preview-review4x.png")
        // Rotation sharpness: one kernel at four angles on black, at the HUD's 1× and 2× scales.
        for scale in [1.0, 2.0] {
            let view = Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                for (i, rot) in [0.0, 0.3, 0.785, 1.2].enumerated() {
                    PopcornRenderer.drawKernel(ctx: &ctx, at: CGPoint(x: 20 + CGFloat(i) * 36, y: 20),
                                               scale: 1, shape: 3, butter: 0.3, alpha: 1, rot: CGFloat(rot))
                }
            }
            .frame(width: 148, height: 40)
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            if let img = renderer.nsImage {
                PopcornCapture.save(img, to: "\(outDir)/kernel-rotation-\(Int(scale))x.png")
            }
        }
        // Cleanup fade: one kernel at alpha 1, 0.75, 0.5, 0.25 over black and white at 4×.
        let fade = Canvas { ctx, size in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)), with: .color(.black))
            ctx.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)), with: .color(.white))
            for (i, alpha) in [1.0, 0.75, 0.5, 0.25].enumerated() {
                for row in 0..<2 {
                    PopcornRenderer.drawKernel(ctx: &ctx, at: CGPoint(x: 20 + CGFloat(i) * 36, y: 20 + CGFloat(row) * 40),
                                               scale: 1, shape: 7, butter: 0.3, alpha: alpha, rot: 0.4)
                }
            }
        }
        .frame(width: 148, height: 80)
        let fadeRenderer = ImageRenderer(content: fade)
        fadeRenderer.scale = 4
        if let img = fadeRenderer.nsImage { PopcornCapture.save(img, to: "\(outDir)/kernel-fade-4x.png") }
        print("wrote review stills to \(outDir)")
    }
}
