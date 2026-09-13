import CoreGraphics
import PopcornCore
import SwiftUI

/// Shared Canvas drawing for the live HUD and offscreen capture tool.
public enum PopcornRenderer {

    /// Art-only geometry. PopcornSim continues to use Tunables' mouth, heap, and collision
    /// coordinates; these values only give the visible paperware a shorter, broader silhouette.
    private enum PopcornMetrics {
        static let bottomShift: CGFloat = 22
        static let baseHalf: CGFloat = 47
        static let baseCorner: CGFloat = 10
        static let sideBow: CGFloat = 4
        static let rimThickness: CGFloat = 3.5
        static let rimOverhang: CGFloat = 2.5
    }

    enum CapsuleStyle {
        case legacy
        case popcorn
    }

    public struct SceneInput: Equatable {
        public var heat: Double
        public var kick: Double
        public var bobPhase: Double
        public var label: String
        public var detail: String
        public var presentation: HUDPresentation
        public var reduceMotion: Bool
        public var bagVisible: Double
        public var kernels: [KernelDraw]
        public var showRecordingDot: Bool
        /// Slow-following heat envelope; nil falls back to `heat`.
        public var mood: Double?
        public var mascot: Mascot = .popcorn
        /// Per-piece displacement of `HeapSeed.pieces` from `PopcornSim`; empty draws the pile at rest.
        public var heap: [HeapPose] = []

        public init(
            heat: Double,
            kick: Double,
            bobPhase: Double,
            label: String,
            detail: String,
            presentation: HUDPresentation,
            reduceMotion: Bool,
            bagVisible: Double,
            kernels: [KernelDraw],
            showRecordingDot: Bool = true,
            mood: Double? = nil,
            mascot: Mascot = .popcorn,
            heap: [HeapPose] = []
        ) {
            self.heap = heap
            self.heat = heat
            self.mood = mood
            self.mascot = mascot
            self.kick = kick
            self.bobPhase = bobPhase
            self.label = label
            self.detail = detail
            self.presentation = presentation
            self.reduceMotion = reduceMotion
            self.bagVisible = bagVisible
            self.kernels = kernels
            self.showRecordingDot = showRecordingDot
        }
    }

    public struct KernelDraw: Equatable {
        public var front: Bool
        public var settled: Bool
        public var x: CGFloat
        public var y: CGFloat
        public var scale: CGFloat
        public var rot: CGFloat
        public var shape: Int
        public var butter: CGFloat
        public var alpha: Double

        public init(
            front: Bool = false,
            settled: Bool = false,
            x: CGFloat,
            y: CGFloat,
            scale: CGFloat,
            rot: CGFloat,
            shape: Int,
            butter: CGFloat,
            alpha: Double
        ) {
            self.front = front
            self.settled = settled
            self.x = x
            self.y = y
            self.scale = scale
            self.rot = rot
            self.shape = shape
            self.butter = butter
            self.alpha = alpha
        }
    }

    public static func drawScene(ctx: inout GraphicsContext, scene: SceneInput) {
        let w = Tunables.cardW
        let h = Tunables.cardH
        let bagBottom = h - Tunables.bagBottomPad
        let bagTop = bagBottom - Tunables.bagH
        let cx = w / 2

        if scene.presentation == .transcribing || scene.bagVisible < 0.15 {
            // Popcorn collapse (recording → transcribing): the tub and pile sink and fade into
            // the capsule over the few frames `HUDController` drives `bagVisible` from 1 to 0,
            // instead of vanishing on the first transcribing frame.
            if scene.mascot == .popcorn, scene.presentation == .transcribing, !scene.reduceMotion,
               scene.bagVisible >= 0.15 {
                let t = CGFloat((scene.bagVisible - 0.15) / 0.85)
                let anchorY = bagBottom - PopcornMetrics.bottomShift
                ctx.drawLayer { layer in
                    layer.opacity = Double(t)
                    layer.translateBy(x: cx, y: anchorY)
                    layer.scaleBy(x: 0.8 + 0.2 * t, y: 0.6 + 0.4 * t)
                    layer.translateBy(x: -cx, y: -anchorY)
                    drawBagScene(ctx: &layer, cx: cx, bagTop: bagTop, bagBottom: bagBottom, scene: scene, drawStatus: false)
                }
            }
            let capsuleY = scene.mascot == .popcorn
                ? popcornCapsuleY(bagBottom: bagBottom)
                : h - Tunables.capsuleH / 2 - 8
            drawCapsuleStyled(
                ctx: &ctx, cx: cx, y: capsuleY,
                label: scene.label.isEmpty ? "Transcribing…" : scene.label,
                bobPhase: scene.bobPhase,
                reduceMotion: scene.reduceMotion,
                showDot: false,
                style: scene.mascot == .popcorn ? .popcorn : .legacy
            )
            return
        }

        switch scene.mascot {
        case .popcorn:
            drawBagScene(ctx: &ctx, cx: cx, bagTop: bagTop, bagBottom: bagBottom, scene: scene)
        case .beagle:
            BeagleArt.drawScene(ctx: &ctx, cx: cx, bagTop: bagTop, bagBottom: bagBottom, scene: scene)
        }
    }

