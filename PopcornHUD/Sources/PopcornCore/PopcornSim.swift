import Foundation

public struct KernelBody: Equatable, Sendable {
    public var id: UInt64 = 0
    public var front: Bool = false
    public var x: Double
    public var y: Double
    public var vx: Double
    public var vy: Double
    public var rot: Double
    public var rotV: Double
    public var scale: Double
    public var shape: Int
    public var butter: Double // 0...1
    public var life: Double
    public var maxLife: Double
    public var settled: Bool
    public var hitRadius: Double
    /// How far a resting kernel sits into the pile surface (pt); set when it lands.
    public var nestle: Double = 0

    public var alpha: Double {
        max(0, min(1, (maxLife - life) / Tunables.cleanupFade))
    }
}

public struct SimSnapshot: Equatable, Sendable {
    public var kernels: [KernelBody]
    public var heat: Double
    /// Slow-following heat envelope (see `Tunables.moodAttackRate`).
    public var mood: Double
    public var kick: Double
    public var phase: Double
    public var bagVisible: Double // 1 = full bag, 0 = collapsed
    /// Displacement of each `HeapSeed.pieces` entry, interpolated like the kernels. Empty means
    /// every piece is at rest.
    public var heap: [HeapPose]

    public init(
        kernels: [KernelBody], heat: Double, mood: Double, kick: Double, phase: Double,
        bagVisible: Double, heap: [HeapPose] = []
    ) {
        self.heap = heap
        self.kernels = kernels
        self.heat = heat
        self.mood = mood
        self.kick = kick
        self.phase = phase
        self.bagVisible = bagVisible
    }
}

/// Per-phase cost accumulated by `PopcornSim.step` while `collectTimings` is on (benchmarks only).
public struct SimPhaseTimings: Equatable, Sendable {
    public var steps = 0
    public var emitNs: UInt64 = 0
    public var integrateNs: UInt64 = 0
    public var collideNs: UInt64 = 0
    public var heapNs: UInt64 = 0
    public init() {}
}

@inline(__always) private func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

private struct KernelPose {
    var x: Double
    var y: Double
    var rot: Double
}

public final class PopcornSim {
    public private(set) var kernels: [KernelBody] = []
    public private(set) var heat: Double = 0
    public private(set) var mood: Double = 0
    public private(set) var kick: Double = 0
    public private(set) var kickV: Double = 0
    public private(set) var phase: Double = 0
    public private(set) var bagVisible: Double = 1
    public var levelsUnavailable: Bool = false { didSet { if levelsUnavailable { clearEmission() } } }
    public var allowSpawn: Bool = true { didSet { if !allowSpawn { clearEmission() } } }
    public var reduceMotion: Bool = false {
        didSet {
            if reduceMotion != oldValue {
                clearEmission()
                kernels.removeAll { !$0.settled }
                kick = 0
                kickV = 0
                prevPoses.removeAll(keepingCapacity: true)
                prevKick = 0
            }
        }
    }

    private var spawnAccum: Double = 0
    private var burstRefractory: Double = 0
    private var onsetBaseline: Double = 0
    private var burstRemaining = 0
    private var burstDelay: Double = 0
    private var nextID: UInt64 = 0
    public private(set) var emittedCount = 0
    /// Benchmark instrumentation. Off in the HUD; costs one branch per phase when off.
    public var collectTimings = false
    public var timings = SimPhaseTimings()

    private func clearEmission() {
        spawnAccum = 0
        burstRemaining = 0
        burstDelay = 0
        burstRefractory = 0
        onsetBaseline = heat
    }
    private var accum: Double = 0
    private var rng: SeededRNG
    private var prevMono: UInt64?
    private var prevPoses: [UInt64: KernelPose] = [:]
    private var prevKick: Double = 0
    private var drawScratch: [KernelBody] = []
    private var heapScratch: [HeapPose] = []
    var heapMotion: HeapMotion
    /// Landing-only randomness. Kept apart from `rng` so that when the moving pile changes when
    /// a kernel lands, the launch sequence of every later pop is unaffected.
    private var landingRng: SeededRNG
    private var hopRefractory: Double = 0
    private var landingsThisStep = 0
    private static let sides: [Double] = [-1, 1]

