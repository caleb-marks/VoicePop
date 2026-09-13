import Foundation

/// Displacement of one decorative heap piece from its `HeapSeed` rest pose, in scene points and
/// radians. `.rest` is exactly zero.
public struct HeapPose: Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public var rot: Double

    public init(dx: Double = 0, dy: Double = 0, rot: Double = 0) {
        self.dx = dx
        self.dy = dy
        self.rot = rot
    }

    public static let rest = HeapPose()
}

/// Constrained spring simulation for the decorative popcorn pile.
///
/// Each `HeapSeed` piece is a damped spring around its rest pose with its own stiffness, damping,
/// and travel limits. Exposed upper pieces are soft and can hop; buried lower pieces are stiff and
/// barely rock. Neighbors are coupled so a shove spreads through the pile instead of moving one
/// piece in isolation. Three things drive it:
///
/// - **Agitation** while speech is energetic: every piece follows its own slow, band-limited
///   random target (an Ornstein-Uhlenbeck process), scaled by a smoothed energy envelope, so the
///   pile shifts continuously without synchronizing and eases down in pauses.
/// - **Disturbances** from launches and landings: a velocity impulse that falls off with distance
///   from the contact point.
/// - **Hops** on speech onsets: an upward kick weighted toward exposed pieces.
///
/// Positions, velocities, and the energy envelope are all clamped, so no input sequence can make
/// the pile drift, explode, or grow work per step. It runs inside `PopcornSim`'s fixed step and
/// uses its own seeded RNG stream, so it never perturbs kernel emission.
struct HeapMotion {
    struct Piece {
        var restX: Double         // scene x offset from tub center
        var restY: Double         // scene y offset from the rim line
        var exposure: Double      // 0 buried … 1 top of the pile
        var stiffness: Double     // 1/s²
        var damping: Double       // 1/s
        var rotStiffness: Double
        var rotDamping: Double
        var maxX: Double
        var maxUp: Double
        var maxDown: Double
        var maxRot: Double
        var mobility: Double      // share of an impulse this piece takes
        var noiseTau: Double      // seconds
    }

    struct Link {
        var a: Int
        var b: Int
        var strength: Double      // 1/s²
    }

    static let maxSpeed = 80.0          // pt/s
    static let maxSpin = 4.0            // rad/s
    static let impulseRadius = 16.0     // pt, Gaussian sigma of a disturbance
    static let energyAttack = 14.0      // 1/s
    static let energyRelease = 2.6      // 1/s: ~0.4 s to fall by 2/3 in a pause
    static let hopSpeed = 75.0          // pt/s upward for a fully exposed piece
    static let sleepEpsilon = 0.004

    private(set) var pieces: [Piece]
    private(set) var links: [Link]
    private(set) var pose: [HeapPose]
    private(set) var velocity: [HeapPose]
    private(set) var previous: [HeapPose]
    private var noise: [HeapPose]
    private var accel: [HeapPose]
    private let surfaceWeights: [[Double]]
    private var surfaceTable: [Double]
    private(set) var energy: Double = 0
    private(set) var asleep = true
    private var rng: SeededRNG

    init(seed: UInt64) {
        pieces = HeapSeed.pieces.enumerated().map { Self.makePiece(index: $0.offset, seed: $0.element) }
        links = Self.makeLinks(pieces)
        let zeros = [HeapPose](repeating: .rest, count: pieces.count)
        pose = zeros
        velocity = zeros
        previous = zeros
        noise = zeros
        accel = zeros
        surfaceWeights = Self.makeSurfaceWeights(pieces)
        surfaceTable = [Double](repeating: 0, count: Self.surfaceSamples)
        rng = SeededRNG(seed: seed ^ 0x6865_6170_6D6F_7465)
    }

    mutating func reset(seed: UInt64) {
        self = HeapMotion(seed: seed)
    }

