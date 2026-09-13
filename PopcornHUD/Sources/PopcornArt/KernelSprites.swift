import AppKit
import CoreGraphics
import PopcornCore
import SwiftUI

/// Pre-rendered popcorn kernel bodies.
///
/// Drawing a kernel as a dozen vector gradient fills and transparency layers cost most of the
/// HUD's frame budget (see `PopcornCapture --bench`). Every detail that is attached to the kernel
/// itself - lobe volume, butter glaze, folds, hull fleck, rim - is rotation-invariant, so it is
/// painted once per shape, butter level, and variant into a small bitmap and drawn rotated.
/// Direction-dependent light is *not* baked in: `PopcornRenderer.drawKernel` lays one scene-space
/// gradient over the silhouette so airborne and piled kernels share the same upper-left light.
enum KernelSprites {
    /// Unit-space half-size covered by a sprite (outlines reach ~0.95, plus rim and blur).
    static let extent: CGFloat = 1.14
    static let butterLevels = 5
    static let variants = 3

    private struct Key: Hashable {
        var density: Int
        var shape: Int
        var level: Int
        var variant: Int
    }

    private static let lock = NSLock()
    private static var bodies: [Key: Image] = [:]
    private static var shadows: [Key: Image] = [:]

    /// Butter bucket and patch arrangement for a kernel's `butter` value. Spawned kernels draw
    /// butter from a seeded range and the decorative heap has fixed values, so the mapping is
    /// deterministic per kernel while still varying across the pile.
    static func butterBucket(_ butter: CGFloat) -> (level: Int, variant: Int) {
        let b = max(0, min(0.999, (Double(butter) - 0.04) / 0.38))
        let level = Int(b * Double(butterLevels))
        let variant = Int((Double(butter) * 1000).rounded()) % variants
        return (level, variant)
    }

    /// Pixel density bucket for the destination scale. 1× screens sample from 2× sprites: the
    /// downsample keeps small kernels' lobe edges slightly crisper than a 1× bitmap rotated in place.
    static func density(displayScale: CGFloat) -> Int {
        max(2, min(4, Int(displayScale.rounded(.up))))
    }

    static func body(shape: Int, butter: CGFloat, density: Int) -> Image {
        let (level, variant) = butterBucket(butter)
        return body(Key(density: density, shape: normalized(shape), level: level, variant: variant))
    }

    private static var prewarmed: Set<Int> = []

    private static func body(_ key: Key) -> Image {
        lock.lock()
        let cached = bodies[key]
        // The first miss at a new scale paints the rest of that scale's sprites in the
        // background, so a recording's first frames only paint what they draw.
        let startPrewarm = cached == nil && prewarmed.insert(key.density).inserted
        lock.unlock()
        if let cached { return cached }
        if startPrewarm {
            DispatchQueue.global(qos: .utility).async { prewarm(density: key.density) }
        }
        // Paint outside the lock so a background prewarm never stalls a frame for long.
        let image = render(density: key.density) { ctx in
            paintBody(ctx, shape: key.shape, level: key.level, variant: key.variant)
        }
        lock.lock()
        defer { lock.unlock() }
        if let raced = bodies[key] { return raced }
        bodies[key] = image
        return image
    }

    static func shadow(shape: Int, density: Int) -> Image {
        let key = Key(density: density, shape: normalized(shape), level: 0, variant: 0)
        lock.lock()
        let cached = shadows[key]
        lock.unlock()
        if let cached { return cached }
        let image = render(density: density) { ctx in
            paintShadow(ctx, shape: key.shape, density: density)
        }
        lock.lock()
        defer { lock.unlock() }
        if let raced = shadows[key] { return raced }
        shadows[key] = image
        return image
    }

    /// Paint every sprite for `density` (180 bodies and 12 shadows). Safe from any thread.
    static func prewarm(density: Int) {
        lock.lock()
        prewarmed.insert(density)
        lock.unlock()
        for shape in 0..<KernelArt.templateCount {
            _ = shadow(shape: shape, density: density)
            for level in 0..<butterLevels {
                for variant in 0..<variants {
                    _ = body(Key(density: density, shape: shape, level: level, variant: variant))
                }
            }
        }
    }