    public init(seed: UInt64? = nil) {
        if let seed {
            rng = SeededRNG(seed: seed)
        } else {
            rng = SeededRNG.fromEnvironment()
        }
        var probe = rng
        heapMotion = HeapMotion(seed: probe.nextUInt64())
        landingRng = SeededRNG(seed: probe.nextUInt64() ^ 0x6C61_6E64_696E_6721)
    }

    /// Current heap displacement (not interpolated).
    public var heapPoses: [HeapPose] { heapMotion.pose }

    public func reset(seed: UInt64? = nil) {
        if let seed { rng = SeededRNG(seed: seed) }
        var probe = rng
        heapMotion.reset(seed: probe.nextUInt64())
        landingRng = SeededRNG(seed: probe.nextUInt64() ^ 0x6C61_6E64_696E_6721)
        hopRefractory = 0
        heapScratch.removeAll(keepingCapacity: true)
        kernels.removeAll(keepingCapacity: true)
        heat = 0
        mood = 0
        kick = 0
        kickV = 0
        phase = 0
        bagVisible = 1
        spawnAccum = 0
        burstRefractory = 0
        onsetBaseline = 0
        burstRemaining = 0
        burstDelay = 0
        nextID = 0
        emittedCount = 0
        accum = 0
        prevMono = nil
        prevPoses.removeAll(keepingCapacity: true)
        prevKick = 0
        drawScratch.removeAll(keepingCapacity: true)
        levelsUnavailable = false
    }

    /// Advance using monotonic ms; returns interpolated snapshot for drawing.
    /// - Parameter peakFresh: true only when a new audio packet arrived (not a held display sample).
    public func advance(toMonoMs mono: UInt64, peak: Float, peakFresh: Bool = true) -> SimSnapshot {
        if let prev = prevMono {
            var dt = Double(mono &- prev) / 1000.0
            if dt < 0 || dt > 0.25 {
                // Sleep / clock jump - reset accumulator, no catch-up burst
                accum = 0
                dt = Tunables.simDt
            }
            accum += dt
        }
        prevMono = mono

        var steps = 0
        var freshForStep = peakFresh
        while accum >= Tunables.simDt, steps < Tunables.maxCatchUpSteps {
            step(dt: Tunables.simDt, peak: peak, peakFresh: freshForStep)
            // Catch-up steps reuse the same sample; only the first sees a fresh packet.
            freshForStep = false
            accum -= Tunables.simDt
            steps += 1
        }
        if steps == Tunables.maxCatchUpSteps {
            accum = 0
        }

        let alpha = accum / Tunables.simDt
        return snapshot(interp: alpha)
    }

    public func step(dt: Double, peak: Float, peakFresh: Bool = true) {
        let tStart = collectTimings ? uptimeNs() : 0
        capturePrevPoses()

        phase += dt
        burstRefractory = max(0, burstRefractory - dt)
        hopRefractory = max(0, hopRefractory - dt)
        landingsThisStep = 0

        let raw = peak.isFinite && !levelsUnavailable && allowSpawn ? Double(max(0, min(1, peak))) : 0
        let quiet = Tunables.quietPeak
        let loud = Tunables.loudPeak
        let norm = min(1, max(0, (raw - quiet) / (loud - quiet)))
        let target = pow(norm, Tunables.heatCurve)
        let rate = target > heat ? Tunables.attackRate : Tunables.releaseRate
        heat += (target - heat) * (1 - exp(-rate * dt))
        let moodRate = heat > mood ? Tunables.moodAttackRate : Tunables.moodReleaseRate
        mood += (heat - mood) * (1 - exp(-moodRate * dt))

        // Bag recoil spring
        let accel = -Tunables.kickStiffness * kick - Tunables.kickDamping * kickV
        kickV += accel * dt
        kick += kickV * dt
        if kick > Tunables.maxKick { kick = Tunables.maxKick; kickV = min(0, kickV) }

        if allowSpawn, !reduceMotion, !levelsUnavailable {
            spawnAccum += Tunables.popsPerSecond(heat: heat) * dt
            // Accents only from fresh packet information - not held display samples.
            // Use target (from this packet) so attack lag cannot miss the onset.
            if peakFresh {
                let rise = target - onsetBaseline
                if rise > Tunables.onsetThreshold, burstRefractory <= 0, burstRemaining == 0 {
                    if hopRefractory <= 0 {
                        heapMotion.hop(strength: min(1, rise / Tunables.heapHopFullRise))
                        hopRefractory = Tunables.heapHopRefractory
                    }
                    burstRemaining = min(Tunables.burstCountMax, max(Tunables.burstCountMin,
                        Int((2 + rise * 5).rounded())))
                    burstDelay = 0
                    burstRefractory = Tunables.burstRefractory
                }
            }
            burstDelay -= dt
            if burstRemaining > 0, burstDelay <= 0 {
                if emit(burst: true) {
                    burstRemaining -= 1
                    burstDelay += Tunables.burstSpacing
                } else { clearEmission() }
            }
            while spawnAccum >= 1 {
                spawnAccum -= 1
                if !emit(burst: false) { clearEmission(); break }
            }
        } else { clearEmission() }
        onsetBaseline += (heat - onsetBaseline) * (1 - exp(-Tunables.onsetBaselineRate * dt))

        let tEmit = collectTimings ? uptimeNs() : 0
        integrate(dt: dt)
        let tIntegrate = collectTimings ? uptimeNs() : 0
        if !reduceMotion { collide(dt: dt) }
        let tCollide = collectTimings ? uptimeNs() : 0
        let agitated = allowSpawn && !levelsUnavailable
        heapMotion.step(dt: dt, drive: agitated ? heat : 0, enabled: !reduceMotion)
        if collectTimings {
            let tHeap = uptimeNs()
            timings.steps += 1
            timings.emitNs += tEmit - tStart
            timings.integrateNs += tIntegrate - tEmit
            timings.collideNs += tCollide - tIntegrate
            timings.heapNs += tHeap - tCollide
        }
    }

