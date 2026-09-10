import Foundation

public struct Vec2: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

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
    public var levelsUnavailable: Bool
}

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
    private static let sides: [Double] = [-1, 1]

    public init(seed: UInt64? = nil) {
        if let seed {
            rng = SeededRNG(seed: seed)
        } else {
            rng = SeededRNG.fromEnvironment()
        }
    }

    public func reset(seed: UInt64? = nil) {
        if let seed { rng = SeededRNG(seed: seed) }
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
        capturePrevPoses()

        phase += dt
        burstRefractory = max(0, burstRefractory - dt)

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

        integrate(dt: dt)
        if !reduceMotion { collide(dt: dt) }
    }

    private func capturePrevPoses() {
        prevPoses.removeAll(keepingCapacity: true)
        for k in kernels {
            prevPoses[k.id] = KernelPose(x: k.x, y: k.y, rot: k.rot)
        }
        prevKick = kick
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
        let scale = rng.next(in: 0.72...1.08)
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
        nextID &+= 1
    }

    private func integrate(dt: Double) {
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
            let heapY = Tunables.heapSurface(x: k.x)
            let hitR = k.hitRadius
            if k.y + hitR > heapY, abs(k.x - cx) < mouth + 4, k.vy > 0 {
                let overlap = k.y + hitR - heapY
                k.y -= overlap
                if k.vy < 95 {
                    k.settled = true
                    k.vy = 0
                    k.vx = 0
                    k.rotV = 0
                    k.maxLife = k.life + rng.next(in: 0.7...1.4)
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
        for a in 0..<n where !kernels[a].settled {
            for b in (a + 1)..<n where !kernels[b].settled {
                var ka = kernels[a]
                var kb = kernels[b]
                if ka.front != kb.front { continue }
                let dx = kb.x - ka.x
                let dy = kb.y - ka.y
                let dist = sqrt(dx * dx + dy * dy)
                let minDist = ka.hitRadius + kb.hitRadius
                if dist > 0.001, dist < minDist {
                    let nx = dx / dist
                    let ny = dy / dist
                    let overlap = minDist - dist
                    ka.x -= nx * overlap * 0.5
                    ka.y -= ny * overlap * 0.5
                    kb.x += nx * overlap * 0.5
                    kb.y += ny * overlap * 0.5
                    let rvx = ka.vx - kb.vx
                    let rvy = ka.vy - kb.vy
                    let vn = rvx * nx + rvy * ny
                    if vn > 0 {
                        let j = vn * (1 + retain) * 0.5
                        ka.vx -= j * nx
                        ka.vy -= j * ny
                        kb.vx += j * nx
                        kb.vy += j * ny
                        ka.rotV += -ny * j * 0.05
                        kb.rotV += ny * j * 0.05
                        ka.vx *= Tunables.friction
                        kb.vx *= Tunables.friction
                    }
                    kernels[a] = ka
                    kernels[b] = kb
                }
            }
        }
        trimSettled(to: Tunables.maxSettledKernels)
        _ = dt
    }

    private func snapshot(interp: Double) -> SimSnapshot {
        let t = max(0, min(1, interp))
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
            levelsUnavailable: levelsUnavailable
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
