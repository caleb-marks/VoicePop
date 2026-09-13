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

    func testFiveMinutesOfLoudAccentedSpeechStaysBounded() {
        let sim = PopcornSim(seed: 2026)
        sim.allowSpawn = true
        let pieces = sim.heapMotion.pieces
        var maxCount = 0, maxSettled = 0
        var mono: UInt64 = 0
        var speech = SyntheticSpeech(intensity: .energetic, seed: 3)
        for frame in 0..<(300 * 120) {
            mono += 8
            var (peak, fresh) = speech.sample(atMonoMs: mono)
            // Every 1.5 s, slam a maximal accent on top of the syllables.
            if frame % 180 < 3 { peak = 1; fresh = true }
            _ = sim.advance(toMonoMs: mono, peak: peak, peakFresh: fresh)
            maxCount = max(maxCount, sim.kernels.count)
            maxSettled = max(maxSettled, sim.kernels.filter(\.settled).count)
            if frame % 12 == 0 {
                let heap = sim.heapMotion
                for i in pieces.indices {
                    let p = heap.pose[i], v = heap.velocity[i]
                    XCTAssertLessThanOrEqual(abs(p.dx), pieces[i].maxX + 1e-9)
                    XCTAssertLessThanOrEqual(-p.dy, pieces[i].maxUp + 1e-9)
                    XCTAssertLessThanOrEqual(p.dy, pieces[i].maxDown + 1e-9)
                    XCTAssertLessThanOrEqual(abs(p.rot), pieces[i].maxRot + 1e-9)
                    XCTAssertLessThanOrEqual(max(abs(v.dx), abs(v.dy)), HeapMotion.maxSpeed)
                    XCTAssertLessThanOrEqual(abs(v.rot), HeapMotion.maxSpin)
                    XCTAssertTrue(p.dx.isFinite && p.dy.isFinite && p.rot.isFinite)
                }
                for k in sim.kernels {
                    XCTAssertTrue(k.x.isFinite && k.y.isFinite && k.vx.isFinite && k.vy.isFinite)
                    if k.settled {
                        XCTAssertLessThanOrEqual(abs(k.vx), 40)
                        XCTAssertLessThanOrEqual(abs(k.vy), 400)
                        XCTAssertGreaterThan(k.y, Double(Tunables.cardH - Tunables.bagBottomPad - Tunables.bagH) - 70)
                    }
                }
            }
        }
        XCTAssertLessThanOrEqual(maxCount, Tunables.maxKernels)
        XCTAssertLessThanOrEqual(maxSettled, Tunables.maxSettledKernels)
        XCTAssertGreaterThan(sim.emittedCount, 300 * 10)
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
