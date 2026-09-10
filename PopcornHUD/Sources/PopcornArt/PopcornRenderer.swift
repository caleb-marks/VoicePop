import CoreGraphics
import PopcornCore
import SwiftUI

/// Shared Canvas drawing for the live HUD and offscreen capture tool.
public enum PopcornRenderer {

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
            mascot: Mascot = .popcorn
        ) {
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
            drawCapsule(
                ctx: &ctx, cx: cx, y: h - Tunables.capsuleH / 2 - 8,
                label: scene.label.isEmpty ? "Transcribing…" : scene.label,
                bobPhase: scene.bobPhase,
                reduceMotion: scene.reduceMotion,
                showDot: false
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
        scene: SceneInput
    ) {
        // Signed: positive = squash (wider, shorter); the spring's negative overshoot reads as a
        // slight stretch instead of freezing at rest, so there is no hitch at the zero crossing.
        let kick = scene.reduceMotion ? 0 : CGFloat(scene.kick)
        let squashOnly = max(0, kick)
        let mouthSag = Tunables.rimRy

        drawHaze(ctx: &ctx, cx: cx, bagTop: bagTop, scene: scene)
        drawFlying(ctx: &ctx, front: false, scene: scene)

        // Ground shadow under bag - widens slightly as the bag squashes
        let shadowRect = CGRect(
            x: cx - Tunables.baseHalf - 6 - squashOnly,
            y: bagBottom - 4,
            width: Tunables.baseHalf * 2 + 12 + squashOnly * 2,
            height: 14
        )
        ctx.fill(
            Path(ellipseIn: shadowRect),
            with: .radialGradient(
                Gradient(colors: [.black.opacity(0.20 + Double(squashOnly) * 0.008), .clear]),
                center: CGPoint(x: cx, y: bagBottom + 2),
                startRadius: 0,
                endRadius: Tunables.baseHalf + 8 + squashOnly
            )
        )

        // Recoil as squash-and-stretch anchored at the ground: each px of kick makes the
        // bag (and everything sitting in it) a little wider and shorter, then springs back.
        // Drawing into a transformed copy of the context keeps every bag/heap coordinate unchanged.
        var bagCtx = ctx
        if kick != 0 {
            let sx = 1 + kick * CGFloat(Tunables.kickSquashX)
            let sy = 1 - kick * CGFloat(Tunables.kickSquashY)
            bagCtx.translateBy(x: cx, y: bagBottom)
            bagCtx.scaleBy(x: sx, y: sy)
            bagCtx.translateBy(x: -cx, y: -bagBottom)
        }
        drawBagBody(ctx: &bagCtx, cx: cx, bagTop: bagTop, bagBottom: bagBottom, mouthSag: mouthSag, scene: scene)

        drawFlying(ctx: &ctx, front: true, scene: scene)

        // Status capsule
        drawCapsule(
            ctx: &ctx,
            cx: cx,
            y: bagBottom + Tunables.capsuleH / 2 + 6,
            label: scene.label,
            bobPhase: scene.bobPhase,
            reduceMotion: scene.reduceMotion,
            showDot: scene.showRecordingDot
        )
        if !scene.detail.isEmpty {
            let detail = Text(scene.detail)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(PaletteUI.bagRed.opacity(0.75))
            ctx.draw(
                detail,
                at: CGPoint(x: cx, y: bagBottom + Tunables.capsuleH + 16),
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
            layer.translateBy(x: 1.5, y: 2.5)
            layer.fill(bag, with: .color(.black.opacity(0.14)))
        }

        // Dark interior / rear ellipse behind heap - matches the rim's inner opening
        let innerRx = Tunables.mouthHalf - Tunables.rimBand
        let innerRy = max(2, mouthSag - Tunables.rimBand * 0.55)
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
                    PaletteUI.bagInterior,
                    PaletteUI.bagRed.opacity(0.55),
                ]),
                center: CGPoint(x: cx, y: bagTop + 2),
                startRadius: 0,
                endRadius: innerRx
            )
        )
        // Rear rim highlight
        var rearRim = Path()
        rearRim.addEllipse(in: CGRect(
            x: cx - innerRx - 1,
            y: bagTop - innerRy - 1,
            width: (innerRx + 1) * 2,
            height: (innerRy + 1) * 2
        ))
        ctx.stroke(rearRim, with: .color(PaletteUI.bagCream.opacity(0.35)), lineWidth: 1.2)

        // Far heap (behind bag body partially - drawn before bag fill so they sit in mouth)
        for (index, piece) in HeapSeed.pieces.enumerated() where piece.far {
            let bob = heapBob(index: index, scene: scene)
            drawKernel(
                ctx: &ctx,
                at: CGPoint(x: cx + piece.dx, y: bagTop + piece.dy + bob),
                scale: piece.s, shape: piece.shape, butter: piece.butter,
                alpha: 1, rot: piece.rot, heat: scene.heat
            )
        }

        // Bag body fill
        ctx.fill(bag, with: .color(PaletteUI.bagCream))

        // Perspective stripes clipped to bag
        ctx.drawLayer { layer in
            layer.clip(to: bag)
            let n = Tunables.stripeCount
            for i in 0..<n where i % 2 == 0 {
                let t0 = CGFloat(i) / CGFloat(n)
                let t1 = CGFloat(i + 1) / CGFloat(n)
                let topL = mouthX(cx: cx, t: t0)
                let topR = mouthX(cx: cx, t: t1)
                let botL = cx - Tunables.baseHalf + Tunables.baseHalf * 2 * t0
                let botR = cx - Tunables.baseHalf + Tunables.baseHalf * 2 * t1
                let topYL = mouthY(bagTop: bagTop, sag: mouthSag, t: t0)
                let topYR = mouthY(bagTop: bagTop, sag: mouthSag, t: t1)
                var s = Path()
                s.move(to: CGPoint(x: topL, y: topYL))
                s.addLine(to: CGPoint(x: topR, y: topYR))
                s.addLine(to: CGPoint(x: botR, y: bagBottom + 4))
                s.addLine(to: CGPoint(x: botL, y: bagBottom + 4))
                s.closeSubpath()
                layer.fill(s, with: .color(PaletteUI.bagRed))
            }

            // Vertical shading: left highlight, right shadow, specular band
            let left = CGPoint(x: cx - Tunables.mouthHalf, y: bagTop)
            let right = CGPoint(x: cx + Tunables.mouthHalf, y: bagTop)
            layer.fill(
                Path(CGRect(x: cx - Tunables.mouthHalf - 4, y: bagTop - 4,
                            width: Tunables.mouthHalf * 2 + 8, height: Tunables.bagH + 12)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.18), location: 0),
                        .init(color: .white.opacity(0.06), location: 0.28),
                        .init(color: .clear, location: 0.42),
                        .init(color: .black.opacity(0.10), location: 0.72),
                        .init(color: .black.opacity(0.22), location: 1),
                    ]),
                    startPoint: left,
                    endPoint: right
                )
            )
            // Soft specular vertical band ~30% from left
            let specX = cx - Tunables.mouthHalf * 0.4
            layer.fill(
                Path(CGRect(x: specX - 8, y: bagTop, width: 16, height: Tunables.bagH)),
                with: .linearGradient(
                    Gradient(colors: [.clear, .white.opacity(0.12), .clear]),
                    startPoint: CGPoint(x: specX - 8, y: bagTop),
                    endPoint: CGPoint(x: specX + 8, y: bagTop)
                )
            )
        }

        // Near heap + settled kernels
        for (index, piece) in HeapSeed.pieces.enumerated() where !piece.far {
            let bob = heapBob(index: index, scene: scene)
            drawKernel(
                ctx: &ctx,
                at: CGPoint(x: cx + piece.dx, y: bagTop + piece.dy + bob),
                scale: piece.s, shape: piece.shape, butter: piece.butter,
                alpha: 1, rot: piece.rot, heat: scene.heat
            )
        }
        for k in scene.kernels where k.settled {
            drawKernel(
                ctx: &ctx,
                at: CGPoint(x: k.x, y: k.y),
                scale: k.scale, shape: k.shape, butter: k.butter,
                alpha: k.alpha, rot: k.rot, heat: scene.heat
            )
        }

        // Rolled rim
        drawRimBand(ctx: &ctx, cx: cx, bagTop: bagTop, mouthSag: mouthSag)

        ctx.stroke(bag, with: .color(PaletteUI.bagRed.opacity(0.40)), lineWidth: 1.2)
    }

    private static func heapBob(index: Int, scene: SceneInput) -> CGFloat {
        if scene.reduceMotion || scene.heat < 0.12 { return 0 }
        return CGFloat(sin(scene.bobPhase * 5.5 + Double(index) * 2.1))
            * CGFloat(scene.heat) * 0.85
    }

    private static func mouthX(cx: CGFloat, t: CGFloat) -> CGFloat {
        cx - Tunables.mouthHalf + Tunables.mouthHalf * 2 * t
    }

    private static func mouthY(bagTop: CGFloat, sag: CGFloat, t: CGFloat) -> CGFloat {
        // Front half of the rim ellipse: 0 at the sides, `sag` at the center.
        let u = min(1, max(-1, t * 2 - 1))
        return bagTop + sag * sqrt(1 - u * u)
    }

    /// Movie-theater tub: elliptical rim, straight walls with a slight outward bow,
    /// narrower rounded base.
    private static func bagPath(cx: CGFloat, bagTop: CGFloat, bagBottom: CGFloat, mouthSag: CGFloat) -> Path {
        var p = Path()
        let topL = CGPoint(x: cx - Tunables.mouthHalf, y: bagTop)
        let topR = CGPoint(x: cx + Tunables.mouthHalf, y: bagTop)
        let botL = CGPoint(x: cx - Tunables.baseHalf, y: bagBottom - Tunables.baseCorner)
        let botR = CGPoint(x: cx + Tunables.baseHalf, y: bagBottom - Tunables.baseCorner)
        // Walls taper straight from rim to base; the control sits just outside the
        // midpoint of that line so the side reads as a shallow bow, not a pinch.
        let wallMidX = (Tunables.mouthHalf + Tunables.baseHalf) / 2 + Tunables.sidePinch
        let wallMidY = bagTop + Tunables.bagH * 0.55

        p.move(to: topL)
        // Front half of the rim ellipse.
        p.addQuadCurve(to: topR, control: CGPoint(x: cx, y: bagTop + mouthSag * 1.30))
        p.addQuadCurve(to: botR, control: CGPoint(x: cx + wallMidX, y: wallMidY))
        // Shallow base ellipse.
        p.addQuadCurve(to: botL, control: CGPoint(x: cx, y: bagBottom + Tunables.baseCorner * 0.9))
        p.addQuadCurve(to: topL, control: CGPoint(x: cx - wallMidX, y: wallMidY))
        p.closeSubpath()
        return p
    }

    /// Rolled rim: an elliptical ring around the mouth, overhanging the wall.
    private static func drawRimBand(
        ctx: inout GraphicsContext,
        cx: CGFloat,
        bagTop: CGFloat,
        mouthSag: CGFloat
    ) {
        let outerRx = Tunables.mouthHalf + Tunables.rimOverhang
        let outerRy = mouthSag + Tunables.rimOverhang * 0.7
        let innerRx = Tunables.mouthHalf - Tunables.rimBand
        let innerRy = max(2, mouthSag - Tunables.rimBand * 0.55)

        var ring = Path()
        ring.addEllipse(in: CGRect(
            x: cx - outerRx, y: bagTop - outerRy,
            width: outerRx * 2, height: outerRy * 2
        ))
        ring.addEllipse(in: CGRect(
            x: cx - innerRx, y: bagTop - innerRy,
            width: innerRx * 2, height: innerRy * 2
        ))
        let evenOdd = FillStyle(eoFill: true)

        // Soft shadow under the rim
        ctx.drawLayer { layer in
            layer.translateBy(x: 0, y: 1.6)
            layer.fill(ring, with: .color(.black.opacity(0.18)), style: evenOdd)
        }
        ctx.fill(ring, with: .linearGradient(
            Gradient(colors: [
                PaletteUI.bagCream,
                PaletteUI.bagCream.opacity(0.88),
            ]),
            startPoint: CGPoint(x: cx - outerRx, y: bagTop - outerRy),
            endPoint: CGPoint(x: cx + outerRx, y: bagTop + outerRy)
        ), style: evenOdd)
        ctx.stroke(ring, with: .color(PaletteUI.bagRed.opacity(0.55)), lineWidth: 1)

        // Specular along the top of the roll, front half only.
        var gleam = Path()
        for i in 0...16 {
            let t = CGFloat(i) / 16
            let x = mouthX(cx: cx, t: t)
            let y = mouthY(bagTop: bagTop, sag: mouthSag, t: t) - Tunables.rimBand * 0.30
            if i == 0 { gleam.move(to: CGPoint(x: x, y: y)) } else { gleam.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(gleam, with: .color(.white.opacity(0.30)), lineWidth: 1.4)
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
        let rect = CGRect(
            x: cx - Tunables.capsuleW / 2,
            y: y - Tunables.capsuleH / 2,
            width: Tunables.capsuleW,
            height: Tunables.capsuleH
        )
        let path = Path(roundedRect: rect, cornerRadius: Tunables.capsuleH / 2)

        // Soft drop shadow
        ctx.drawLayer { layer in
            layer.translateBy(x: 0, y: 2)
            layer.fill(path, with: .color(.black.opacity(0.16)))
        }

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

        let textX: CGFloat
        if showDot {
            let pulse: Double
            if reduceMotion {
                pulse = 1
            } else {
                pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(bobPhase * 6))
            }
            let dotR: CGFloat = 3.5
            let dotX = rect.minX + 16
            ctx.fill(
                Path(ellipseIn: CGRect(x: dotX - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)),
                with: .color(PaletteUI.bagRed.opacity(pulse))
            )
            textX = cx + 4
        } else {
            textX = cx
        }

        let text = Text(label)
            .font(.system(size: Tunables.statusFontSize, weight: .bold, design: .rounded))
            .foregroundColor(PaletteUI.bagRed)
        ctx.draw(text, at: CGPoint(x: textX, y: y), anchor: .center)
    }

    // MARK: - Kernel

    /// Unit-space SwiftUI `Path`s derived from `KernelArt`'s cached `CGPath`s. Pure functions of
    /// `shape`, so building them once per shape instead of once per kernel per frame is
    /// bit-identical output.
    private enum KernelShapeCache {
        static let toast: [Path] = (0..<KernelArt.templateCount).map { Path(KernelArt.toast(shape: $0)) }
        static let hull: [Path] = (0..<KernelArt.templateCount).map { Path(KernelArt.hull(shape: $0)) }
        static let hullBox: [CGRect] = hull.map(\.boundingRect)
        static let lobeHighlight: [[Path]] = (0..<KernelArt.templateCount).map { s in
            KernelArt.lobes(shape: s).map { Path(ellipseIn: $0.rect.insetBy(dx: -0.05, dy: -0.05)) }
        }
        static let butterPatch: [[Path]] = (0..<KernelArt.templateCount).map { s in
            KernelArt.lobes(shape: s).prefix(2).map { lobe in
                Path(ellipseIn: CGRect(
                    x: lobe.x - lobe.rx * 0.35,
                    y: lobe.y - lobe.ry * 0.25,
                    width: lobe.rx * 0.85,
                    height: lobe.ry * 0.65
                ))
            }
        }
        static func index(_ shape: Int) -> Int {
            ((shape % KernelArt.templateCount) + KernelArt.templateCount) % KernelArt.templateCount
        }
    }

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
        let r = CGFloat(Tunables.kernelRadius) * scale
        var transform = CGAffineTransform(translationX: at.x, y: at.y)
            .rotated(by: rot).scaledBy(x: r, y: r)
        guard let outline = KernelArt.path(shape: shape).copy(using: &transform),
              let creasePath = KernelArt.creases(shape: shape).copy(using: &transform)
        else { return }

        let silhouette = Path(outline)
        let creases = Path(creasePath)
        let shade = PaletteUI.puffShade
        let creaseColor = PaletteUI.puffCrease
        let b = Double(max(0, min(1, butter))) + heat * 0.03
        let lobes = KernelArt.lobes(shape: shape)
        let si = KernelShapeCache.index(shape)

        func paint(_ layer: inout GraphicsContext) {
            // 1. Contact shadow
            var shadow = layer
            shadow.translateBy(x: 0.7, y: 1.4)
            shadow.fill(silhouette, with: .color(.black.opacity(0.12)))

            // 2. Base fill - near-white with warm underside falloff
            layer.fill(
                silhouette,
                with: .linearGradient(
                    PaletteUI.kernelBase,
                    startPoint: CGPoint(x: at.x - r * 0.85, y: at.y - r * 0.9),
                    endPoint: CGPoint(x: at.x + r * 0.55, y: at.y + r * 0.95)
                )
            )

            // 3–6. Clipped detail in unit space (rotated with kernel)
            layer.drawLayer { detail in
                detail.clip(to: silhouette)
                detail.translateBy(x: at.x, y: at.y)
                detail.rotate(by: .radians(Double(rot)))
                detail.scaleBy(x: r, y: r)

                // Per-lobe radial volume shading (highlight only - shade comes from base gradient).
                // Airborne kernels are small and moving; skip the per-lobe pass to hold frame budget.
                if !airborne {
                    for (li, lobe) in lobes.enumerated() {
                        let hiCenter = CGPoint(x: lobe.x - lobe.rx * 0.35, y: lobe.y - lobe.ry * 0.40)
                        let lobePath = KernelShapeCache.lobeHighlight[si][li]
                        detail.fill(
                            lobePath,
                            with: .radialGradient(
                                PaletteUI.lobeHighlight,
                                center: hiCenter,
                                startRadius: 0,
                                endRadius: max(lobe.rx, lobe.ry) * 0.95
                            )
                        )
                    }
                }

                // Soft toast patches
                let toast = KernelShapeCache.toast[si]
                detail.fill(toast, with: .color(shade.opacity(0.18 + b * 0.14)))

                // Butter sheen on 1–2 lobes (first two)
                for (i, lobe) in lobes.prefix(2).enumerated() {
                    let strength = b * (i == 0 ? 0.70 : 0.40)
                    let patch = KernelShapeCache.butterPatch[si][i]
                    detail.fill(
                        patch,
                        with: .radialGradient(
                            Gradient(colors: [
                                PaletteUI.puffButter.opacity(strength),
                                .clear,
                            ]),
                            center: CGPoint(x: lobe.x, y: lobe.y),
                            startRadius: 0,
                            endRadius: max(lobe.rx, lobe.ry) * 0.55
                        )
                    )
                }

                // Hull remnant - drawn in unit space so gradient and speck rotate with the kernel.
                let hullUnit = KernelShapeCache.hull[si]
                let hullBox = KernelShapeCache.hullBox[si]
                let hullCenter = CGPoint(x: hullBox.midX, y: hullBox.midY)
                detail.fill(
                    hullUnit,
                    with: .radialGradient(
                        PaletteUI.hull,
                        center: CGPoint(x: hullCenter.x - 0.03, y: hullCenter.y - 0.02),
                        startRadius: 0,
                        endRadius: max(hullBox.width, hullBox.height) * 0.75
                    )
                )
                detail.fill(
                    Path(ellipseIn: CGRect(
                        x: hullCenter.x - 0.05, y: hullCenter.y - 0.045,
                        width: 0.05, height: 0.04
                    )),
                    with: .color(.white.opacity(0.45))
                )
            }

            // Creases in scene space (already transformed)
            layer.drawLayer { fold in
                fold.clip(to: silhouette)
                fold.stroke(
                    creases,
                    with: .color(shade.opacity(0.26)),
                    style: StrokeStyle(lineWidth: r * 0.16, lineCap: .round)
                )
                fold.stroke(
                    creases,
                    with: .color(creaseColor.opacity(0.55)),
                    style: StrokeStyle(lineWidth: r * 0.04, lineCap: .round)
                )
            }

            // Faint full outline for dark-bg readability. Upper-left rim light comes from the
            // base gradient; a separate rim layer was dropped to hold the frame budget.
            layer.stroke(silhouette, with: .color(shade.opacity(0.12)), lineWidth: 0.45)
        }

        // Opacity 1.0 with a normal blend mode makes the transparency layer a no-op, and that is
        // the entire settled heap. Draw straight into the caller's context instead.
        if alpha >= 1 {
            paint(&ctx)
        } else {
            ctx.drawLayer { layer in
                layer.opacity = alpha
                paint(&layer)
            }
        }
    }
}