    // MARK: - Bag scene

    private static func drawBagScene(
        ctx: inout GraphicsContext,
        cx: CGFloat,
        bagTop: CGFloat,
        bagBottom: CGFloat,
        scene: SceneInput,
        drawStatus: Bool = true
    ) {
        let visibleBottom = bagBottom - PopcornMetrics.bottomShift
        // Signed: positive = squash (wider, shorter); the spring's negative overshoot reads as a
        // slight stretch instead of freezing at rest, so there is no hitch at the zero crossing.
        let kick = scene.reduceMotion ? 0 : CGFloat(scene.kick)
        let squashOnly = max(0, kick)
        let mouthSag = Tunables.rimRy

        drawHaze(ctx: &ctx, cx: cx, bagTop: bagTop, scene: scene)
        drawFlying(ctx: &ctx, front: false, scene: scene)

        // Ground shadow under the visible bag. The simulation remains anchored to bagBottom;
        // only this art layer and the status move upward together.
        let shadowRect = CGRect(
            x: cx - PopcornMetrics.baseHalf - 6 - squashOnly,
            y: visibleBottom - 4,
            width: PopcornMetrics.baseHalf * 2 + 12 + squashOnly * 2,
            height: 14
        )
        ctx.fill(
            Path(ellipseIn: shadowRect),
            with: .radialGradient(
                Gradient(colors: [.black.opacity(0.20 + Double(squashOnly) * 0.008), .clear]),
                center: CGPoint(x: cx, y: visibleBottom + 2),
                startRadius: 0,
                endRadius: PopcornMetrics.baseHalf + 8 + squashOnly
            )
        )

        // Recoil as squash-and-stretch anchored at the ground: each px of kick makes the
        // bag (and everything sitting in it) a little wider and shorter, then springs back.
        // Drawing into a transformed copy of the context keeps every bag/heap coordinate unchanged.
        var bagCtx = ctx
        if kick != 0 {
            let sx = 1 + kick * CGFloat(Tunables.kickSquashX)
            let sy = 1 - kick * CGFloat(Tunables.kickSquashY)
            bagCtx.translateBy(x: cx, y: visibleBottom)
            bagCtx.scaleBy(x: sx, y: sy)
            bagCtx.translateBy(x: -cx, y: -visibleBottom)
        }
        drawBagBody(ctx: &bagCtx, cx: cx, bagTop: bagTop, bagBottom: visibleBottom, mouthSag: mouthSag, scene: scene)

        drawFlying(ctx: &ctx, front: true, scene: scene)
        guard drawStatus else { return }

        // Status capsule
        drawCapsuleStyled(
            ctx: &ctx,
            cx: cx,
            y: visibleBottom + Tunables.capsuleH / 2 + 6,
            label: scene.label,
            bobPhase: scene.bobPhase,
            reduceMotion: scene.reduceMotion,
            showDot: scene.showRecordingDot,
            style: .popcorn
        )
        if !scene.detail.isEmpty {
            let detail = Text(scene.detail)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(PaletteUI.popcornInk.opacity(0.78))
            ctx.draw(
                detail,
                at: CGPoint(x: cx, y: visibleBottom + Tunables.capsuleH + 16),
                anchor: .center
            )
        }
    }