    private func capturePrevPoses() {
        prevPoses.removeAll(keepingCapacity: true)
        for k in kernels {
            prevPoses[k.id] = KernelPose(x: k.x, y: k.y, rot: k.rot)
        }
        prevKick = kick
        heapMotion.capturePrevious()
    }

    private func emit(burst: Bool) -> Bool {
        guard makeRoomForSpawn() else { return false }
        spawnKernel(burst: burst)
        emittedCount += 1
        let impulse = Tunables.kickPerPop
            + Tunables.kickHeatScale * heat * heat
            + (burst ? Tunables.kickPerBurst * heat : 0)
        kickV = min(Tunables.maxKickVelocity, kickV + impulse)
        return true
    }

    /// Free a slot by dropping oldest settled kernels. Returns false if still at capacity.
    @discardableResult
    private func makeRoomForSpawn() -> Bool {
        trimSettled(to: Tunables.maxSettledKernels)
        while kernels.count >= Tunables.maxKernels {
            guard let idx = kernels.firstIndex(where: { $0.settled }) else { return false }
            kernels.remove(at: idx)
        }
        return kernels.count < Tunables.maxKernels
    }

    private func trimSettled(to maxSettled: Int) {
        var settledCount = kernels.reduce(0) { $0 + ($1.settled ? 1 : 0) }
        while settledCount > maxSettled {
            guard let idx = kernels.firstIndex(where: { $0.settled }) else { break }
            kernels.remove(at: idx)
            settledCount -= 1
        }
    }

    /// Benchmarks only: top the population up to `count` (≤ `maxKernels`) with airborne kernels
    /// launched like ordinary pops, without recoil or emission bookkeeping. Consumes the RNG, so a
    /// sim that calls this no longer matches an unfilled sim with the same seed.
    public func benchmarkFill(to count: Int) {
        while kernels.count < min(count, Tunables.maxKernels) {
            spawnKernel(burst: false)
        }
    }