    /// Stable per-piece jitter in 0..<1, independent of the simulation seed: the pile's
    /// personality (which pieces are loose) stays the same from one recording to the next.
    private static func jitter(_ index: Int, _ salt: Double) -> Double {
        let v = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private static func makePiece(index i: Int, seed p: HeapPiece) -> Piece {
        // HeapSeed dy runs from about +4 (buried at the rim) to -36 (crown).
        var exposure = max(0, min(1, (4 - Double(p.dy)) / 40))
        // Pieces wedged against the rim shoulders are held by the paper, too.
        exposure *= 1 - 0.35 * max(0, min(1, (abs(Double(p.dx)) - 30) / 14))
        if p.far { exposure *= 0.9 }
        let k = lerp(1100, 300, exposure) * (0.8 + 0.4 * jitter(i, 1))
        let zeta = lerp(0.60, 0.30, exposure) * (0.85 + 0.3 * jitter(i, 2))
        let kr = k * (1.1 + 0.5 * jitter(i, 3))
        let zetaR = lerp(0.55, 0.28, exposure) * (0.85 + 0.3 * jitter(i, 4))
        return Piece(
            restX: Double(p.dx), restY: Double(p.dy), exposure: exposure,
            stiffness: k, damping: 2 * zeta * sqrt(k),
            rotStiffness: kr, rotDamping: 2 * zetaR * sqrt(kr),
            maxX: lerp(0.5, 2.4, exposure), maxUp: lerp(0.35, 3.2, exposure),
            maxDown: lerp(0.25, 0.9, exposure), maxRot: lerp(0.03, 0.16, exposure),
            mobility: lerp(0.45, 1.0, exposure),
            noiseTau: 0.10 + 0.20 * jitter(i, 5)
        )
    }

    private static func makeLinks(_ pieces: [Piece]) -> [Link] {
        var out: [Link] = []
        let reach = 22.0
        for a in pieces.indices {
            for b in (a + 1)..<pieces.count {
                let d = hypot(pieces[a].restX - pieces[b].restX, pieces[a].restY - pieces[b].restY)
                if d < reach { out.append(Link(a: a, b: b, strength: 160 * (1 - d / reach))) }
            }
        }
        return out
    }

    /// Scene position of piece `i` relative to (tub center, rim line), including displacement.
    func position(_ i: Int) -> (x: Double, y: Double) {
        (pieces[i].restX + pose[i].dx, pieces[i].restY + pose[i].dy)
    }

    mutating func capturePrevious() {
        for i in pose.indices { previous[i] = pose[i] }
    }

    /// Advance one fixed step. `drive` is the target agitation (0…1); `enabled` false (Reduce
    /// Motion) pins every piece to its rest pose.
    mutating func step(dt: Double, drive: Double, enabled: Bool) {
        guard enabled else {
            if !asleep || energy != 0 { settleToRest() }
            return
        }
        let target = max(0, min(1, drive.isFinite ? drive : 0))
        let rate = target > energy ? Self.energyAttack : Self.energyRelease
        energy += (target - energy) * (1 - exp(-rate * dt))
        if energy < 1e-4 && target == 0 { energy = 0 }
        if asleep && energy == 0 { return }
        asleep = false

        let n = pieces.count
        let noiseOn = energy > 0
        for i in 0..<n {
            let p = pieces[i]
            if noiseOn {
                // Ornstein-Uhlenbeck targets with unit variance; uniform increments scaled by √3.
                let decay = dt / p.noiseTau
                let kick = sqrt(2 * decay) * 1.7320508
                noise[i].dx += -noise[i].dx * decay + kick * rng.next(in: -1...1)
                noise[i].dy += -noise[i].dy * decay + kick * rng.next(in: -1...1)
                noise[i].rot += -noise[i].rot * decay + kick * rng.next(in: -1...1)
            } else {
                noise[i] = .rest
            }
            let tx = noise[i].dx * p.maxX * 0.45 * energy
            let ty = noise[i].dy * (noise[i].dy < 0 ? p.maxUp : p.maxDown) * 0.45 * energy
            let tr = noise[i].rot * p.maxRot * 0.45 * energy
            accel[i].dx = p.stiffness * (tx - pose[i].dx) - p.damping * velocity[i].dx
            accel[i].dy = p.stiffness * (ty - pose[i].dy) - p.damping * velocity[i].dy
            accel[i].rot = p.rotStiffness * (tr - pose[i].rot) - p.rotDamping * velocity[i].rot
            // Soft travel limits: the pile packs tighter past 70% of a piece's range, so pieces
            // decelerate into their limits instead of hitting the hard stop below.
            accel[i].dx -= Self.limitForce(pose[i].dx, p.maxX, p.maxX, p.stiffness)
            accel[i].dy -= Self.limitForce(pose[i].dy, p.maxUp, p.maxDown, p.stiffness)
            accel[i].rot -= Self.limitForce(pose[i].rot, p.maxRot, p.maxRot, p.rotStiffness)
        }
        for link in links {
            let ddx = pose[link.b].dx - pose[link.a].dx
            let ddy = pose[link.b].dy - pose[link.a].dy
            accel[link.a].dx += link.strength * ddx
            accel[link.a].dy += link.strength * ddy
            accel[link.b].dx -= link.strength * ddx
            accel[link.b].dy -= link.strength * ddy
        }

        var quiet = energy < Self.sleepEpsilon
        for i in 0..<n {
            let p = pieces[i]
            var v = velocity[i]
            var o = pose[i]
            v.dx = clamp(v.dx + accel[i].dx * dt, Self.maxSpeed)
            v.dy = clamp(v.dy + accel[i].dy * dt, Self.maxSpeed)
            v.rot = clamp(v.rot + accel[i].rot * dt, Self.maxSpin)
            o.dx += v.dx * dt
            o.dy += v.dy * dt
            o.rot += v.rot * dt
            // Travel limits act like the neighbors and paper holding the piece: inelastic stops.
            if abs(o.dx) > p.maxX { o.dx = p.maxX * sign(o.dx); v.dx = 0 }
            if o.dy < -p.maxUp { o.dy = -p.maxUp; v.dy = max(0, v.dy) }
            if o.dy > p.maxDown { o.dy = p.maxDown; v.dy = min(0, v.dy) }
            if abs(o.rot) > p.maxRot { o.rot = p.maxRot * sign(o.rot); v.rot = 0 }
            velocity[i] = v
            pose[i] = o
            if quiet, abs(o.dx) + abs(o.dy) > 0.01 || abs(o.rot) > 0.001
                || abs(v.dx) + abs(v.dy) > 0.05 || abs(v.rot) > 0.01 {
                quiet = false
            }
        }
        if quiet { settleToRest() } else { updateSurfaceTable() }
    }

    private mutating func settleToRest() {
        for i in pose.indices {
            pose[i] = .rest
            velocity[i] = .rest
            noise[i] = .rest
        }
        for j in surfaceTable.indices { surfaceTable[j] = 0 }
        energy = 0
        asleep = true
    }

    /// Velocity impulse centered at (`x`, `y`) relative to (tub center, rim line). `dvx`/`dvy` is
    /// the push at the center, `radial` pushes pieces away from the center, and `spin` rocks them
    /// in the direction of their side. Everything falls off as a Gaussian of distance.
    mutating func disturb(x: Double, y: Double, dvx: Double, dvy: Double, radial: Double, spin: Double) {
        guard dvx.isFinite, dvy.isFinite, radial.isFinite, spin.isFinite else { return }
        let inv2s2 = 1 / (2 * Self.impulseRadius * Self.impulseRadius)
        var touched = false
        for i in pieces.indices {
            let (px, py) = position(i)
            let rx = px - x, ry = py - y
            let d2 = rx * rx + ry * ry
            let w = exp(-d2 * inv2s2)
            guard w > 0.02 else { continue }
            let m = pieces[i].mobility * w
            let d = max(1, sqrt(d2))
            velocity[i].dx = clamp(velocity[i].dx + m * (dvx + radial * rx / d), Self.maxSpeed)
            velocity[i].dy = clamp(velocity[i].dy + m * (dvy + radial * ry / d), Self.maxSpeed)
            velocity[i].rot = clamp(velocity[i].rot + m * spin * (rx >= 0 ? 1 : -1), Self.maxSpin)
            touched = true
        }
        if touched { asleep = false }
    }

    /// Speech-onset hop: exposed pieces jump by different amounts in slightly different directions.
    mutating func hop(strength: Double) {
        let s = max(0, min(1, strength.isFinite ? strength : 0))
        guard s > 0 else { return }
        for i in pieces.indices {
            let e = pieces[i].exposure
            let lift = Self.hopSpeed * s * e * e * rng.next(in: 0.45...1.0)
            velocity[i].dy = clamp(velocity[i].dy - lift, Self.maxSpeed)
            velocity[i].dx = clamp(velocity[i].dx + lift * 0.35 * rng.next(in: -1...1), Self.maxSpeed)
            velocity[i].rot = clamp(velocity[i].rot + s * e * 2.2 * rng.next(in: -1...1), Self.maxSpin)
        }
        asleep = false
    }

    /// Vertical displacement of the pile surface near scene offset `x` (negative = raised), from
    /// the pieces that form the top layer there. Collisions and resting kernels follow it.
    func surfaceOffset(atX x: Double) -> Double {
        if asleep { return 0 }
        let u = (x - Self.surfaceStartX) / Self.surfaceSpacing
        let lo = max(0, min(surfaceTable.count - 2, Int(u.rounded(.down))))
        let t = max(0, min(1, u - Double(lo)))
        return surfaceTable[lo] + (surfaceTable[lo + 1] - surfaceTable[lo]) * t
    }

    /// The surface is sampled every `surfaceSpacing` pt once per step, so the many collision and
    /// resting-kernel queries per step are table lookups instead of sums over every piece.
    static let surfaceStartX = -72.0
    static let surfaceSpacing = 8.0
    static let surfaceSamples = 19

    private static func makeSurfaceWeights(_ pieces: [Piece]) -> [[Double]] {
        (0..<surfaceSamples).map { j in
            let x = surfaceStartX + Double(j) * surfaceSpacing
            let raw = pieces.map { exp(-($0.restX - x) * ($0.restX - x) / 200) * (0.25 + $0.exposure) }
            let total = max(1e-9, raw.reduce(0, +))
            return raw.map { $0 / total }
        }
    }

    private mutating func updateSurfaceTable() {
        for j in surfaceTable.indices {
            var sum = 0.0
            let w = surfaceWeights[j]
            for i in pose.indices { sum += pose[i].dy * w[i] }
            surfaceTable[j] = sum
        }
    }

    func interpolated(_ t: Double, into out: inout [HeapPose]) {
        out.removeAll(keepingCapacity: true)
        for i in pose.indices {
            let a = previous[i], b = pose[i]
            out.append(HeapPose(dx: a.dx + (b.dx - a.dx) * t, dy: a.dy + (b.dy - a.dy) * t, rot: a.rot + (b.rot - a.rot) * t))
        }
    }

    private static func limitForce(_ o: Double, _ negLimit: Double, _ posLimit: Double, _ k: Double) -> Double {
        let soft = 0.7
        if o > posLimit * soft { return 6 * k * (o - posLimit * soft) }
        if o < -negLimit * soft { return 6 * k * (o + negLimit * soft) }
        return 0
    }

    private func clamp(_ v: Double, _ limit: Double) -> Double { max(-limit, min(limit, v)) }
    private func sign(_ v: Double) -> Double { v < 0 ? -1 : 1 }
}
