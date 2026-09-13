import XCTest
@testable import PopcornCore

/// Whole-pile motion: the decorative heap springs and kernels resting on it.
final class HeapMotionTests: XCTestCase {
    /// Drive a sim at a 120 Hz display rate with `SyntheticSpeech`, calling `each` per frame.
    private func runSpeech(
        _ sim: PopcornSim, seconds: Double, intensity: SyntheticIntensity = .energetic, seed: UInt64 = 7,
        startMs: UInt64 = 0, each: (SimSnapshot, UInt64) -> Void = { _, _ in }
    ) -> UInt64 {
        var speech = SyntheticSpeech(intensity: intensity, seed: seed)
        var mono = startMs
        for _ in 0..<Int(seconds * 120) {
            mono += 8
            let (peak, fresh) = speech.sample(atMonoMs: mono)
            each(sim.advance(toMonoMs: mono, peak: peak, peakFresh: fresh), mono)
        }
        return mono
    }

    private func poses(_ snap: SimSnapshot) -> [HeapPose] {
        snap.heap.isEmpty ? Array(repeating: .rest, count: HeapSeed.pieces.count) : snap.heap
    }

    func testSameSeedAndInputReproduceHeapExactly() {
        func trace(seed: UInt64) -> [[HeapPose]] {
            let sim = PopcornSim(seed: seed)
            var out: [[HeapPose]] = []
            _ = runSpeech(sim, seconds: 3) { snap, _ in out.append(snap.heap) }
            return out
        }
        let a = trace(seed: 2026), b = trace(seed: 2026), c = trace(seed: 2027)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.contains { !$0.isEmpty }, "speech should wake the pile")
    }

    func testEveryPieceMovesDistinctlyDuringSustainedSpeech() {
        let sim = PopcornSim(seed: 11)
        let n = HeapSeed.pieces.count
        var series = [[Double]](repeating: [], count: n)
        var travel = [Double](repeating: 0, count: n)
        var last = [HeapPose](repeating: .rest, count: n)
        _ = runSpeech(sim, seconds: 1)                        // let the pile wake up
        _ = runSpeech(sim, seconds: 4, startMs: 1000) { snap, _ in
            let p = self.poses(snap)
            for i in 0..<n {
                series[i].append(p[i].dy + p[i].dx + p[i].rot * 10)
                travel[i] += abs(p[i].dx - last[i].dx) + abs(p[i].dy - last[i].dy) + abs(p[i].rot - last[i].rot) * 10
            }
            last = p
        }
        for i in 0..<n {
            let range = (series[i].max() ?? 0) - (series[i].min() ?? 0)
            XCTAssertGreaterThan(range, 0.25, "piece \(i) barely moved")
        }
        // Buried pieces are held more than the crown.
        let exposure = sim.heapMotion.pieces.map(\.exposure)
        let crown = exposure.indices.max { exposure[$0] < exposure[$1] }!
        let buried = exposure.indices.min { exposure[$0] < exposure[$1] }!
        XCTAssertGreaterThan(travel[crown], travel[buried] * 1.5)
        // Visible at native 1×: the crown shifts by points, not fractions of one; buried pieces
        // stay nearly rigid.
        func span(_ i: Int) -> Double { (series[i].max() ?? 0) - (series[i].min() ?? 0) }
        XCTAssertGreaterThan(span(crown), 3)
        XCTAssertLessThan(span(buried), 1.5)

        // Not one rigid group: pairwise correlation of piece motion stays low on average.
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
            var num = 0.0, da = 0.0, db = 0.0
            for k in a.indices {
                num += (a[k] - ma) * (b[k] - mb)
                da += (a[k] - ma) * (a[k] - ma)
                db += (b[k] - mb) * (b[k] - mb)
            }
            return num / max(1e-12, sqrt(da * db))
        }
        var total = 0.0, pairs = 0.0, maxCorr = 0.0
        for i in 0..<n {
            for j in (i + 1)..<n {
                let c = abs(corr(series[i], series[j]))
                total += c
                pairs += 1
                maxCorr = max(maxCorr, c)
            }
        }
        XCTAssertLessThan(total / pairs, 0.4)
        XCTAssertLessThan(maxCorr, 0.95)
    }

    func testAccentHopsLiftTheCrownAboveSustainedMotion() {
        func crownLift(syllables: Bool) -> Double {
            let sim = PopcornSim(seed: 2026)
            let pieces = sim.heapMotion.pieces
            let crown = pieces.indices.filter { pieces[$0].exposure > 0.75 }
            var speech = SyntheticSpeech(intensity: .energetic, seed: 7)
            var mono: UInt64 = 0, lift = 0.0
            for frame in 0..<(8 * 120) {
                mono += 8
                // Held loud level: one onset at the start, then no accents.
                var (peak, fresh) = speech.sample(atMonoMs: mono)
                if !syllables { peak = 0.3; fresh = true }
                sim.step(dt: Tunables.simDt, peak: peak, peakFresh: fresh)
                guard frame > 120 else { continue }
                for i in crown { lift = max(lift, -sim.heapMotion.pose[i].dy) }
            }
            return lift
        }
        let accented = crownLift(syllables: true), held = crownLift(syllables: false)
        XCTAssertGreaterThan(accented, 5, "speech accents should make the crown hop visibly")
        XCTAssertGreaterThan(accented, held * 1.5, "hops come from accents, not from loudness alone")
    }

    func testNudgedPieceDragsItsNeighbors() {
        var heap = HeapMotion(seed: 1)
        let pieces = heap.pieces
        let nudged = pieces.indices.max { pieces[$0].exposure < pieces[$1].exposure }!
        let neighbors = Set(heap.links.filter { $0.a == nudged || $0.b == nudged }.map { $0.a == nudged ? $0.b : $0.a })
        let distant = pieces.indices.filter {
            hypot(pieces[$0].restX - pieces[nudged].restX, pieces[$0].restY - pieces[nudged].restY) > 45
        }
        XCTAssertFalse(neighbors.isEmpty)
        XCTAssertFalse(distant.isEmpty)
        heap.nudge(piece: nudged, dvx: 60)
        var peak = [Double](repeating: 0, count: pieces.count)
        for _ in 0..<90 {
            heap.capturePrevious()
            heap.step(dt: Tunables.simDt, drive: 0, enabled: true)
            for i in pieces.indices { peak[i] = max(peak[i], abs(heap.pose[i].dx)) }
        }
        let nearMean = neighbors.map { peak[$0] }.reduce(0, +) / Double(neighbors.count)
        let farMean = distant.map { peak[$0] }.reduce(0, +) / Double(distant.count)
        XCTAssertGreaterThan(nearMean, peak[nudged] * 0.1, "neighbors should visibly follow the shove")
        XCTAssertGreaterThan(nearMean, farMean * 5, "the shove fades with distance through the pile")
    }

    func testDisturbanceAffectsNearbyPiecesMoreThanDistantOnes() {
        var heap = HeapMotion(seed: 1)
        let pieces = heap.pieces
        // Land on the far left shoulder of the pile.
        let x = -40.0, y = -4.0
        let near = pieces.indices.min { hypot(pieces[$0].restX - x, pieces[$0].restY - y) < hypot(pieces[$1].restX - x, pieces[$1].restY - y) }!
        let far = pieces.indices.max { hypot(pieces[$0].restX - x, pieces[$0].restY - y) < hypot(pieces[$1].restX - x, pieces[$1].restY - y) }!
        heap.disturb(x: x, y: y, dvx: 20, dvy: 25, radial: 10, spin: 2)
        var peakNear = 0.0, peakFar = 0.0
        for _ in 0..<60 {
            heap.capturePrevious()
            heap.step(dt: Tunables.simDt, drive: 0, enabled: true)
            peakNear = max(peakNear, abs(heap.pose[near].dx) + abs(heap.pose[near].dy))
            peakFar = max(peakFar, abs(heap.pose[far].dx) + abs(heap.pose[far].dy))
        }
        XCTAssertGreaterThan(peakNear, 0.15)
        XCTAssertGreaterThan(peakNear, peakFar * 4)
    }

    func testLandingsAndLaunchesDisturbThePileInsideTheSim() {
        // Normal speech: pops and landings (plus agitation) wake and move the pile.
        let sim = PopcornSim(seed: 5)
        sim.allowSpawn = true
        var moved = false
        for _ in 0..<240 {
            sim.step(dt: Tunables.simDt, peak: 0.12)
            if sim.heapPoses.contains(where: { abs($0.dx) + abs($0.dy) > 0.05 }) { moved = true }
        }
        XCTAssertTrue(moved)

        // A resting kernel next to a landing gets knocked; one far away does not.
        let quiet = PopcornSim(seed: 9)
        quiet.allowSpawn = false
        quiet.insertRestingKernelForTesting(atOffsetX: -30)
        quiet.insertRestingKernelForTesting(atOffsetX: 30)
        for _ in 0..<60 { quiet.step(dt: Tunables.simDt, peak: 0) }
        let before = quiet.kernels.map(\.x)
        quiet.disturbPile(x: -30, y: Tunables.heapSurface(x: Double(Tunables.cardW) / 2 - 30) - Double(Tunables.cardH - Tunables.bagBottomPad - Tunables.bagH),
                          dvx: 25, dvy: 20, radial: 10, spin: 2)
        var maxShift = [0.0, 0.0]
        for _ in 0..<30 {
            quiet.step(dt: Tunables.simDt, peak: 0)
            for (i, k) in quiet.kernels.enumerated() { maxShift[i] = max(maxShift[i], abs(k.x - before[i])) }
        }
        XCTAssertGreaterThan(maxShift[0], 0.2)
        XCTAssertLessThan(maxShift[1], maxShift[0] * 0.1)
    }

    func testLongLoudAccentedSpeechStaysBounded() {
        // Sixty seconds of fixed steps (no display snapshots) is 40 accent cycles and dozens of
        // kernel lifetimes: long enough for any drift or energy build-up to show, short enough
        // to keep the suite fast in debug builds.
        let sim = PopcornSim(seed: 2026)
        sim.allowSpawn = true
        let pieces = sim.heapMotion.pieces
        var maxCount = 0, maxSettled = 0
        var mono: UInt64 = 0
        var speech = SyntheticSpeech(intensity: .energetic, seed: 3)
        let seconds = 60
        var worstTravel = 0.0, worstSpeed = 0.0, worstRestingVx = 0.0
        var highestResting = Double.infinity
        var allFinite = true
        for frame in 0..<(seconds * 120) {
            mono += 8
            var (peak, fresh) = speech.sample(atMonoMs: mono)
            // Every 1.5 s, slam a maximal accent on top of the syllables.
            if frame % 180 < 3 { peak = 1; fresh = true }
            sim.step(dt: Tunables.simDt, peak: peak, peakFresh: fresh)
            maxCount = max(maxCount, sim.kernels.count)
            if frame % 6 == 0 {
                maxSettled = max(maxSettled, sim.kernels.reduce(0) { $0 + ($1.settled ? 1 : 0) })
                // Track the worst use of each limit (1 = at the limit) and assert once at the end.
                let heap = sim.heapMotion
                for i in pieces.indices {
                    let p = heap.pose[i], v = heap.velocity[i]
                    worstTravel = max(worstTravel, abs(p.dx) / pieces[i].maxX, -p.dy / pieces[i].maxUp,
                                      p.dy / pieces[i].maxDown, abs(p.rot) / pieces[i].maxRot)
                    worstSpeed = max(worstSpeed, abs(v.dx) / HeapMotion.maxSpeed, abs(v.dy) / HeapMotion.maxSpeed,
                                     abs(v.rot) / HeapMotion.maxSpin)
                    allFinite = allFinite && p.dx.isFinite && p.dy.isFinite && p.rot.isFinite
                }
                for k in sim.kernels {
                    allFinite = allFinite && k.x.isFinite && k.y.isFinite && k.vx.isFinite && k.vy.isFinite
                    if k.settled {
                        worstRestingVx = max(worstRestingVx, abs(k.vx))
                        highestResting = min(highestResting, k.y)
                    }
                }
            }
        }
        XCTAssertTrue(allFinite)
        XCTAssertLessThanOrEqual(worstTravel, 1 + 1e-9)
        XCTAssertGreaterThan(worstTravel, 0.3, "loud accents should use a real share of the travel")
        XCTAssertLessThanOrEqual(worstSpeed, 1 + 1e-9)
        XCTAssertLessThanOrEqual(worstRestingVx, 40)
        XCTAssertGreaterThan(highestResting, Double(Tunables.cardH - Tunables.bagBottomPad - Tunables.bagH) - 70)
        XCTAssertLessThanOrEqual(maxCount, Tunables.maxKernels)
        XCTAssertLessThanOrEqual(maxSettled, Tunables.maxSettledKernels)
        XCTAssertGreaterThan(sim.emittedCount, seconds * 10)
    }

    func testSilenceSettlesToExactRestInBoundedTime() {
        let sim = PopcornSim(seed: 3)
        sim.allowSpawn = true
        let mono = runSpeech(sim, seconds: 3)
        var snap = sim.advance(toMonoMs: mono, peak: 0)
        var restMs: UInt64?
        var m = mono
        var previousPeak = Double.infinity
        var windowPeak = 0.0
        for frame in 0..<(6 * 120) {
            m += 8
            snap = sim.advance(toMonoMs: m, peak: 0, peakFresh: true)
            let size = poses(snap).map { abs($0.dx) + abs($0.dy) + abs($0.rot) * 10 }.max() ?? 0
            windowPeak = max(windowPeak, size)
            if frame % 60 == 59 {
                // Eases down: each half second of silence moves less than the one before it
                // (small slack for a last landing).
                XCTAssertLessThanOrEqual(windowPeak, previousPeak + 0.3)
                previousPeak = windowPeak
                windowPeak = 0
            }
            if restMs == nil, snap.heap.isEmpty, snap.kernels.isEmpty { restMs = m - mono }
        }
        let settledAfter = try? XCTUnwrap(restMs)
        XCTAssertNotNil(settledAfter)
        XCTAssertLessThan(settledAfter ?? .max, 4500, "pile and resting kernels should be still within 4.5 s")
        // …and stay exactly still.
        let still = sim.advance(toMonoMs: m + 8, peak: 0)
        XCTAssertTrue(still.heap.isEmpty)
        XCTAssertEqual(still.kick, 0, accuracy: 0.01)
    }

    func testReduceMotionPinsThePileAndStaysStable() {
        let sim = PopcornSim(seed: 8)
        sim.allowSpawn = true
        let mono = runSpeech(sim, seconds: 2)
        sim.reduceMotion = true
        var last: SimSnapshot?
        _ = runSpeech(sim, seconds: 3, startMs: mono) { snap, _ in
            XCTAssertTrue(snap.heap.isEmpty, "Reduce Motion draws the pile at rest")
            XCTAssertEqual(snap.kick, 0)
            XCTAssertTrue(snap.kernels.allSatisfy(\.settled))
            last = snap
        }
        XCTAssertTrue(sim.heapPoses.allSatisfy { $0 == .rest })
        // Once the old resting kernels expire, frames are identical apart from the clock.
        XCTAssertTrue(last?.kernels.isEmpty ?? false)
        XCTAssertGreaterThan(last?.heat ?? 0, 0.3, "recording feedback still follows the voice")
    }

    func testTenSecondStallProducesNoBurstAndNoHeapJump() {
        let sim = PopcornSim(seed: 21)
        sim.allowSpawn = true
        let mono = runSpeech(sim, seconds: 2)
        let emitted = sim.emittedCount
        let before = sim.heapMotion.pose
        let pieces = sim.heapMotion.pieces
        // Sleep: the display clock jumps ten seconds while the voice is loud.
        let after = sim.advance(toMonoMs: mono + 10_000, peak: 0.34, peakFresh: true)
        XCTAssertLessThanOrEqual(sim.emittedCount - emitted, 2, "no catch-up emission burst")
        for i in pieces.indices {
            let a = before[i], b = sim.heapMotion.pose[i]
            XCTAssertLessThan(abs(a.dx - b.dx) + abs(a.dy - b.dy), 1.0, "piece \(i) jumped")
        }
        XCTAssertLessThanOrEqual(after.kernels.count, Tunables.maxKernels)
        // Backwards clock jump is handled the same way.
        _ = sim.advance(toMonoMs: mono, peak: 0.34, peakFresh: true)
        XCTAssertLessThanOrEqual(sim.emittedCount - emitted, 4)
    }

    func testStrayKernelsFadeBeforeReachingTheStatusCapsule() {
        let sim = PopcornSim(seed: 29)
        sim.allowSpawn = true
        let cx = Double(Tunables.cardW) / 2
        let lip = Double(Tunables.cardH - Tunables.bagBottomPad - Tunables.bagH)
        // Top of the status capsule under the visible tub (see PopcornRenderer's metrics).
        let capsuleTop = Double(Tunables.cardH - Tunables.bagBottomPad) - 22 + 6
        var strays = 0
        _ = runSpeech(sim, seconds: 20) { snap, _ in
            for k in snap.kernels where !k.settled && abs(k.x - cx) > Double(Tunables.mouthHalf) && k.vy > 0 {
                if k.y > lip + 30 { strays += 1 }
                if k.y + k.hitRadius > capsuleTop {
                    XCTAssertEqual(k.alpha, 0, accuracy: 1e-9, "a stray kernel is still visible over the capsule")
                }
            }
        }
        XCTAssertGreaterThan(strays, 20, "energetic speech should throw some kernels past the rim")
    }

    func testHeapPosesInterpolateBetweenFixedSteps() {
        let sim = PopcornSim(seed: 17)
        var mono = runSpeech(sim, seconds: 1.5)
        var strictlyBetween = 0
        // A 3 ms display clock against the 8.3 ms fixed step: most frames fall between steps.
        for _ in 0..<200 {
            mono += 3
            let snap = sim.advance(toMonoMs: mono, peak: 0.3, peakFresh: false)
            guard !snap.heap.isEmpty else { continue }
            let prev = sim.heapMotion.previous, cur = sim.heapMotion.pose
            for i in snap.heap.indices {
                let lo = min(prev[i].dy, cur[i].dy), hi = max(prev[i].dy, cur[i].dy)
                XCTAssertGreaterThanOrEqual(snap.heap[i].dy, lo - 1e-9)
                XCTAssertLessThanOrEqual(snap.heap[i].dy, hi + 1e-9)
                if hi - lo > 1e-4, snap.heap[i].dy > lo + 1e-6, snap.heap[i].dy < hi - 1e-6 { strictlyBetween += 1 }
            }
        }
        XCTAssertGreaterThan(strictlyBetween, 100, "heap poses should blend, not snap, between steps")
    }

    func testRestingKernelsFollowTheDisplacedSurface() {
        let sim = PopcornSim(seed: 13)
        sim.allowSpawn = true
        let cx = Double(Tunables.cardW) / 2
        var worstGap = 0.0
        var samples = 0
        _ = runSpeech(sim, seconds: 6) { _, _ in
            for k in sim.kernels where k.settled && k.life > k.maxLife - 0.5 {
                let surface = Tunables.heapSurface(x: k.x) + sim.heapMotion.surfaceOffset(atX: k.x - cx)
                // Bottom of the kernel relative to the displaced surface: no hovering above it,
                // no sinking far into it.
                let gap = (k.y + k.hitRadius) - surface
                worstGap = max(worstGap, abs(gap - k.nestle))
                samples += 1
            }
        }
        XCTAssertGreaterThan(samples, 100)
        XCTAssertLessThan(worstGap, 6.5)
    }
}