    /// Bag, interior, heap, and settled kernels in unshifted scene coordinates.
    private static func drawBagBody(
        ctx: inout GraphicsContext,
        cx: CGFloat,
        bagTop: CGFloat,
        bagBottom: CGFloat,
        mouthSag: CGFloat,
        scene: SceneInput
    ) {
        let bag = bagPath(cx: cx, bagTop: bagTop, bagBottom: bagBottom, mouthSag: mouthSag)

        // Contact shadow offset
        ctx.drawLayer { layer in
            layer.translateBy(x: 0.5, y: 1.25)
            layer.fill(bag, with: .color(.black.opacity(0.07)))
        }

        // Dark interior / rear ellipse behind the heap. It is deliberately warm brown paper
        // shadow, with only small gaps remaining between the kernels.
        let innerRx = Tunables.mouthHalf - PopcornMetrics.rimThickness
        let innerRy = max(2, mouthSag - PopcornMetrics.rimThickness * 0.55)
        let interiorRect = CGRect(
            x: cx - innerRx,
            y: bagTop - innerRy,
            width: innerRx * 2,
            height: innerRy * 2
        )
        ctx.fill(
            Path(ellipseIn: interiorRect),
            with: .radialGradient(
                Gradient(colors: [
                    PaletteUI.popcornInterior,
                    PaletteUI.popcornInkShade.opacity(0.72),
                ]),
                center: CGPoint(x: cx, y: bagTop + 2),
                startRadius: 0,
                endRadius: innerRx
            )
        )
        // The rear half of the rolled lip belongs behind the heap.
        drawRimHalf(ctx: &ctx, cx: cx, bagTop: bagTop, mouthSag: mouthSag, front: false)

        // Far heap (behind bag body partially - drawn before bag fill so they sit in mouth)
        for index in HeapSeed.drawOrder where HeapSeed.pieces[index].far {
            drawHeapPiece(ctx: &ctx, index: index, piece: HeapSeed.pieces[index], cx: cx, bagTop: bagTop, scene: scene)
        }

        // Bag body fill
        ctx.fill(bag, with: .color(PaletteUI.popcornPaper))

        // Perspective stripes clipped to bag
        ctx.drawLayer { layer in
            layer.clip(to: bag)
            // Five tapered ink panels, with wider paper gaps and a centered panel.
            let centers: [CGFloat] = [0.10, 0.30, 0.50, 0.70, 0.90]
            let angularHalfWidth: CGFloat = 0.055
            for center in centers {
                let t0 = cylindricalT(center - angularHalfWidth)
                let t1 = cylindricalT(center + angularHalfWidth)
                let topL = mouthX(cx: cx, t: t0)
                let topR = mouthX(cx: cx, t: t1)
                let botL = cx - PopcornMetrics.baseHalf + PopcornMetrics.baseHalf * 2 * t0
                let botR = cx - PopcornMetrics.baseHalf + PopcornMetrics.baseHalf * 2 * t1
                let topYL = mouthY(bagTop: bagTop, sag: mouthSag, t: t0)
                let topYR = mouthY(bagTop: bagTop, sag: mouthSag, t: t1)
                var s = Path()
                s.move(to: CGPoint(x: topL, y: topYL))
                s.addLine(to: CGPoint(x: topR, y: topYR))
                s.addLine(to: CGPoint(x: botR, y: bagBottom + 2))
                s.addLine(to: CGPoint(x: botL, y: bagBottom + 2))
                s.closeSubpath()
                layer.fill(s, with: .color(PaletteUI.popcornInk))
            }

            // Broad paper shading gives the curved wall volume without glossy streaks.
            let left = CGPoint(x: cx - Tunables.mouthHalf, y: bagTop)
            let right = CGPoint(x: cx + Tunables.mouthHalf, y: bagTop)
            layer.fill(
                Path(CGRect(x: cx - Tunables.mouthHalf - 4, y: bagTop - 4,
                            width: Tunables.mouthHalf * 2 + 8, height: bagBottom - bagTop + 12)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: PaletteUI.popcornPaperLight.opacity(0.24), location: 0),
                        .init(color: PaletteUI.popcornPaperLight.opacity(0.08), location: 0.30),
                        .init(color: .clear, location: 0.48),
                        .init(color: PaletteUI.popcornPaperShade.opacity(0.16), location: 0.78),
                        .init(color: PaletteUI.popcornInkShade.opacity(0.13), location: 1),
                    ]),
                    startPoint: left,
                    endPoint: right
                )
            )
        }

        // Near heap + settled kernels
        for index in HeapSeed.drawOrder where !HeapSeed.pieces[index].far {
            drawHeapPiece(ctx: &ctx, index: index, piece: HeapSeed.pieces[index], cx: cx, bagTop: bagTop, scene: scene)
        }
        for k in scene.kernels where k.settled {
            drawKernel(
                ctx: &ctx,
                at: CGPoint(x: k.x, y: k.y),
                scale: k.scale, shape: k.shape, butter: k.butter,
                alpha: k.alpha, rot: k.rot, heat: scene.heat
            )
        }

        // Only the front half of the roll crosses the near heap, leaving its upper mound intact.
        drawRimHalf(ctx: &ctx, cx: cx, bagTop: bagTop, mouthSag: mouthSag, front: true)

        // Fine warm paper edge and a subtle lower seam.
        ctx.stroke(bag, with: .color(PaletteUI.popcornFineEdge.opacity(0.72)), lineWidth: 0.8)
        var seam = Path()
        seam.move(to: CGPoint(x: cx - PopcornMetrics.baseHalf + 5, y: bagBottom - 8))
        seam.addQuadCurve(to: CGPoint(x: cx + PopcornMetrics.baseHalf - 5, y: bagBottom - 8),
                          control: CGPoint(x: cx, y: bagBottom - 2))
        ctx.drawLayer { layer in
            layer.clip(to: bag)
            layer.stroke(seam, with: .color(PaletteUI.popcornPaperShade.opacity(0.62)), lineWidth: 0.8)
        }
    }

    private static func drawHeapPiece(
        ctx: inout GraphicsContext, index: Int, piece: HeapPiece, cx: CGFloat, bagTop: CGFloat, scene: SceneInput
    ) {
        let pose = !scene.reduceMotion && index < scene.heap.count ? scene.heap[index] : .rest
        drawKernel(
            ctx: &ctx,
            at: CGPoint(x: cx + piece.dx + CGFloat(pose.dx), y: bagTop + piece.dy + CGFloat(pose.dy)),
            scale: piece.s, shape: piece.shape, butter: piece.butter,
            alpha: 1, rot: piece.rot + CGFloat(pose.rot), heat: scene.heat
        )
    }

    private static func mouthX(cx: CGFloat, t: CGFloat) -> CGFloat {
        cx - Tunables.mouthHalf + Tunables.mouthHalf * 2 * t
    }

    /// Project evenly spaced ink panels around a shallow cylinder. This compresses the side
    /// panels while keeping the center panel intentional and symmetric.
    private static func cylindricalT(_ angularT: CGFloat) -> CGFloat {
        0.5 + 0.5 * sin((angularT - 0.5) * .pi)
    }

    private static func mouthY(bagTop: CGFloat, sag: CGFloat, t: CGFloat) -> CGFloat {
        // Front half of the rim ellipse: 0 at the sides, `sag` at the center.
        let u = min(1, max(-1, t * 2 - 1))
        return bagTop + sag * sqrt(1 - u * u)
    }

    /// Movie-theater tub: a smooth bowed wall and shallow rounded base.
    private static func bagPath(cx: CGFloat, bagTop: CGFloat, bagBottom: CGFloat, mouthSag: CGFloat) -> Path {
        var p = Path()
        let topL = CGPoint(x: cx - Tunables.mouthHalf, y: bagTop)
        let topR = CGPoint(x: cx + Tunables.mouthHalf, y: bagTop)
        let botL = CGPoint(x: cx - PopcornMetrics.baseHalf, y: bagBottom - PopcornMetrics.baseCorner)
        let botR = CGPoint(x: cx + PopcornMetrics.baseHalf, y: bagBottom - PopcornMetrics.baseCorner)
        let wallMidY = bagTop + (bagBottom - bagTop) * 0.56
        let wallTopX = Tunables.mouthHalf
        let wallMidX = (Tunables.mouthHalf + PopcornMetrics.baseHalf) * 0.52 + PopcornMetrics.sideBow

        p.move(to: topL)
        p.addCurve(to: topR,
                   control1: CGPoint(x: cx - 36, y: bagTop + mouthSag * 1.12),
                   control2: CGPoint(x: cx + 36, y: bagTop + mouthSag * 1.12))
        p.addCurve(to: botR,
                   control1: CGPoint(x: cx + wallTopX + 2, y: bagTop + (bagBottom - bagTop) * 0.28),
                   control2: CGPoint(x: cx + wallMidX + 2, y: wallMidY))
        p.addQuadCurve(to: botL, control: CGPoint(x: cx, y: bagBottom + PopcornMetrics.baseCorner * 0.9))
        p.addCurve(to: topL,
                   control1: CGPoint(x: cx - wallMidX - 2, y: wallMidY),
                   control2: CGPoint(x: cx - wallTopX - 2, y: bagTop + (bagBottom - bagTop) * 0.28))
        p.closeSubpath()
        return p
    }

    /// Draw one half of a rolled elliptical lip. Keeping the rear half separate prevents it
    /// from painting across the front kernels.
    private static func drawRimHalf(
        ctx: inout GraphicsContext,
        cx: CGFloat,
        bagTop: CGFloat,
        mouthSag: CGFloat
        , front: Bool
    ) {
        let outerRx = Tunables.mouthHalf + PopcornMetrics.rimOverhang
        let outerRy = mouthSag + PopcornMetrics.rimOverhang * 0.7
        let innerRx = Tunables.mouthHalf - PopcornMetrics.rimThickness
        let innerRy = max(2, mouthSag - PopcornMetrics.rimThickness * 0.55)
        let start = front ? 0.0 : Double.pi
        let end = front ? Double.pi : Double.pi * 2
        let samples = 18

        func point(rx: CGFloat, ry: CGFloat, angle: Double) -> CGPoint {
            CGPoint(x: cx + rx * CGFloat(cos(angle)), y: bagTop + ry * CGFloat(sin(angle)))
        }

        var ring = Path()
        for i in 0...samples {
            let angle = start + (end - start) * Double(i) / Double(samples)
            let p = point(rx: outerRx, ry: outerRy, angle: angle)
            if i == 0 { ring.move(to: p) } else { ring.addLine(to: p) }
        }
        for i in stride(from: samples, through: 0, by: -1) {
            let angle = start + (end - start) * Double(i) / Double(samples)
            ring.addLine(to: point(rx: innerRx, ry: innerRy, angle: angle))
        }
        ring.closeSubpath()

        ctx.drawLayer { layer in
            layer.translateBy(x: 0, y: front ? 1.4 : 0.8)
            layer.fill(ring, with: .color(PaletteUI.popcornInkShade.opacity(front ? 0.14 : 0.18)))
        }
        ctx.fill(ring, with: .linearGradient(
            Gradient(colors: [PaletteUI.popcornPaperLight, PaletteUI.popcornPaper]),
            startPoint: CGPoint(x: cx, y: bagTop - outerRy),
            endPoint: CGPoint(x: cx, y: bagTop + outerRy)
        ))
        ctx.stroke(ring, with: .color(PaletteUI.popcornFineEdge.opacity(0.82)), lineWidth: 0.75)

        if front {
            var edge = Path()
            for i in 0...samples {
                let angle = start + (end - start) * Double(i) / Double(samples)
                let p = point(rx: innerRx, ry: innerRy, angle: angle)
                if i == 0 { edge.move(to: p) } else { edge.addLine(to: p) }
            }
            ctx.stroke(edge, with: .color(PaletteUI.popcornPaperShade.opacity(0.75)), lineWidth: 0.8)
        }
    }

    // MARK: - Flying / haze / capsule

    private static func drawFlying(ctx: inout GraphicsContext, front: Bool, scene: SceneInput) {
        guard !scene.reduceMotion else { return }
        for k in scene.kernels where !k.settled && k.front == front {
            drawKernel(
                ctx: &ctx,
                at: CGPoint(x: k.x, y: k.y),
                scale: k.scale, shape: k.shape, butter: k.butter,
                alpha: k.alpha, rot: k.rot, heat: scene.heat, airborne: true
            )
        }
    }

    public static func drawHaze(
        ctx: inout GraphicsContext,
        cx: CGFloat,
        bagTop: CGFloat,
        scene: SceneInput
    ) {
        guard !scene.reduceMotion, scene.heat > 0.10 else { return }
        let strength = min(1, scene.heat)
        for i in 0..<4 {
            let x = cx + (CGFloat(i) - 1.5) * 18
            let sway = CGFloat(sin(scene.bobPhase * 2.2 + Double(i) * 1.8)) * strength * 3.5
            let bottom = CGPoint(x: x, y: bagTop - 18)
            let top = CGPoint(x: x + sway, y: bagTop - 54 - CGFloat(strength) * 14)
            var wisp = Path()
            wisp.move(to: bottom)
            wisp.addCurve(
                to: top,
                control1: CGPoint(x: x - sway * 0.6, y: bottom.y - 12),
                control2: CGPoint(x: x + sway * 0.8, y: top.y + 10)
            )
            ctx.stroke(
                wisp,
                with: .linearGradient(
                    Gradient(colors: [
                        PaletteUI.puffWhite.opacity(0.10 * strength),
                        Color.white.opacity(0.06 * strength),
                        .clear,
                    ]),
                    startPoint: bottom,
                    endPoint: top
                ),
                style: StrokeStyle(lineWidth: 1.6 + CGFloat(strength), lineCap: .round)
            )
        }
    }

    public static func drawCapsule(
        ctx: inout GraphicsContext,
        cx: CGFloat,
        y: CGFloat,
        label: String,
        bobPhase: Double,
        reduceMotion: Bool,
        showDot: Bool
    ) {
        drawCapsuleStyled(ctx: &ctx, cx: cx, y: y, label: label, bobPhase: bobPhase,
                          reduceMotion: reduceMotion, showDot: showDot, style: .legacy)
    }

    static func drawCapsuleStyled(
        ctx: inout GraphicsContext,
        cx: CGFloat,
        y: CGFloat,
        label: String,
        bobPhase: Double,
        reduceMotion: Bool,
        showDot: Bool,
        style: CapsuleStyle = .legacy
    ) {
        let rect = CGRect(
            x: cx - Tunables.capsuleW / 2,
            y: y - Tunables.capsuleH / 2,
            width: Tunables.capsuleW,
            height: Tunables.capsuleH
        )
        let path = Path(roundedRect: rect, cornerRadius: Tunables.capsuleH / 2)

        let premium = style == .popcorn

        // Soft drop shadow
        ctx.drawLayer { layer in
            layer.translateBy(x: 0, y: premium ? 1.5 : 2)
            layer.fill(path, with: .color(.black.opacity(premium ? 0.11 : 0.16)))
        }

        if premium {
            ctx.fill(path, with: .color(PaletteUI.popcornStatusSurface))
            ctx.stroke(path, with: .color(PaletteUI.popcornFineEdge.opacity(0.75)), lineWidth: 0.65)
        } else {
            ctx.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [
                        PaletteUI.bagCream,
                        PaletteUI.puffUnderside.opacity(0.55),
                    ]),
                    startPoint: CGPoint(x: cx, y: rect.minY),
                    endPoint: CGPoint(x: cx, y: rect.maxY)
                )
            )
            ctx.stroke(path, with: .color(PaletteUI.bagRed), lineWidth: 1.5)
        }

        let textFont = Font.system(
            size: premium ? 12.5 : Tunables.statusFontSize,
            weight: premium ? .semibold : .bold,
            design: premium ? .default : .rounded
        )
        let textColor = premium ? PaletteUI.popcornStatusText : PaletteUI.bagRed
        let resolvedText = ctx.resolve(Text(label).font(textFont).foregroundColor(textColor))
        let textWidth = resolvedText.measure(in: CGSize(width: rect.width, height: rect.height)).width
        let textX: CGFloat
        if showDot {
            let pulse: Double
            if reduceMotion {
                pulse = 1
            } else {
                pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(bobPhase * 6))
            }
            let dotR: CGFloat = premium ? 2.8 : 3.5
            let dotX: CGFloat
            if premium {
                let gap: CGFloat = 7
                let groupWidth = dotR * 2 + gap + textWidth
                let groupLeft = cx - groupWidth / 2
                dotX = groupLeft + dotR
                textX = groupLeft + dotR * 2 + gap + textWidth / 2
            } else {
                dotX = rect.minX + 16
                textX = cx + 4
            }
            ctx.fill(
                Path(ellipseIn: CGRect(x: dotX - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)),
                with: .color((premium ? PaletteUI.popcornRecordingDot : PaletteUI.bagRed).opacity(pulse))
            )
        } else {
            textX = cx
        }

        ctx.draw(Text(label).font(textFont).foregroundColor(textColor), at: CGPoint(x: textX, y: y), anchor: .center)
    }

    private static func popcornCapsuleY(bagBottom: CGFloat) -> CGFloat {
        bagBottom - PopcornMetrics.bottomShift + Tunables.capsuleH / 2 + 6
    }

    // MARK: - Kernel

    /// Unit-space silhouettes, converted from `KernelArt`'s cached `CGPath`s once per shape.
    private enum KernelShapeCache {
        static let outline: [Path] = (0..<KernelArt.templateCount).map { Path(KernelArt.path(shape: $0)) }
        static func index(_ shape: Int) -> Int {
            ((shape % KernelArt.templateCount) + KernelArt.templateCount) % KernelArt.templateCount
        }
    }

    /// Paint the kernel sprite cache for a display scale ahead of the first frame (about a few
    /// tens of milliseconds for a 2× display). Optional: sprites are otherwise painted on first use.
    public static func prewarmKernelSprites(displayScale: CGFloat) {
        KernelSprites.prewarm(density: KernelSprites.density(displayScale: displayScale))
    }

    /// One kernel: a soft contact shadow, the pre-rendered body sprite (lobes, butter, folds),
    /// and a scene-space light gradient over the silhouette. The light is computed in scene
    /// space and counter-rotated into the kernel's frame, so a tumbling kernel keeps its highlight
    /// on the upper left exactly like the resting pile. `airborne` only lightens the shadow.
    public static func drawKernel(
        ctx: inout GraphicsContext,
        at: CGPoint,
        scale: CGFloat,
        shape: Int,
        butter: CGFloat,
        alpha: Double,
        rot: CGFloat,
        heat: Double = 0,
        airborne: Bool = false
    ) {
        guard alpha > 0 else { return }
        // A fading kernel also shrinks a little and drops its shadow, so it melts away instead of
        // leaving a gray smudge on dark backgrounds.
        let fading = alpha < 1
        let r = CGFloat(Tunables.kernelRadius) * scale * (fading ? CGFloat(0.55 + 0.45 * alpha) : 1)
        let density = KernelSprites.density(displayScale: ctx.environment.displayScale)
        let e = KernelSprites.extent
        let unitRect = CGRect(x: -e, y: -e, width: e * 2, height: e * 2)
        let si = KernelShapeCache.index(shape)
        _ = heat

        var c = ctx
        if alpha < 1 { c.opacity *= alpha }

        if !fading {
            var shadow = c
            shadow.translateBy(x: at.x + 0.55, y: at.y + (airborne ? 1.1 : 1.35))
            shadow.rotate(by: .radians(Double(rot)))
            shadow.scaleBy(x: r, y: r)
            if airborne { shadow.opacity *= 0.8 }
            shadow.draw(KernelSprites.shadow(shape: si, density: density), in: unitRect)
        }

        c.translateBy(x: at.x, y: at.y)
        c.rotate(by: .radians(Double(rot)))
        c.scaleBy(x: r, y: r)
        c.draw(KernelSprites.body(shape: si, butter: butter, density: density), in: unitRect)

        let cosR = CGFloat(cos(Double(-rot)))
        let sinR = CGFloat(sin(Double(-rot)))
        func local(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * cosR - y * sinR, y: x * sinR + y * cosR)
        }
        c.fill(
            KernelShapeCache.outline[si],
            with: .linearGradient(PaletteUI.kernelLight, startPoint: local(-0.75, -0.95), endPoint: local(0.45, 0.95))
        )
    }
}