    private func spawnKernel(burst: Bool) {
        let cx = Double(Tunables.cardW) / 2
        let bagTop = Double(Tunables.cardH - Tunables.bagBottomPad - Tunables.bagH)
        let mouthY = bagTop + 6
        // Onset accents: same kernel count, more energy per kernel.
        let launchAccent = burst ? Tunables.burstLaunchAccent : 1.0
        let spreadAccent = burst ? Tunables.burstSpreadAccent : 1.0
        let spinAccent = burst ? Tunables.burstSpinAccent : 1.0
        let launch = (Tunables.minLaunch + Tunables.launchRange * heat)
            * rng.next(in: Tunables.launchJitterMin...Tunables.launchJitterMax)
            * launchAccent
        // Restrained sideways spread so launches stay in-panel.
        let spread = rng.next(in: -1...1) * Tunables.spreadPxPerSec
            * (Tunables.spreadHeatBase + heat * Tunables.spreadHeatScale)
            * spreadAccent
        let scale = rng.next(in: Tunables.kernelScaleMin...Tunables.kernelScaleMax)
        let r0 = Tunables.kernelRadius * scale
        var body = KernelBody(
            id: nextID, front: rng.next(in: 0...1) < 0.28,
            x: cx + rng.next(in: -14...14),
            y: bagTop - 32 - rng.next(in: 0...8),
            vx: spread,
            vy: -launch,
            rot: rng.next(in: 0...(2 * .pi)),
            rotV: rng.next(in: -Tunables.spinRange...Tunables.spinRange)
                * (Tunables.spinHeatBase + heat * Tunables.spinHeatScale)
                * spinAccent,
            scale: scale,
            shape: rng.nextInt(in: 0...(KernelArt.templateCount - 1)),
            butter: rng.next(in: 0.06...0.32),
            life: 0,
            maxLife: rng.next(in: 2.4...3.2),
            settled: false,
            hitRadius: r0 * 0.88
        )
        body.y = min(body.y, mouthY - 2)
        let maxLaunch = sqrt(2 * Tunables.gravity * max(1, body.y - r0 - 18))
        body.vy = -min(launch, maxLaunch)
        kernels.append(body)
        if !reduceMotion {
            // The pop shoves the crown it bursts out of: pieces around the mouth recoil outward
            // and rock. Scaled by launch energy; accents push harder without adding kernels.
            let energy = min(1.2, -body.vy / (Tunables.minLaunch + Tunables.launchRange))
            let accent = burst ? Tunables.heapBurstAccent : 1
            disturbPile(
                x: body.x - cx, y: Tunables.heapLaunchDepth,
                dvx: body.vx * 0.04, dvy: Tunables.heapLaunchPush * energy * accent,
                radial: Tunables.heapLaunchRadial * energy * accent,
                spin: Tunables.heapLaunchSpin * energy * accent
            )
        }
        nextID &+= 1
    }

    /// Apply a pile disturbance (rim-relative coordinates, see `HeapMotion.disturb`) to the
    /// decorative pieces and to kernels resting on the pile.
    func disturbPile(x: Double, y: Double, dvx: Double, dvy: Double, radial: Double, spin: Double) {
        guard !reduceMotion else { return }
        heapMotion.disturb(x: x, y: y, dvx: dvx, dvy: dvy, radial: radial, spin: spin)
        let cx = Double(Tunables.cardW) / 2
        let bagTop = Double(Tunables.cardH - Tunables.bagBottomPad - Tunables.bagH)
        let inv2s2 = 1 / (2 * HeapMotion.impulseRadius * HeapMotion.impulseRadius)
        for i in kernels.indices where kernels[i].settled {
            let rx = kernels[i].x - cx - x
            let ry = kernels[i].y - bagTop - y
            let d2 = rx * rx + ry * ry
            let w = exp(-d2 * inv2s2) * 0.8
            guard w > 0.02 else { continue }
            let d = max(1, sqrt(d2))
            kernels[i].vx = max(-40, min(40, kernels[i].vx + w * (dvx + radial * rx / d)))
            kernels[i].vy = max(-60, min(60, kernels[i].vy + w * (dvy + radial * ry / d)))
            kernels[i].rotV = max(-4, min(4, kernels[i].rotV + w * spin * (rx >= 0 ? 1 : -1)))
        }
    }

    /// Tests only: a long-lived kernel already resting on the pile at `atOffsetX` from center.
    func insertRestingKernelForTesting(atOffsetX offset: Double) {
        let x = Double(Tunables.cardW) / 2 + offset
        var body = KernelBody(
            id: nextID, x: x, y: 0, vx: 0, vy: 0, rot: 0, rotV: 0, scale: 1, shape: 0, butter: 0.2,
            life: 0, maxLife: 1_000, settled: true, hitRadius: Tunables.kernelRadius * 0.88
        )
        body.y = restingY(body)
        kernels.append(body)
        nextID &+= 1
    }

    /// Resting height for a kernel on the (displaced) pile surface.
    private func restingY(_ k: KernelBody) -> Double {
        let cx = Double(Tunables.cardW) / 2
        return Tunables.heapSurface(x: k.x) + heapMotion.surfaceOffset(atX: k.x - cx) - k.hitRadius + k.nestle
    }

