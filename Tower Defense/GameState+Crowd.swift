import Foundation
import simd

// MARK: - Enemy collision & intra-tile spread ("corridor" model)
//
// Enemies keep their existing (currentCell, progress) along-path coordinate — that's what
// every targeting/AOE/gravity-well/hopper system already relies on — and gain a signed
// `lateralOffset` perpendicular to the path tangent. World position becomes
// `splinePoint + lateralAxis * lateralOffset`, so the offset rotates with the path
// automatically at corners and cell transitions with no conversion needed.
//
// Enemies are solved strictly front-to-back by distance-to-end: whoever is further along
// never yields, and nothing is ever pushed forward. That makes the solver deadlock-free by
// construction and guarantees no enemy can be shoved into the base ahead of its own motion.
//
// See /Users/zac/.claude/plans/okay-i-want-to-hidden-cocoa.md for the full design.

/// Tuning constants for the corridor collision/avoidance solver. All world units are the
/// same units as `GameState.spacing` (hex center-to-center ≈ 0.9093).
enum CorridorTuning {
    /// RealityKit tap-collision sphere ÷ the physical body radius (`EnemyType.bodyRadiusScale`).
    /// Slightly larger than the drawn/physical body so enemies stay easy to tap.
    static let tapColliderSlack: Float = 1.25

    /// Skin distance kept between two bodies on top of the sum of their radii.
    static let separationGap: Float = 0.02
    /// Eased-deceleration horizon: at equilibrium a follower settles at roughly
    /// `followDistance * leaderSpeed / followerDesiredSpeed` behind its leader, rather than
    /// gluing to its surface (which pops apart/together every frame under float noise).
    static let followDistance: Float = 0.18
    /// Largest body radius in the game (the hive) — used to size the forward-probe range.
    static let maxCorridorRadius: Float = 0.25
    /// Extra slack added on top of the geometric minimum forward-probe range.
    static let probeRangePadding: Float = 0.05
    /// Hard cap on how many cells the forward probe walks looking for a blocker, however
    /// large a single frame's desired step is (bounds the cost of a stalled substep count).
    static let maxLookaheadCells = 16
    /// Target world-space advance per substep; frames wanting to move further are split into
    /// multiple substeps so a blocked/steering enemy gets more than one decision per frame.
    /// This is purely a quality knob — see `solveCrowd`'s doc comment for why substepping
    /// is not what prevents tunneling.
    static let substepDistance: Float = 0.15
    /// Ceiling on substeps per frame, bounding worst-case cost at very large `deltaTime`.
    static let maxSubsteps = 8
}

extension GameState {

    // MARK: - Corridor solver: status timers, ordering, and front-to-back collision

    /// Ticks the slow/freeze status timers for one enemy. Extracted from the old `moveEnemy`
    /// (which only ran for enemies taking the "normal walk" branch) and now called
    /// unconditionally for every active enemy, so a frozen hopper thaws and a Gravity-Well
    /// -pulled enemy's slow expires — both silently never happened before.
    func tickStatusTimers(_ enemy: Enemy, deltaTime: Float) {
        if enemy.slowed {
            enemy.slowTimer -= deltaTime
            if enemy.slowTimer <= 0 {
                enemy.slowed = false
                enemy.slowTimer = 0
                enemy.slowFactor = 0.5
            }
        }
        if enemy.frozen {
            enemy.frozenTimer -= deltaTime
            if enemy.frozenTimer <= 0 {
                enemy.frozen = false
                enemy.frozenTimer = 0
            }
        }
    }

    /// The speed `solveCrowd` should move this enemy at before any corridor blocking is
    /// applied — same formula the old `moveEnemy` used.
    func effectiveSpeed(of enemy: Enemy) -> Float {
        enemy.frozen ? 0 : (enemy.slowed ? enemy.speed * enemy.slowFactor : enemy.speed)
    }

    /// Flying enemies pass through ground traffic entirely: never blocked, never a blocker.
    private func isFlyingType(_ type: EnemyType) -> Bool {
        type == .wisp || type == .hive
    }

