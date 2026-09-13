import AppKit
import PopcornArt
import PopcornCore
import SwiftUI

// Offscreen cost of publishing HUD frames through NSHostingView<PopcornView> (the HUD's path),
// compared with an ObservableObject-driven host. No panel is shown, no watcher/daemon is touched.
//
//   hud-publish-bench [--frames N] [--intensity quiet|normal|energetic]
//
// Rows:
//   assign        `hosting.rootView = PopcornView(frame:)` alone (what HUDController.publish does)
//   assign+draw   assignment, layout, and a forced synchronous draw into a bitmap (cacheDisplay)
//   model+draw    same, but mutating an @Published frame on a long-lived host instead
//   canvas draw   time inside the Canvas closure (PopcornRenderer.drawScene) during those draws
//   sim.advance   simulation step for context (WS1 owns sim/render profiling)

final class FrameModel: ObservableObject {
    @Published var frame: PopcornFrame
    init(_ frame: PopcornFrame) { self.frame = frame }
}

struct ModelView: View {
    @ObservedObject var model: FrameModel
    var body: some View { PopcornView(frame: model.frame) }
}

@main
enum HUDPublishBench {
    static func arg(_ name: String, _ fallback: String) -> String {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
        return fallback
    }

    static func us(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
    }

    static func stats(_ name: String, _ v: [Double]) {
        let s = v.sorted()
        func p(_ q: Double) -> Double { s[max(0, min(s.count - 1, Int((q * Double(s.count)).rounded(.up)) - 1))] }
        print(String(format: "%-12@ n=%4d  p50=%8.1f µs  p95=%8.1f µs  max=%8.1f µs", name as NSString, s.count, p(0.5), p(0.95), s.last ?? 0))
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let frames = Int(arg("--frames", "600"))!
        let intensity = SyntheticIntensity(rawValue: arg("--intensity", "energetic")) ?? .energetic

        // Precompute a sustained-speech run at the HUD's 120 Hz tick; publish every other tick (60 Hz).
        let sim = PopcornSim(seed: 11)
        sim.allowSpawn = true
        var speech = SyntheticSpeech(intensity: intensity, seed: 11)
        var sceneFrames: [PopcornFrame] = []
        var simCost: [Double] = []
        var mono: UInt64 = 10_000
        var maxKernels = 0
        for i in 0..<(frames * 2 + 240) {
            mono += i % 3 == 2 ? 9 : 8
            let s = speech.sample(atMonoMs: mono)
            var snap: SimSnapshot?
            let c = us { snap = sim.advance(toMonoMs: mono, peak: s.peak, peakFresh: s.fresh) }
            guard i >= 240, let snap else { continue } // skip warm-up so the pile is populated
            simCost.append(c)
            maxKernels = max(maxKernels, snap.kernels.count)
            if i % 2 == 0 {
                sceneFrames.append(PopcornFrame(
                    opacity: 1, scale: 1,
                    scene: PopcornRenderer.SceneInput(snapshot: snap, label: "Recording", presentation: .recording,
                                                      reduceMotion: false, mascot: .popcorn)
                ))
            }
        }

        let rect = NSRect(x: 0, y: 0, width: Tunables.cardW, height: Tunables.cardH)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: PopcornView(frame: sceneFrames[0]))
        hosting.frame = rect
        window.contentView = hosting
        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: rect)!

        var draws: [Double] = []
        PopcornView.drawCostHook = { draws.append(Double($0)) }
        var assign: [Double] = []
        var assignDraw: [Double] = []
        for f in sceneFrames {
            assign.append(us { hosting.rootView = PopcornView(frame: f) })
        }
        for f in sceneFrames {
            assignDraw.append(us {
                hosting.rootView = PopcornView(frame: f)
                hosting.layoutSubtreeIfNeeded()
                hosting.cacheDisplay(in: rect, to: bitmap)
            })
        }

        let model = FrameModel(sceneFrames[0])
        let modelHost = NSHostingView(rootView: ModelView(model: model))
        modelHost.frame = rect
        window.contentView = modelHost
        let bitmap2 = modelHost.bitmapImageRepForCachingDisplay(in: rect)!
        var modelDraw: [Double] = []
        for f in sceneFrames {
            modelDraw.append(us {
                model.frame = f
                modelHost.layoutSubtreeIfNeeded()
                modelHost.cacheDisplay(in: rect, to: bitmap2)
            })
        }

        print("# hud-publish-bench — offscreen, -O, \(ProcessInfo.processInfo.operatingSystemVersionString); intensity=\(intensity.rawValue) frames=\(sceneFrames.count) maxKernels=\(maxKernels)")
        stats("assign", assign)
        stats("assign+draw", assignDraw)
        stats("model+draw", modelDraw)
        stats("canvas draw", draws)
        stats("sim.advance", simCost)
    }
}