    private var offsideFadeY: Double {
        Double(Tunables.cardH - Tunables.bagBottomPad - Tunables.bagH) + Tunables.offsideFadeBelowLip
    }

    private func integrate(dt: Double) {
        let cx = Double(Tunables.cardW) / 2
        let restLimitX = Double(Tunables.mouthHalf) - 6
        var i = 0
        while i < kernels.count {
            var k = kernels[i]
            k.life += dt
            if k.life >= k.maxLife {
                kernels.remove(at: i)
                continue
            }
            if !k.settled {
                k.vy += Tunables.gravity * dt
                k.x += k.vx * dt
                k.y += k.vy * dt
                k.rot += k.rotV * dt
                k.rotV *= exp(-0.55 * dt)
                // Soft horizontal drag keeps clutter in-panel without pausing at apex.
                k.vx *= exp(-0.35 * dt)
                if k.y > Double(Tunables.cardH) + 30 || k.x < -24 || k.x > Double(Tunables.cardW) + 24 {
                    kernels.remove(at: i)
                    continue
                }
                // Falling past the lip outside the mouth: fade out now rather than tumbling down
                // beside the tub and across the status capsule.
                if k.vy > 0, k.y > offsideFadeY, abs(k.x - cx) > Double(Tunables.mouthHalf) {
                    k.maxLife = min(k.maxLife, k.life + Tunables.cleanupFade)
                }
            } else if !reduceMotion {
                // Resting on the pile: slide and spin down to a stop, ride the surface as the
                // pile shifts, and stay free to be knocked by later landings and launches.
                let target = restingY(k)
                let slope = (Tunables.heapSurface(x: k.x + 1) - Tunables.heapSurface(x: k.x - 1)) / 2
                // Sliding friction: only a kernel already moving slips downhill; a stopped one sticks.
                if abs(k.vx) > 1.5 { k.vx += slope * Tunables.restingSlopePull * dt }
                k.vy += (Tunables.restingStiffness * (target - k.y) - Tunables.restingDamping * k.vy) * dt
                k.vx *= exp(-Tunables.restingSlideDrag * dt)
                k.rotV *= exp(-Tunables.restingSpinDrag * dt)
                k.x += k.vx * dt
                k.y += k.vy * dt
                k.rot += k.rotV * dt
                if abs(k.x - cx) > restLimitX { k.x = cx + restLimitX * (k.x < cx ? -1 : 1); k.vx = 0 }
                if k.y > target + 2 { k.y = target + 2; k.vy = min(0, k.vy) }
                if k.y < target - 6 { k.y = target - 6; k.vy = max(0, k.vy) }
            }
            kernels[i] = k
            i += 1
        }
        trimSettled(to: Tunables.maxSettledKernels)
    }