    private static func normalized(_ shape: Int) -> Int {
        ((shape % KernelArt.templateCount) + KernelArt.templateCount) % KernelArt.templateCount
    }

    /// Largest on-screen kernel: heap pieces reach scale 1.2.
    private static let maxKernelScale: CGFloat = 1.2

    private static func pixelsPerUnit(density: Int) -> CGFloat {
        CGFloat(density) * CGFloat(Tunables.kernelRadius) * maxKernelScale
    }

    private static func render(density: Int, paint: (CGContext) -> Void) -> Image {
        let ppu = pixelsPerUnit(density: density)
        let size = Int((extent * 2 * ppu).rounded(.up))
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Image(nsImage: NSImage()) }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        // Unit space with y down, matching KernelArt and SwiftUI: row 0 of the image is unit y = -extent.
        let k = CGFloat(size) / (extent * 2)
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: k, y: -k)
        ctx.translateBy(x: extent, y: extent)
        paint(ctx)
        guard let cg = ctx.makeImage() else { return Image(nsImage: NSImage()) }
        return Image(decorative: cg, scale: 1).interpolation(.high)
    }

    // MARK: - Painting

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func color(_ c: NSColor, _ alpha: CGFloat = 1) -> CGColor {
        c.usingColorSpace(.sRGB)!.withAlphaComponent(alpha).cgColor
    }

    private static func gradient(_ stops: [(NSColor, CGFloat, CGFloat)]) -> CGGradient {
        CGGradient(
            colorsSpace: space,
            colors: stops.map { color($0.0, $0.1) } as CFArray,
            locations: stops.map(\.2)
        )!
    }

    /// Fluffy lobe: creamy center, golden where it tucks under its neighbors.
    private static let lobeGradient = gradient([
        (Palette.kernelHighlight, 1.0, 0.0),
        (Palette.kernelHighlight, 1.0, 0.35),
        (Palette.kernelCream, 1.0, 0.84),
        (Palette.kernelGolden, 1.0, 1.0),
    ])

    private static let butterGradient = gradient([
        (Palette.kernelButter, 1.0, 0.0),
        (Palette.kernelButter, 0.75, 0.45),
        (Palette.kernelButter, 0.0, 1.0),
    ])

    private static let butterCoreGradient = gradient([
        (Palette.kernelButterDeep, 1.0, 0.0),
        (Palette.kernelButterDeep, 0.0, 1.0),
    ])

    private static let hullGradient = gradient([
        (Palette.kernelHullLight, 0.9, 0.0),
        (Palette.kernelHullDark, 0.8, 1.0),
    ])

    private static func fillEllipseGradient(
        _ ctx: CGContext, _ g: CGGradient, center: CGPoint, rx: CGFloat, ry: CGFloat
    ) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: rx, y: ry)
        ctx.addEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
        ctx.clip()
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        ctx.restoreGState()
    }

    private static func paintBody(_ ctx: CGContext, shape: Int, level: Int, variant: Int) {
        let outline = KernelArt.path(shape: shape)
        let lobes = KernelArt.lobes(shape: shape)

        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip()

        ctx.setFillColor(color(Palette.kernelCream))
        ctx.fill(CGRect(x: -extent, y: -extent, width: extent * 2, height: extent * 2))

        // Lobe puffs, largest first so small lobes sit on top as separate florets. Each lobe casts
        // a soft, offset-free occlusion shadow onto the lobes beneath it: the seams between
        // florets darken gently instead of being drawn as crease lines.
        let occlusionBlur = 0.10 * CGFloat(ctx.ctm.a)
        for lobe in lobes.sorted(by: { $0.rx * $0.ry > $1.rx * $1.ry }) {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: occlusionBlur, color: color(Palette.kernelAmber, 0.50))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            fillEllipseGradient(
                ctx, lobeGradient, center: CGPoint(x: lobe.x, y: lobe.y),
                rx: lobe.rx * 1.06, ry: lobe.ry * 1.06
            )
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        // Butter glaze: multiply keeps the lobe modelling underneath while saturating it gold.
        ctx.setBlendMode(.multiply)
        let patchCount = min(lobes.count, 1 + (level >= 2 ? 1 : 0) + (level >= 4 ? 1 : 0))
        let strength = 0.36 + 0.11 * CGFloat(level)
        for i in 0..<patchCount {
            let lobe = lobes[(variant + shape + i * 2) % lobes.count]
            let angle = Double(variant * 2 + shape + i) * 1.9
            let center = CGPoint(
                x: lobe.x + lobe.rx * 0.28 * CGFloat(cos(angle)),
                y: lobe.y + lobe.ry * 0.28 * CGFloat(sin(angle))
            )
            let a = strength * (i == 0 ? 1 : 0.8)
            ctx.saveGState()
            ctx.setAlpha(a)
            fillEllipseGradient(ctx, butterGradient, center: center, rx: lobe.rx * 0.66, ry: lobe.ry * 0.56)
            ctx.setAlpha(a * 0.18)
            fillEllipseGradient(ctx, butterCoreGradient, center: center, rx: lobe.rx * 0.34, ry: lobe.ry * 0.28)
            ctx.restoreGState()
        }

        // Soft folds: the outer part of each crease only, so no stitched "Y" meets in the middle.
        ctx.setLineCap(.round)
        for fold in KernelArt.folds(shape: shape) {
            let path = CGMutablePath()
            let steps = 8
            for j in 0...steps {
                let t = 0.45 + 0.45 * Double(j) / Double(steps)
                let p = fold.point(at: t)
                if j == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.addPath(path)
            ctx.setStrokeColor(color(Palette.kernelFold, 0.10))
            ctx.setLineWidth(0.13)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setStrokeColor(color(Palette.kernelFold, 0.12))
            ctx.setLineWidth(0.05)
            ctx.strokePath()
        }
        ctx.setBlendMode(.normal)

        // Small hull fleck on a third of the kernels.
        if variant == 0 {
        let hull = KernelArt.hull(shape: shape)
        let box = hull.boundingBox
        ctx.saveGState()
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.scaleBy(x: 0.5, y: 0.5)
        ctx.translateBy(x: -box.midX, y: -box.midY)
        ctx.addPath(hull)
        ctx.clip()
        ctx.drawRadialGradient(
            hullGradient,
            startCenter: CGPoint(x: box.midX - box.width * 0.2, y: box.midY - box.height * 0.2), startRadius: 0,
            endCenter: CGPoint(x: box.midX, y: box.midY), endRadius: max(box.width, box.height) * 0.7,
            options: [.drawsAfterEndLocation]
        )
        ctx.restoreGState()
        }

        // Warm inner rim so the silhouette holds on white without a dark outline.
        ctx.addPath(outline)
        ctx.setStrokeColor(color(Palette.kernelAmber, 0.16))
        ctx.setLineWidth(0.22)
        ctx.strokePath()
        ctx.addPath(outline)
        ctx.setStrokeColor(color(Palette.kernelAmber, 0.22))
        ctx.setLineWidth(0.08)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.addPath(outline)
        ctx.setStrokeColor(color(Palette.kernelEdge, 0.30))
        ctx.setLineWidth(0.035)
        ctx.strokePath()
    }

    private static func paintShadow(_ ctx: CGContext, shape: Int, density: Int) {
        let outline = KernelArt.path(shape: shape)
        let shadowColor = color(Palette.kernelShadow, 0.30)
        // Blur is specified in device pixels and ignores the CTM.
        ctx.setShadow(offset: .zero, blur: 1.6 * CGFloat(density), color: shadowColor)
        ctx.addPath(outline)
        ctx.setFillColor(shadowColor)
        ctx.fillPath()
    }
}
