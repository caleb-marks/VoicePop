import CoreGraphics
import Foundation

/// Cached asymmetric popcorn silhouettes (12 shapes) with crease, hull, and lobe data.
/// Geometry is built once; never regenerated per frame.
public enum KernelArt {
    public static let templateCount = 12

    /// Unit-space lobe ellipse for per-lobe shading.
    public struct Lobe: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var rx: Double
        public var ry: Double

        public var rect: CGRect {
            CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2)
        }
    }

    /// Unit-space path (~radius 1), drawn scaled.
    public static func path(shape: Int) -> CGPath {
        outlines[normalized(shape)]
    }

    /// Thin crease strokes in unit space (stroke, do not fill).
    public static func creases(shape: Int) -> CGPath {
        creasePaths[normalized(shape)]
    }

    public static func toast(shape: Int) -> CGPath {
        toastPaths[normalized(shape)]
    }

    /// Dark pericarp remnant path (fill).
    public static func hull(shape: Int) -> CGPath {
        hullPaths[normalized(shape)]
    }

    /// Per-lobe ellipses in unit space for volume shading.
    public static func lobes(shape: Int) -> [Lobe] {
        lobeLists[normalized(shape)]
    }

    private static func normalized(_ shape: Int) -> Int {
        ((shape % templateCount) + templateCount) % templateCount
    }

    private static let outlines: [CGPath] = (0..<templateCount).map { outline(for: $0) }
    private static let creasePaths: [CGPath] = (0..<templateCount).map { creasePath(for: $0) }
    private static let toastPaths: [CGPath] = (0..<templateCount).map { toastPath(for: $0) }
    private static let hullPaths: [CGPath] = (0..<templateCount).map { hullPath(for: $0) }
    private static let lobeLists: [[Lobe]] = (0..<templateCount).map { lobeList(for: $0) }

    /// Irregular blob centers - deliberately uneven spacing (not flower/star symmetry).
    private struct Blob {
        var x: Double
        var y: Double
        var rx: Double
        var ry: Double
    }

    private struct Crease {
        var x0: Double, y0: Double
        var x1: Double, y1: Double
        var cx: Double, cy: Double
    }

    private struct HullSpec {
        var x: Double
        var y: Double
        var rx: Double
        var ry: Double
        var tilt: Double
    }

    private struct Recipe {
        var blobs: [Blob]
        var creases: [Crease]
        var toast: [(x: Double, y: Double, w: Double, h: Double)]
        var hull: HullSpec
        var squashY: Double
    }

    private static let recipes: [Recipe] = [
        // 0 - lopsided three-cluster
        Recipe(blobs: [
            Blob(x: -0.18, y: -0.12, rx: 0.55, ry: 0.48),
            Blob(x: 0.32, y: -0.05, rx: 0.42, ry: 0.50),
            Blob(x: 0.02, y: 0.35, rx: 0.48, ry: 0.38),
            Blob(x: -0.35, y: 0.22, rx: 0.28, ry: 0.32),
        ], creases: [
            Crease(x0: 0.02, y0: 0.02, x1: -0.28, y1: -0.28, cx: -0.18, cy: -0.08),
            Crease(x0: 0.04, y0: 0.04, x1: 0.38, y1: -0.18, cx: 0.22, cy: 0.02),
            Crease(x0: 0.02, y0: 0.06, x1: 0.08, y1: 0.42, cx: 0.10, cy: 0.22),
        ], toast: [(0.08, 0.05, 0.22, 0.14), (-0.20, 0.15, 0.12, 0.10)],
            hull: HullSpec(x: 0.02, y: 0.04, rx: 0.11, ry: 0.07, tilt: 0.35), squashY: 0.94),
        // 1 - tall with shoulder
        Recipe(blobs: [
            Blob(x: -0.08, y: -0.30, rx: 0.45, ry: 0.52),
            Blob(x: 0.28, y: -0.10, rx: 0.38, ry: 0.42),
            Blob(x: -0.28, y: 0.15, rx: 0.40, ry: 0.36),
            Blob(x: 0.05, y: 0.32, rx: 0.50, ry: 0.34),
        ], creases: [
            Crease(x0: -0.02, y0: 0.0, x1: -0.22, y1: -0.38, cx: -0.18, cy: -0.15),
            Crease(x0: 0.0, y0: 0.02, x1: 0.32, y1: -0.22, cx: 0.18, cy: -0.05),
            Crease(x0: 0.0, y0: 0.04, x1: 0.08, y1: 0.38, cx: 0.05, cy: 0.20),
        ], toast: [(-0.05, -0.15, 0.18, 0.12), (0.20, 0.10, 0.10, 0.08)],
            hull: HullSpec(x: -0.02, y: 0.02, rx: 0.10, ry: 0.065, tilt: -0.4), squashY: 0.90),
        // 2 - wide low cloud
        Recipe(blobs: [
            Blob(x: -0.40, y: 0.05, rx: 0.38, ry: 0.36),
            Blob(x: -0.05, y: -0.15, rx: 0.48, ry: 0.42),
            Blob(x: 0.38, y: 0.00, rx: 0.40, ry: 0.38),
            Blob(x: 0.12, y: 0.28, rx: 0.36, ry: 0.30),
            Blob(x: -0.22, y: 0.30, rx: 0.28, ry: 0.26),
        ], creases: [
            Crease(x0: -0.02, y0: 0.02, x1: -0.42, y1: 0.08, cx: -0.22, cy: -0.05),
            Crease(x0: 0.0, y0: 0.0, x1: 0.40, y1: -0.05, cx: 0.20, cy: -0.12),
            Crease(x0: 0.0, y0: 0.04, x1: 0.12, y1: 0.32, cx: 0.08, cy: 0.18),
        ], toast: [(0.0, 0.0, 0.20, 0.12), (0.30, 0.12, 0.12, 0.09)],
            hull: HullSpec(x: -0.02, y: 0.02, rx: 0.12, ry: 0.07, tilt: 0.15), squashY: 0.96),
        // 3 - chunky kidney
        Recipe(blobs: [
            Blob(x: -0.22, y: -0.05, rx: 0.52, ry: 0.45),
            Blob(x: 0.30, y: -0.18, rx: 0.36, ry: 0.40),
            Blob(x: 0.18, y: 0.30, rx: 0.44, ry: 0.36),
        ], creases: [
            Crease(x0: 0.05, y0: 0.0, x1: -0.35, y1: -0.18, cx: -0.12, cy: -0.15),
            Crease(x0: 0.06, y0: 0.02, x1: 0.38, y1: -0.22, cx: 0.22, cy: -0.05),
            Crease(x0: 0.05, y0: 0.04, x1: 0.20, y1: 0.38, cx: 0.12, cy: 0.20),
        ], toast: [(0.05, -0.05, 0.24, 0.14)],
            hull: HullSpec(x: 0.06, y: 0.02, rx: 0.115, ry: 0.07, tilt: 0.55), squashY: 0.93),
        // 4 - irregular butterfly (uneven wings)
        Recipe(blobs: [
            Blob(x: -0.38, y: -0.18, rx: 0.36, ry: 0.44),
            Blob(x: 0.42, y: -0.08, rx: 0.32, ry: 0.38),
            Blob(x: 0.0, y: 0.10, rx: 0.42, ry: 0.40),
            Blob(x: -0.10, y: 0.38, rx: 0.34, ry: 0.28),
        ], creases: [
            Crease(x0: 0.0, y0: 0.05, x1: -0.40, y1: -0.22, cx: -0.20, cy: -0.05),
            Crease(x0: 0.02, y0: 0.05, x1: 0.44, y1: -0.12, cx: 0.24, cy: 0.0),
            Crease(x0: 0.0, y0: 0.08, x1: -0.08, y1: 0.42, cx: -0.02, cy: 0.25),
        ], toast: [(-0.15, 0.0, 0.16, 0.11), (0.22, 0.08, 0.10, 0.08)],
            hull: HullSpec(x: 0.0, y: 0.06, rx: 0.10, ry: 0.065, tilt: -0.2), squashY: 0.92),
        // 5 - compact with side bump
        Recipe(blobs: [
            Blob(x: 0.0, y: -0.05, rx: 0.50, ry: 0.48),
            Blob(x: 0.35, y: 0.15, rx: 0.32, ry: 0.34),
            Blob(x: -0.30, y: 0.22, rx: 0.30, ry: 0.28),
            Blob(x: -0.12, y: -0.35, rx: 0.28, ry: 0.26),
        ], creases: [
            Crease(x0: 0.02, y0: 0.0, x1: 0.38, y1: 0.18, cx: 0.22, cy: 0.05),
            Crease(x0: 0.0, y0: 0.02, x1: -0.32, y1: 0.26, cx: -0.15, cy: 0.12),
            Crease(x0: 0.0, y0: -0.02, x1: -0.14, y1: -0.38, cx: -0.05, cy: -0.20),
        ], toast: [(0.05, 0.05, 0.18, 0.12)],
            hull: HullSpec(x: 0.02, y: 0.0, rx: 0.105, ry: 0.068, tilt: 0.25), squashY: 0.95),
        // 6 - diagonal cluster
        Recipe(blobs: [
            Blob(x: -0.30, y: -0.28, rx: 0.38, ry: 0.36),
            Blob(x: 0.05, y: -0.05, rx: 0.46, ry: 0.42),
            Blob(x: 0.32, y: 0.25, rx: 0.40, ry: 0.36),
            Blob(x: -0.20, y: 0.28, rx: 0.30, ry: 0.28),
        ], creases: [
            Crease(x0: 0.02, y0: 0.0, x1: -0.32, y1: -0.32, cx: -0.15, cy: -0.12),
            Crease(x0: 0.04, y0: 0.02, x1: 0.36, y1: 0.28, cx: 0.20, cy: 0.12),
            Crease(x0: 0.02, y0: 0.04, x1: -0.22, y1: 0.32, cx: -0.08, cy: 0.18),
        ], toast: [(0.0, 0.0, 0.20, 0.13), (-0.22, -0.15, 0.10, 0.08)],
            hull: HullSpec(x: 0.03, y: 0.02, rx: 0.11, ry: 0.07, tilt: 0.7), squashY: 0.91),
        // 7 - five-blob cloud (irregular)
        Recipe(blobs: [
            Blob(x: -0.35, y: -0.10, rx: 0.30, ry: 0.32),
            Blob(x: -0.05, y: -0.28, rx: 0.36, ry: 0.30),
            Blob(x: 0.32, y: -0.12, rx: 0.34, ry: 0.36),
            Blob(x: 0.18, y: 0.28, rx: 0.38, ry: 0.30),
            Blob(x: -0.22, y: 0.25, rx: 0.34, ry: 0.32),
        ], creases: [
            Crease(x0: 0.0, y0: 0.0, x1: -0.38, y1: -0.12, cx: -0.18, cy: -0.08),
            Crease(x0: 0.02, y0: -0.02, x1: 0.34, y1: -0.16, cx: 0.18, cy: -0.05),
            Crease(x0: 0.0, y0: 0.04, x1: 0.18, y1: 0.32, cx: 0.10, cy: 0.18),
        ], toast: [(0.08, -0.05, 0.16, 0.10), (-0.18, 0.12, 0.11, 0.09)],
            hull: HullSpec(x: 0.0, y: 0.02, rx: 0.10, ry: 0.06, tilt: -0.15), squashY: 0.94),
        // 8 - soft pear
        Recipe(blobs: [
            Blob(x: -0.05, y: -0.28, rx: 0.40, ry: 0.38),
            Blob(x: 0.15, y: 0.05, rx: 0.48, ry: 0.44),
            Blob(x: -0.28, y: 0.18, rx: 0.36, ry: 0.34),
            Blob(x: 0.05, y: 0.35, rx: 0.42, ry: 0.30),
        ], creases: [
            Crease(x0: 0.02, y0: 0.02, x1: -0.08, y1: -0.35, cx: -0.02, cy: -0.15),
            Crease(x0: 0.04, y0: 0.04, x1: -0.32, y1: 0.22, cx: -0.12, cy: 0.12),
            Crease(x0: 0.04, y0: 0.06, x1: 0.08, y1: 0.40, cx: 0.10, cy: 0.22),
        ], toast: [(0.0, 0.08, 0.22, 0.14)],
            hull: HullSpec(x: 0.04, y: 0.04, rx: 0.108, ry: 0.068, tilt: 0.4), squashY: 0.89),
        // 9 - roundish with offset bite
        Recipe(blobs: [
            Blob(x: 0.0, y: 0.0, rx: 0.52, ry: 0.50),
            Blob(x: 0.30, y: -0.22, rx: 0.28, ry: 0.30),
            Blob(x: -0.32, y: 0.18, rx: 0.30, ry: 0.28),
        ], creases: [
            Crease(x0: 0.02, y0: -0.02, x1: 0.32, y1: -0.28, cx: 0.18, cy: -0.12),
            Crease(x0: 0.0, y0: 0.02, x1: -0.35, y1: 0.22, cx: -0.15, cy: 0.10),
        ], toast: [(0.05, -0.05, 0.18, 0.12), (-0.20, 0.10, 0.10, 0.08)],
            hull: HullSpec(x: 0.02, y: 0.0, rx: 0.10, ry: 0.065, tilt: -0.5), squashY: 0.97),
        // 10 - jagged spill
        Recipe(blobs: [
            Blob(x: -0.28, y: -0.22, rx: 0.34, ry: 0.30),
            Blob(x: 0.10, y: -0.30, rx: 0.32, ry: 0.28),
            Blob(x: 0.38, y: -0.02, rx: 0.30, ry: 0.36),
            Blob(x: 0.08, y: 0.22, rx: 0.44, ry: 0.36),
            Blob(x: -0.30, y: 0.20, rx: 0.36, ry: 0.32),
        ], creases: [
            Crease(x0: 0.0, y0: 0.0, x1: -0.30, y1: -0.26, cx: -0.12, cy: -0.12),
            Crease(x0: 0.02, y0: -0.02, x1: 0.40, y1: -0.05, cx: 0.22, cy: -0.10),
            Crease(x0: 0.0, y0: 0.04, x1: 0.10, y1: 0.30, cx: 0.08, cy: 0.16),
        ], toast: [(0.05, 0.0, 0.14, 0.10), (0.25, -0.10, 0.10, 0.08)],
            hull: HullSpec(x: 0.0, y: 0.02, rx: 0.11, ry: 0.07, tilt: 0.3), squashY: 0.93),
        // 11 - squat mushroom
        Recipe(blobs: [
            Blob(x: -0.15, y: -0.20, rx: 0.48, ry: 0.40),
            Blob(x: 0.28, y: -0.12, rx: 0.38, ry: 0.36),
            Blob(x: 0.0, y: 0.25, rx: 0.50, ry: 0.36),
            Blob(x: -0.35, y: 0.10, rx: 0.26, ry: 0.28),
        ], creases: [
            Crease(x0: 0.0, y0: 0.02, x1: -0.20, y1: -0.32, cx: -0.08, cy: -0.12),
            Crease(x0: 0.02, y0: 0.02, x1: 0.34, y1: -0.18, cx: 0.18, cy: -0.05),
            Crease(x0: 0.0, y0: 0.06, x1: 0.0, y1: 0.38, cx: 0.05, cy: 0.22),
        ], toast: [(0.0, -0.05, 0.20, 0.12)],
            hull: HullSpec(x: 0.0, y: 0.04, rx: 0.112, ry: 0.07, tilt: -0.25), squashY: 0.95),
    ]

    private static func lobeList(for shape: Int) -> [Lobe] {
        let recipe = recipes[shape]
        return recipe.blobs.map {
            Lobe(x: $0.x, y: $0.y * recipe.squashY, rx: $0.rx, ry: $0.ry * recipe.squashY)
        }
    }

    private static func outline(for shape: Int) -> CGPath {
        let recipe = recipes[shape]
        let samples = 64
        var pts: [CGPoint] = []
        pts.reserveCapacity(samples)
        for i in 0..<samples {
            let ang = Double(i) / Double(samples) * 2 * .pi
            let dirX = cos(ang)
            let dirY = sin(ang)
            var best = 0.28
            for blob in recipe.blobs {
                let lx = dirX
                let ly = dirY
                let ox = -blob.x
                let oy = -blob.y
                let invRx2 = 1 / (blob.rx * blob.rx)
                let invRy2 = 1 / (blob.ry * blob.ry)
                let a = lx * lx * invRx2 + ly * ly * invRy2
                let b = 2 * (ox * lx * invRx2 + oy * ly * invRy2)
                let c = ox * ox * invRx2 + oy * oy * invRy2 - 1
                let disc = b * b - 4 * a * c
                guard disc >= 0, a > 1e-9 else { continue }
                let s = sqrt(disc)
                let t1 = (-b - s) / (2 * a)
                let t2 = (-b + s) / (2 * a)
                let cand = max(t1, t2)
                if cand > best { best = cand }
            }
            // Deterministic edge roughness - puffed, not airbrushed.
            let bump = sin(Double(shape + 1) * 2.7 + Double(i) * 1.37) * 0.035
                + sin(Double(shape) * 5.1 + Double(i) * 2.9) * 0.018
            best *= 1.0 + bump
            pts.append(CGPoint(x: dirX * best, y: dirY * best * recipe.squashY))
        }
        return closedCubic(through: pts)
    }

    private static func creasePath(for shape: Int) -> CGPath {
        let recipe = recipes[shape]
        let path = CGMutablePath()
        for c in recipe.creases {
            path.move(to: CGPoint(x: c.x0, y: c.y0 * recipe.squashY))
            path.addQuadCurve(
                to: CGPoint(x: c.x1, y: c.y1 * recipe.squashY),
                control: CGPoint(x: c.cx, y: c.cy * recipe.squashY)
            )
        }
        return path
    }

    private static func toastPath(for shape: Int) -> CGPath {
        let recipe = recipes[shape]
        let path = CGMutablePath()
        for t in recipe.toast {
            path.addEllipse(in: CGRect(
                x: t.x - t.w * 0.5,
                y: (t.y - t.h * 0.5) * recipe.squashY,
                width: t.w,
                height: t.h * recipe.squashY
            ))
        }
        return path
    }

    private static func hullPath(for shape: Int) -> CGPath {
        let recipe = recipes[shape]
        let h = recipe.hull
        let path = CGMutablePath()
        // Kidney / teardrop: ellipse with a pinched tip.
        let samples = 24
        var pts: [CGPoint] = []
        pts.reserveCapacity(samples)
        let cosT = cos(h.tilt)
        let sinT = sin(h.tilt)
        for i in 0..<samples {
            let ang = Double(i) / Double(samples) * 2 * .pi
            // Pinch one side for teardrop silhouette.
            let pinch = 1.0 - 0.35 * max(0, cos(ang))
            let lx = cos(ang) * h.rx * pinch
            let ly = sin(ang) * h.ry
            let rx = lx * cosT - ly * sinT
            let ry = lx * sinT + ly * cosT
            pts.append(CGPoint(x: h.x + rx, y: (h.y + ry) * recipe.squashY))
        }
        path.move(to: pts[0])
        for i in 1..<pts.count {
            path.addLine(to: pts[i])
        }
        path.closeSubpath()
        return path
    }

    private static func closedCubic(through pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard pts.count >= 3 else { return path }
        let n = pts.count
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n]
            let p1 = pts[i]
            let p2 = pts[(i + 1) % n]
            let p3 = pts[(i + 2) % n]
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }
}