    private func collide(dt: Double) {
        let bagTop = Double(Tunables.cardH - Tunables.bagBottomPad - Tunables.bagH)
        let cx = Double(Tunables.cardW) / 2
        let mouth = Double(Tunables.mouthHalf)
        let retain = Tunables.bounceRetainMin
            + (Tunables.bounceRetainMax - Tunables.bounceRetainMin) * 0.5

        for i in kernels.indices where !kernels[i].settled {
            var k = kernels[i]
            let heapY = Tunables.heapSurface(x: k.x) + heapMotion.surfaceOffset(atX: k.x - cx)
            let hitR = k.hitRadius
            if k.y + hitR > heapY, abs(k.x - cx) < mouth + 4, k.vy > 0 {
                let overlap = k.y + hitR - heapY
                k.y -= overlap
                if landingsThisStep < Tunables.heapMaxLandingsPerStep {
                    landingsThisStep += 1
                    let mass = k.scale * k.scale
                    let g = Tunables.heapLandingGain * mass
                    disturbPile(
                        x: k.x - cx, y: heapY - bagTop,
                        dvx: max(-30, min(30, k.vx * g)), dvy: min(30, k.vy * g * 0.9),
                        radial: min(20, k.vy * g * 0.4), spin: max(-2, min(2, k.vx * 0.01))
                    )
                }
                if k.vy < 95 {
                    k.settled = true
                    k.vy = 0
                    // Keep a little of the impact so it slides and rolls to rest instead of freezing.
                    k.vx = max(-40, min(40, k.vx * 0.35))
                    k.rotV *= 0.3
                    k.nestle = Double((k.id &* 2_654_435_761) % 1000) / 1000 * Tunables.restingNestleMax
                    k.maxLife = k.life + landingRng.next(in: 0.7...1.4)
                } else {
                    k.vy *= -retain
                    k.vx *= 0.62
                }
                k.rotV += -k.vx * 0.02
            }
            for side in Self.sides where !k.settled {
                let wallX = cx + side * mouth
                let dx = k.x - wallX
                if abs(dx) < hitR + 3, k.y > bagTop - 30, k.y < bagTop + 40 {
                    let push = (hitR + 3 - abs(dx)) * (dx < 0 ? -1 : 1)
                    k.x += push
                    k.vx *= -retain
                    k.rotV += side * abs(k.vy) * 0.01
                }
            }
            kernels[i] = k
        }

        let n = kernels.count
        guard n > 1 else { return }
        // Pairwise pass over raw storage: the O(n²) loop is the hottest code in the simulation,
        // and element-wise array access (bounds and exclusivity checks, whole-struct copies)
        // dominated it in unoptimized builds.
        kernels.withUnsafeMutableBufferPointer { buffer in
            guard let k = buffer.baseAddress else { return }
            for a in 0..<n where !k[a].settled {
                for b in (a + 1)..<n where !k[b].settled {
                    // Cheap rejects first: different layer, or separated on one axis by more than
                    // the contact distance (exact, so results match the full distance test).
                    if k[a].front != k[b].front { continue }
                    let dx = k[b].x - k[a].x
                    let dy = k[b].y - k[a].y
                    let minDist = k[a].hitRadius + k[b].hitRadius
                    if abs(dx) >= minDist || abs(dy) >= minDist { continue }
                    let dist = sqrt(dx * dx + dy * dy)
                    guard dist > 0.001, dist < minDist else { continue }
                    let nx = dx / dist
                    let ny = dy / dist
                    let overlap = minDist - dist
                    k[a].x -= nx * overlap * 0.5
                    k[a].y -= ny * overlap * 0.5
                    k[b].x += nx * overlap * 0.5
                    k[b].y += ny * overlap * 0.5
                    let rvx = k[a].vx - k[b].vx
                    let rvy = k[a].vy - k[b].vy
                    let vn = rvx * nx + rvy * ny
                    if vn > 0 {
                        let j = vn * (1 + retain) * 0.5
                        k[a].vx -= j * nx
                        k[a].vy -= j * ny
                        k[b].vx += j * nx
                        k[b].vy += j * ny
                        k[a].rotV += -ny * j * 0.05
                        k[b].rotV += ny * j * 0.05
                        k[a].vx *= Tunables.friction
                        k[b].vx *= Tunables.friction
                    }
                }
            }
        }
        trimSettled(to: Tunables.maxSettledKernels)
        _ = dt
    }

    private func snapshot(interp: Double) -> SimSnapshot {
        let t = max(0, min(1, interp))
        if reduceMotion || heapMotion.asleep {
            heapScratch.removeAll(keepingCapacity: true)
        } else {
            heapMotion.interpolated(t, into: &heapScratch)
        }
        drawScratch.removeAll(keepingCapacity: true)
        if drawScratch.capacity < kernels.count {
            drawScratch.reserveCapacity(Tunables.maxKernels)
        }
        drawScratch.append(contentsOf: kernels)
        for i in drawScratch.indices {
            let id = drawScratch[i].id
            guard let prev = prevPoses[id] else { continue } // newly spawned: current only
            drawScratch[i].x = prev.x + (drawScratch[i].x - prev.x) * t
            drawScratch[i].y = prev.y + (drawScratch[i].y - prev.y) * t
            drawScratch[i].rot = lerpAngle(prev.rot, drawScratch[i].rot, t)
        }
        let kickOut: Double
        if reduceMotion {
            kickOut = 0
        } else {
            kickOut = prevKick + (kick - prevKick) * t
        }
        return SimSnapshot(
            kernels: drawScratch,
            heat: heat,
            mood: mood,
            kick: kickOut,
            phase: phase,
            bagVisible: bagVisible,
            heap: heapScratch
        )
    }

    private func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var d = b - a
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return a + d * t
    }

    public func setBagVisible(_ v: Double) {
        bagVisible = max(0, min(1, v))
    }
}
