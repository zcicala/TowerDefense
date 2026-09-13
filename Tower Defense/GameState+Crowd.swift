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
}

extension GameState {

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
            return (tangent, SIMD2(-tangent.y, tangent.x), spacing * Float(3.0).squareRoot())
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