    /// Advances every surviving enemy in `movers` for this frame. Enemies pulled by the
    /// Gravity Well this frame are skipped (it already moved them); hoppers keep their own
    /// jump/teleport logic (`updateHopper`) untouched; enemies with `speed <= 0` (test props,
    /// or an ability that should hold them in place) are never moved by the solver at all.
    /// Everyone else ("walkers", including flying enemies, which still follow the path — they
    /// just aren't blocked by or blockers of anyone) is advanced front-to-back: whoever is
    /// further along the path (smaller `distanceToEnd`) is treated as immovable by everyone
    /// behind them, so nothing is ever pushed forward and the yield relation is a strict total
    /// order — deadlock-free by construction, with no iteration needed to converge.
    ///
    /// Substepping is for *quality*, not correctness: within a substep, `advanceWalkers`
    /// clamps each enemy's step to the actual free distance ahead of it, so no amount of
    /// splitting or not splitting `deltaTime` can let two enemies overlap. What substepping
    /// buys is a steering enemy getting more than one decision over a long or fast frame,
    /// and it incidentally fixes a latent bug where a very large `deltaTime` could advance
    /// `progress` several cells past 1.0 in one step and evaluate the position spline far
    /// outside its valid range.
    func solveCrowd(deltaTime: Float, movers: [Enemy], pulledByWell: Set<UUID>) {
        var walkers: [Enemy] = []
        walkers.reserveCapacity(movers.count)
        for enemy in movers {
            if pulledByWell.contains(enemy.id) { continue }
            if enemy.enemyType == .hopper || enemy.enemyType == .superHopper {
                updateHopper(enemy, deltaTime: deltaTime)
                continue
            }
            if enemy.speed <= 0 { continue }
            walkers.append(enemy)
        }
        guard !walkers.isEmpty else { return }

        // Front-to-back: smaller distanceToEnd (further along) always sorts first. Tiebreak
        // on `seq` — needed because e.g. the Gravity Well can pin several enemies at exactly
        // the same (cell, progress).
        let keyed = walkers.map { ($0, distanceToEnd($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.seq < $1.0.seq }
        walkers = keyed.map { $0.0 }

        let vmax = walkers.map { effectiveSpeed(of: $0) }.max() ?? 0
        let steps: Int
        if vmax > 0 {
            steps = min(CorridorTuning.maxSubsteps, max(1, Int((vmax * deltaTime / CorridorTuning.substepDistance).rounded(.up))))
        } else {
            steps = 1
        }
        let h = deltaTime / Float(steps)
        for _ in 0..<steps {
            advanceWalkers(walkers, dt: h)
        }
    }

    /// One substep: bucket walkers by their current cell, then advance each — in front-to-back
    /// order, so a follower always sees its leader's already-updated position this same
    /// substep (Gauss-Seidel), avoiding the one-substep-of-lag that would otherwise show up
    /// as a follower bumping into where its leader used to be.
    private func advanceWalkers(_ walkers: [Enemy], dt: Float) {
        var byCell: [HexCoord: [Enemy]] = [:]
        for enemy in walkers {
            guard let coord = enemy.currentCell?.coord else { continue }
            byCell[coord, default: []].append(enemy)
        }

        for enemy in walkers {
            guard let cell = enemy.currentCell else { continue }
            let speed = effectiveSpeed(of: enemy)
            let desiredStep = speed * dt
            guard desiredStep > 0 else { continue }

            let frame = pathFrame(cell: cell, progress: enemy.progress)
            let free: Float
            if isFlyingType(enemy.enemyType) {
                free = .greatestFiniteMagnitude
            } else {
                free = forwardFreeDistance(for: enemy, cell: cell, frame: frame, desiredStep: desiredStep, byCell: byCell)
            }

            // Eased slowdown rather than a hard `min(desired, free)`: at equilibrium this
            // settles into a stable standing gap instead of the follower's surface gluing to
            // the leader's and popping apart/together each frame under float noise. The
            // `min(..., free)` term is the actual (hard) safety against ever overlapping.
            let eased = free.isFinite ? desiredStep * min(1, free / CorridorTuning.followDistance) : desiredStep
            let step = max(0, min(desiredStep, eased, free))

            if step > 0 {
                let visualRadius = enemyVisualRadius(for: enemy.enemyType)
                enemy.rollDeltaAngle = step / visualRadius
                enemy.rollAxis = SIMD3(frame.tangent.y, 0, -frame.tangent.x)
            } else {
                enemy.rollDeltaAngle = 0
            }

            advance(enemy, from: cell, by: step)
        }
    }

    /// Distance `enemy` can advance along its own path tangent this substep before it would
    /// overlap a higher-priority (further-along) walker. `.greatestFiniteMagnitude` when
    /// nothing is in the way within the probe range.
    ///
    /// Works in the enemy's own tangent/lateral frame, so a blocker on a different cell (with
    /// a different tangent, e.g. just past a corner) needs no coordinate conversion — only
    /// its world position matters. "Ahead" is decided by path order (`distanceToEnd`), never
    /// by geometry alone: that's what makes the yield relation acyclic. The `along > 0` check
    /// below is only a geometric sanity filter — at a sharp corner, someone who is ahead in
    /// path order can briefly be geometrically behind — not a priority test.
    private func forwardFreeDistance(
        for enemy: Enemy,
        cell: HexCell,
        frame: (tangent: SIMD2<Float>, lateral: SIMD2<Float>, speedScale: Float),
        desiredStep: Float,
        byCell: [HexCoord: [Enemy]]
    ) -> Float {
        guard let ePos3 = enemyWorldPosition(enemy) else { return .greatestFiniteMagnitude }
        let ePos = SIMD2<Float>(ePos3.x, ePos3.z)
        let eRadius = enemyVisualRadius(for: enemy.enemyType)
        let myDistanceToEnd = distanceToEnd(enemy)

        // The broadphase walk must always cover at least one full hex chord (~0.9093):
        // a blocker exactly one cell ahead can already be at near-zero *physical* distance
        // (self near progress 1 in its cell, blocker near progress 0 in the next one), even
        // though the topological "accumulated chord" bookkeeping below says they're a whole
        // segment apart. Flooring on `desiredStep` alone broke this for small/slow steps —
        // a blocker one hop away is skipped by the `acc <= probeRange` check entirely, so a
        // fast-approaching enemy that happens to have a small step this frame (or substep)
        // never sees it coming and can end the frame already overlapping it.
        let probeRange = max(desiredStep, hexChordDistance) + 2 * CorridorTuning.maxCorridorRadius
            + CorridorTuning.followDistance + CorridorTuning.probeRangePadding

        var free: Float = .greatestFiniteMagnitude
        var walker: HexCell? = cell
        var acc: Float = 0
        var hops = 0
        while let visitCell = walker, acc <= probeRange, hops <= CorridorTuning.maxLookaheadCells {
            if let candidates = byCell[visitCell.coord] {
                for other in candidates {
                    guard other !== enemy, !isFlyingType(other.enemyType) else { continue }
                    guard distanceToEnd(other) < myDistanceToEnd else { continue }
                    guard let oPos3 = enemyWorldPosition(other) else { continue }
                    let oPos = SIMD2<Float>(oPos3.x, oPos3.z)
                    let d = oPos - ePos
                    let along = simd_dot(d, frame.tangent)
                    guard along > 0, along <= probeRange else { continue }
                    let side = simd_dot(d, frame.lateral)
                    let r = eRadius + enemyVisualRadius(for: other.enemyType) + CorridorTuning.separationGap
                    guard abs(side) < r else { continue }
                    let clearance = along - (r * r - side * side).squareRoot()
                    free = min(free, max(0, clearance))
                }
            }
            guard let next = visitCell.next else { break }
            acc += simd_distance(visitCell.coord.worldPosition(spacing: spacing), next.coord.worldPosition(spacing: spacing))
            walker = next
            hops += 1
        }
        return free
    }

    /// Advances `enemy`'s `(currentCell, progress)` by `step` world units along the path,
    /// crossing cell boundaries in a loop (rather than the single `if` the old `moveEnemy`
    /// used) so a large step can cross several cells in one call without leaving `progress`
    /// far outside `[0, 1]`. Writes `enemy`'s stored properties once at the end rather than
    /// per cell crossed, since `Enemy` is `@Observable` and every write has observation cost.
    private func advance(_ enemy: Enemy, from startCell: HexCell, by step: Float) {
        guard step > 0 else { return }
        var cell = startCell
        var progress = enemy.progress
        var remaining = step
        while remaining > 0 {
            guard let nextCell = cell.next else {
                if cell !== enemy.currentCell { enemy.currentCell = cell }
                enemy.progress = progress
                enemy.active = false
                enemy.reachedEnd = true
                return
            }
            let segmentLength = simd_distance(cell.coord.worldPosition(spacing: spacing), nextCell.coord.worldPosition(spacing: spacing))
            let remainingInSegment = max(0, (1 - progress) * segmentLength)
            if remaining < remainingInSegment {
                progress += remaining / segmentLength
                remaining = 0
            } else {
                remaining -= remainingInSegment
                cell = nextCell
                progress = 0
            }
        }
        if cell !== enemy.currentCell { enemy.currentCell = cell }
        enemy.progress = progress
    }
}

extension GameState {

    /// Center-to-center distance between any two adjacent hex cells (`spacing * sqrt(3)`,
    /// ≈0.9093 at the game's default `spacing`). Every neighbor pair is exactly this far
    /// apart regardless of direction, which several corridor-solver distance estimates rely on.
    var hexChordDistance: Float { spacing * Float(3.0).squareRoot() }

    // MARK: - Path frame (tangent/lateral axis at a point on the enemy spline)

    /// XZ control points `(p0, p1, p2, p3)` for the Catmull-Rom segment that runs from `cell`
    /// (p1) to `cell.next` (p2), with the same end-of-path reflection rule `enemyWorldPosition`
    /// already used (`p0 = 2·p1 − p2` when there's no previous cell, `p3 = 2·p2 − p1` when the
    /// next cell is terminal). Shared by position and tangent so the two can never drift apart.
    /// Returns `nil` when `cell` has no `next` — there is no segment to interpolate.
    func splineControlPoints(for cell: HexCell) -> (p0: SIMD2<Float>, p1: SIMD2<Float>, p2: SIMD2<Float>, p3: SIMD2<Float>)? {
        guard let nextCell = cell.next else { return nil }
        let p1 = cell.coord.worldPosition(spacing: spacing)
        let p2 = nextCell.coord.worldPosition(spacing: spacing)
        let p0 = cell.previous.map { $0.coord.worldPosition(spacing: spacing) } ?? (p1 * 2 - p2)
        let p3 = nextCell.next.map { $0.coord.worldPosition(spacing: spacing) } ?? (p2 * 2 - p1)
        return (p0, p1, p2, p3)
    }

    /// Analytic derivative of the Catmull-Rom segment at parameter `t`, unnormalized.
    /// Used instead of a numerical (sample t±ε) derivative: the position function is already
    /// an exact cubic in `t`, a central difference at `t=0`/`t=1` would need to straddle into
    /// an adjacent segment with a different (and, at a branch junction, lossy) control-point
    /// set, and this is ~6x cheaper.
    private func catmullRomTangent(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t
        return 0.5 * ((-p0 + p2) +
                       2 * (2 * p0 - 5 * p1 + 4 * p2 - p3) * t +
                       3 * (-p0 + 3 * p1 - 3 * p2 + p3) * t2)
    }

    /// Unit tangent (direction of travel) and unit left-normal (`lateralOffset`'s axis) in the
    /// XZ plane at `(cell, progress)`, plus the raw `|d/dt|` ("speedScale") needed to convert a
    /// world-space step into a change in `progress` when the spline isn't traveled at constant
    /// speed per unit of `t` (it measurably isn't — see Stage 2b).
    func pathFrame(cell: HexCell, progress t: Float) -> (tangent: SIMD2<Float>, lateral: SIMD2<Float>, speedScale: Float) {
        guard let cp = splineControlPoints(for: cell) else {
            // Terminal cell: no segment exists. Fall back to the incoming direction so the
            // frame is still well-defined for the last frame or two before `reachedEnd`.
            let p1 = cell.coord.worldPosition(spacing: spacing)
            var tangent = SIMD2<Float>(1, 0)
            if let prev = cell.previous {
                let d = p1 - prev.coord.worldPosition(spacing: spacing)
                if simd_length(d) > 1e-4 { tangent = simd_normalize(d) }
            }
            return (tangent, SIMD2(-tangent.y, tangent.x), hexChordDistance)
        }

        let dx = catmullRomTangent(cp.p0.x, cp.p1.x, cp.p2.x, cp.p3.x, t)
        let dz = catmullRomTangent(cp.p0.y, cp.p1.y, cp.p2.y, cp.p3.y, t)
        var speedScale = simd_length(SIMD2(dx, dz))
        var tangent: SIMD2<Float>
        if speedScale > 1e-4 {
            tangent = SIMD2(dx, dz) / speedScale
        } else {
            // Degenerate derivative — verified not to occur on any valid hex configuration
            // (minimum |d/dt| over all non-reversing hex triples is ≈0.454), kept as a guard
            // against a malformed grid rather than a case expected in practice.
            let fallback = cp.p2 - cp.p1
            tangent = simd_length(fallback) > 1e-4 ? simd_normalize(fallback) : SIMD2(1, 0)
            speedScale = max(speedScale, 1e-4)
        }
        let lateral = SIMD2<Float>(-tangent.y, tangent.x)
        return (tangent, lateral, speedScale)
    }

    // MARK: - Path-order ranking

    /// Returns the number of `.next` hops from `coord` to the end of its path, caching every
    /// cell visited along the way. The cache is invalidated automatically when the grid's
    /// topology changes (`hexGrid.pathVersion`), which happens on path generation, branch
    /// addition, and restart — see `HexGrid.pathVersion`'s doc comment for why that single
    /// counter is enough. Equivalent to (but far cheaper across repeated calls than) walking
    /// `stepsToEnd(of:)` from scratch every time, which `superHopper`'s jump-target search
    /// used to do once per candidate cell per jump.
    func cachedStepsToEnd(_ coord: HexCoord) -> Int {
        if cachedPathVersion != hexGrid.pathVersion {
            stepsToEndCache.removeAll(keepingCapacity: true)
            cachedPathVersion = hexGrid.pathVersion
        }
        if let cached = stepsToEndCache[coord] { return cached }

        // Walk forward from `coord`, collecting the uncached prefix until we either hit a
        // cell whose value is already cached, or run off the true end of the path.
        var chain: [HexCoord] = []
        var walker: HexCell? = hexGrid.cell(at: coord)
        while let cell = walker {
            if let cached = stepsToEndCache[cell.coord] {
                for (i, c) in chain.enumerated() {
                    stepsToEndCache[c] = cached + (chain.count - i)
                }
                return stepsToEndCache[coord] ?? cached
            }
            chain.append(cell.coord)
            walker = cell.next
        }
        // Ran off the end: the last element of `chain` is the true end cell (0 steps
        // remaining); fill the rest counting backward from there.
        let n = chain.count
        for (i, c) in chain.enumerated() {
            stepsToEndCache[c] = n - 1 - i
        }
        return stepsToEndCache[coord] ?? 0
    }

    /// Continuous distance-to-end used to order enemies front-to-back for the corridor solver:
    /// lower means further along (closer to the end). Continuous across a cell transition — as
    /// `progress → 1` on cell C this tends to `cachedStepsToEnd(C.next)`, matching the value at
    /// `progress = 0` there — so the sort order never jumps when an enemy crosses into a new
    /// cell. Branch topology is handled for free: `next` is single-valued and every path
    /// converges on one `.end`, so this is globally comparable across the whole tree, including
    /// enemies on different branches.
    func distanceToEnd(_ enemy: Enemy) -> Float {
        guard let cell = enemy.currentCell else { return .greatestFiniteMagnitude }
        return Float(cachedStepsToEnd(cell.coord)) - enemy.progress
    }
}
