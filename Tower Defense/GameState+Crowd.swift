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

    // MARK: Lateral steering (Stage 4)

    /// Half the physical width of the "gate" between two adjacent path tiles (`hexRadius / 2`)
    /// — the largest symmetric lateral offset that keeps an enemy's center within the union of
    /// path-tile lanes on a straight run. Verified by sampling the actual Catmull-Rom curve
    /// (see the plan doc): a tight double-turn pinches this down to ~0.164, so an enemy can
    /// briefly overrun its lane by a few hundredths of a unit there — invisible in practice,
    /// and the path generator biases hard against curling that tightly in the first place.
    static let corridorHalfWidth: Float = 0.25
    /// `maxLateralOffset = corridorHalfWidth − maxOffsetRadiusFactor * radius`. Half the
    /// radius, not the full radius: subtracting the full radius would make a basic vs. tank
    /// pass impossible and give the hive a negative budget.
    static let maxOffsetRadiusFactor: Float = 0.5
    /// Floor on `maxLateralOffset` so even the largest enemies keep some steering budget.
    static let minMaxOffset: Float = 0.06
    /// Lateral steering rate as a fraction of the enemy's own current forward speed.
    static let lateralSpeedFactor: Float = 0.8
    /// Absolute cap on lateral speed (world units/sec), independent of forward speed.
    static let lateralSpeedMax: Float = 1.2
    /// Recentring (drifting back to `lateralOffset = 0` once clear) uses this fraction of the
    /// normal lateral rate — deliberately lazier than avoidance, so an enemy doesn't snap back
    /// to center the instant a gap opens.
    static let recentreSpeedFactor: Float = 0.5
    /// Below this remaining distance to the desired lateral offset, snap directly to it
    /// instead of rate-limiting — kills residual per-frame vibration.
    static let lateralDeadband: Float = 0.005
    /// Minimum time a freshly chosen avoidance side is locked in before it can be
    /// re-evaluated, so per-frame noise in the cost estimate can't flip it back and forth.
    static let avoidHoldTime: Float = 0.6
    /// Once the hold expires, the other side must be better by at least this much (not
    /// merely better) to justify switching — a second, independent anti-oscillation guard.
    static let sideSwitchMargin: Float = 0.06
    /// Seconds an enemy must be continuously unblocked before its avoidance side resets to
    /// center — long enough that weaving past a multi-enemy queue doesn't trigger a recenter
    /// attempt in the brief gaps between blockers.
    static let recentreDelay: Float = 0.35

    // MARK: Separation relaxation (Stage 5)

    /// Fraction of overlap corrected per separation iteration/pair. Less than 1 so multiple
    /// overlapping pairs relax smoothly toward each other's constraints rather than each
    /// correction fighting the last one to convergence in a single jump.
    static let separationStrength: Float = 0.5
    /// Iterations of the separation pass per frame. 1 is enough visually; 2 resolves a
    /// same-tile clump (e.g. several Gravity-Well-pinned enemies) in one frame instead of
    /// visibly unstacking over several.
    static let separationIterations = 2
    /// Per-pair, per-iteration displacement cap, so a large overlap (many enemies pinned at
    /// literally the same point) can't produce an explosive one-frame pop.
    static let maxSeparationStep: Float = 0.15
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

        if !walkers.isEmpty {
            // Front-to-back: smaller distanceToEnd (further along) always sorts first.
            // Tiebreak on `seq` — needed because e.g. the Gravity Well can pin several
            // enemies at exactly the same (cell, progress).
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

        // Once per frame (not per substep), independent of whether any "walker" moved this
        // frame at all — a Gravity Well pinning enemies with no ordinary walkers present
        // must still get its clump fanned out. See relaxSeparation's doc comment.
        relaxSeparation(movers)
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

            if isFlyingType(enemy.enemyType) {
                // Flying enemies never engage the solver at all: never blocked, never a
                // blocker, lateralOffset stays exactly 0.
                advance(enemy, from: cell, by: desiredStep)
                enemy.rollDeltaAngle = desiredStep / enemyVisualRadius(for: enemy.enemyType)
                enemy.rollAxis = SIMD3(frame.tangent.y, 0, -frame.tangent.x)
                continue
            }

            let eRadius = enemyVisualRadius(for: enemy.enemyType)
            let myDistanceToEnd = distanceToEnd(enemy)
            let probeRange = max(desiredStep, hexChordDistance) + 2 * CorridorTuning.maxCorridorRadius
                + CorridorTuning.followDistance + CorridorTuning.probeRangePadding

            // Scan once at the current offset to decide whether — and which way — to steer.
            let ePos0 = enemyWorldPosition(enemy).map { SIMD2($0.x, $0.z) }
            let scan0 = ePos0.map {
                scanCandidates(for: enemy, cell: cell, frame: frame, ePos: $0, eRadius: eRadius,
                                probeRange: probeRange, myDistanceToEnd: myDistanceToEnd, byCell: byCell)
            } ?? CandidateScan()
            // Engage steering either when a higher-priority enemy is genuinely slowing my
            // forward progress, or when I'm currently overlapping *anyone's* lane laterally
            // (regardless of priority) — the latter is what lets a leader with an open road
            // ahead still nudge aside a little for a follower trying to squeeze past, without
            // ever slowing its own forward progress for them (see scanCandidates's doc comment).
            let blocked = scan0.free < desiredStep - 0.0001 || scan0.needLeft > 0 || scan0.needRight > 0

            updateLateralSteering(enemy, maxOffset: maxLateralOffset(for: enemy.enemyType), scan: scan0, blocked: blocked, dt: dt)

            // Re-scan with the (possibly just-updated) offset before actually advancing —
            // the offset change may have opened up or closed off the forward path.
            let ePos1 = enemyWorldPosition(enemy).map { SIMD2($0.x, $0.z) }
            let free = ePos1.map {
                scanCandidates(for: enemy, cell: cell, frame: frame, ePos: $0, eRadius: eRadius,
                                probeRange: probeRange, myDistanceToEnd: myDistanceToEnd, byCell: byCell).free
            } ?? .greatestFiniteMagnitude

            // Eased slowdown rather than a hard `min(desired, free)`: at equilibrium this
            // settles into a stable standing gap instead of the follower's surface gluing to
            // the leader's and popping apart/together each frame under float noise. The
            // `min(..., free)` term is the actual (hard) safety against ever overlapping.
            let eased = free.isFinite ? desiredStep * min(1, free / CorridorTuning.followDistance) : desiredStep
            let step = max(0, min(desiredStep, eased, free))

            if step > 0 {
                enemy.rollDeltaAngle = step / eRadius
                enemy.rollAxis = SIMD3(frame.tangent.y, 0, -frame.tangent.x)
            } else {
                enemy.rollDeltaAngle = 0
            }

            advance(enemy, from: cell, by: step)
        }
    }

    /// The largest `|lateralOffset|` this enemy type is allowed to steer to. Half the radius,
    /// not the full radius, is subtracted from the corridor half-width — see
    /// `CorridorTuning.maxOffsetRadiusFactor`'s doc comment for why.
    func maxLateralOffset(for type: EnemyType) -> Float {
        max(CorridorTuning.minMaxOffset,
            CorridorTuning.corridorHalfWidth - CorridorTuning.maxOffsetRadiusFactor * enemyVisualRadius(for: type))
    }

    /// Result of `scanCandidates`.
    private struct CandidateScan {
        /// How far `enemy` can advance along its own tangent before touching a higher-priority
        /// enemy ahead of it. `.greatestFiniteMagnitude` when nothing is in the way.
        var free: Float = .greatestFiniteMagnitude
        /// Largest lateral shift, in either direction, that would clear every enemy currently
        /// overlapping `enemy`'s lane — see `scanCandidates`'s doc comment for why this side
        /// is *not* priority-filtered the way `free` is.
        var needLeft: Float = 0
        var needRight: Float = 0
        /// `seq` of whichever candidate is driving each `need*` value — used only to break a
        /// symmetric tie deterministically (see `updateLateralSteering`).
        var tightLeftSeq: Int?
        var tightRightSeq: Int?
    }

    /// Scans every enemy within `probeRange` of `enemy` — ahead, behind, or beside, along its
    /// own path — and returns a `CandidateScan`.
    ///
    /// `free` (the forward-yield clamp Stage 3 introduced) only ever comes from a
    /// higher-priority enemy actually ahead (`along > 0`): that asymmetry is what guarantees a
    /// lower-priority follower can never slow down or push a leader.
    ///
    /// `needLeft`/`needRight` (lateral clearance) are deliberately symmetric — computed
    /// against *any* nearby enemy regardless of priority. Two bodies can only fit side by side
    /// in the corridor if both of them contribute some of the required separation (see the
    /// plan doc's pass-matrix math: `maxLateralOffset` alone, for either type, is smaller than
    /// many pairs' required clearance — it only works out when both shift toward opposite
    /// extremes). A leader with an open road ahead has no *forward* reason to move, but this
    /// lets it still nudge sideways for a follower trying to get past, without that follower
    /// ever being able to slow the leader's own advance.
    ///
    /// Works entirely in `enemy`'s own tangent/lateral frame, so a blocker on a different cell
    /// (with a different tangent, e.g. just past a corner) needs no coordinate conversion —
    /// only its world position matters. Walks both forward (`.next`) and backward (`.previous`)
    /// from `cell`; `.previous` is lossy at a branch junction (see `HexCell.previous`'s doc
    /// comment), so in that rare topology a leader simply won't know to make room for a
    /// follower approaching across the merge — safe, just a missed courtesy, since the
    /// follower's own hard `free` clamp still guarantees no overlap regardless.
    private func scanCandidates(
        for enemy: Enemy,
        cell: HexCell,
        frame: (tangent: SIMD2<Float>, lateral: SIMD2<Float>, speedScale: Float),
        ePos: SIMD2<Float>,
        eRadius: Float,
        probeRange: Float,
        myDistanceToEnd: Float,
        byCell: [HexCoord: [Enemy]]
    ) -> CandidateScan {
        var scan = CandidateScan()

        func consider(_ other: Enemy) {
            guard other !== enemy, !isFlyingType(other.enemyType) else { return }
            guard let oPos3 = enemyWorldPosition(other) else { return }
            let oPos = SIMD2<Float>(oPos3.x, oPos3.z)
            let d = oPos - ePos
            let along = simd_dot(d, frame.tangent)
            guard abs(along) <= probeRange else { return }
            let r = eRadius + enemyVisualRadius(for: other.enemyType) + CorridorTuning.separationGap
            let side = simd_dot(d, frame.lateral)
            guard abs(side) < r else { return }

            if along > 0 && distanceToEnd(other) < myDistanceToEnd {
                let clearance = along - (r * r - side * side).squareRoot()
                scan.free = min(scan.free, max(0, clearance))
            }
            let needL = side + r
            if needL > scan.needLeft { scan.needLeft = needL; scan.tightLeftSeq = other.seq }
            let needR = r - side
            if needR > scan.needRight { scan.needRight = needR; scan.tightRightSeq = other.seq }
        }

        var walker: HexCell? = cell
        var acc: Float = 0
        var hops = 0
        while let visitCell = walker, acc <= probeRange, hops <= CorridorTuning.maxLookaheadCells {
            byCell[visitCell.coord]?.forEach(consider)
            guard let next = visitCell.next else { break }
            acc += simd_distance(visitCell.coord.worldPosition(spacing: spacing), next.coord.worldPosition(spacing: spacing))
            walker = next
            hops += 1
        }
        walker = cell.previous
        acc = 0
        hops = 0
        while let visitCell = walker, acc <= probeRange, hops <= CorridorTuning.maxLookaheadCells {
            byCell[visitCell.coord]?.forEach(consider)
            guard let prev = visitCell.previous else { break }
            acc += simd_distance(visitCell.coord.worldPosition(spacing: spacing), prev.coord.worldPosition(spacing: spacing))
            walker = prev
            hops += 1
        }

        scan.needLeft = max(0, scan.needLeft)
        scan.needRight = max(0, scan.needRight)
        return scan
    }

    /// Updates `enemy.avoidSide`/`avoidHold`/`clearTimer`/`lateralOffset` for one substep.
    /// Avoidance and recentring are branches of one if/else feeding a single rate-limited
    /// integrator — never two summed forces — which is structurally why they can't fight each
    /// other into a vibrating equilibrium. See the plan doc's anti-jitter section for the
    /// three separate mechanisms (hold time, switch margin, recenter delay) guarding against
    /// side-to-side oscillation specifically.
    private func updateLateralSteering(_ enemy: Enemy, maxOffset: Float, scan: CandidateScan, blocked: Bool, dt: Float) {
        enemy.avoidHold = max(0, enemy.avoidHold - dt)

        if !blocked {
            enemy.clearTimer += dt
            if enemy.clearTimer >= CorridorTuning.recentreDelay {
                enemy.avoidSide = 0
            }
        } else {
            enemy.clearTimer = 0
            if enemy.avoidHold <= 0 {
                // Cost is the *residual* need left over after moving as far as our own
                // maxOffset allows toward that side — not "is the full requirement feasible
                // unilaterally." Many passable pairs (see the plan doc's pass-matrix math)
                // only clear when BOTH enemies contribute part of the separation, so refusing
                // to move at all unless our own budget alone fully resolves it would deadlock
                // forever: neither party ever moves first. Moving partway is always taken —
                // the other party's own solver pass supplies the rest over the following
                // frames, and the hard forward `free` clamp stays the actual safety net
                // regardless of how far either of us gets.
                let targetPlus = min(maxOffset, enemy.lateralOffset + scan.needLeft)
                let targetMinus = max(-maxOffset, enemy.lateralOffset - scan.needRight)
                let residualPlus = max(0, scan.needLeft - (targetPlus - enemy.lateralOffset))
                let residualMinus = max(0, scan.needRight - (enemy.lateralOffset - targetMinus))

                if enemy.avoidSide == 1 && residualPlus <= residualMinus + CorridorTuning.sideSwitchMargin {
                    // keep left
                } else if enemy.avoidSide == -1 && residualMinus <= residualPlus + CorridorTuning.sideSwitchMargin {
                    // keep right
                } else if residualPlus == residualMinus {
                    // A perfect tie (most commonly: two enemies approaching each other
                    // head-on/dead-astern with zero lateral offset yet) must be broken
                    // anti-symmetrically, not by a fixed preference — otherwise both parties
                    // in a mutual negotiation pick the *same* side and stay locked together
                    // forever, since a shared shift in one direction changes nothing between
                    // them. Comparing against the specific candidate driving the tie (falling
                    // back to our own seq, which only matters when there's no real
                    // candidate) guarantees the other party's symmetric comparison resolves
                    // to the opposite side.
                    let otherSeq = scan.tightLeftSeq ?? scan.tightRightSeq ?? enemy.seq
                    enemy.avoidSide = enemy.seq < otherSeq ? 1 : -1
                } else {
                    enemy.avoidSide = residualPlus < residualMinus ? 1 : -1
                }
                enemy.avoidHold = CorridorTuning.avoidHoldTime
            }
        }

        let desiredLateral: Float
        switch enemy.avoidSide {
        case 1:  desiredLateral = min(maxOffset, enemy.lateralOffset + scan.needLeft)
        case -1: desiredLateral = max(-maxOffset, enemy.lateralOffset - scan.needRight)
        default: desiredLateral = 0
        }

        let baseRate = enemy.frozen ? 0 : min(CorridorTuning.lateralSpeedFactor * effectiveSpeed(of: enemy), CorridorTuning.lateralSpeedMax)
        let rate = enemy.avoidSide != 0 ? baseRate : baseRate * CorridorTuning.recentreSpeedFactor
        let delta = desiredLateral - enemy.lateralOffset
        if abs(delta) <= CorridorTuning.lateralDeadband {
            enemy.lateralOffset = desiredLateral
        } else {
            enemy.lateralOffset += max(-rate * dt, min(rate * dt, delta))
        }
        enemy.lateralOffset = max(-maxOffset, min(maxOffset, enemy.lateralOffset))
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

    // MARK: - Separation relaxation (overlaps the corridor solver above didn't create)

    private struct SeparationAgent {
        let enemy: Enemy
        let radius: Float
        let maxOffset: Float
        var pos: SIMD2<Float>
        var tangent: SIMD2<Float>
        var lateral: SIMD2<Float>
        var key: Float
    }

    private func separationAgent(for enemy: Enemy, radius: Float, maxOffset: Float) -> SeparationAgent? {
        guard let cell = enemy.currentCell, let pos3 = enemyWorldPosition(enemy) else { return nil }
        let frame = pathFrame(cell: cell, progress: enemy.progress)
        return SeparationAgent(enemy: enemy, radius: radius, maxOffset: maxOffset,
                                pos: SIMD2(pos3.x, pos3.z), tangent: frame.tangent, lateral: frame.lateral,
                                key: distanceToEnd(enemy))
    }

    /// Nudges apart any overlapping ground enemies that the corridor solver above didn't
    /// create or resolve — a Gravity Well pinning several enemies at the exact same point, two
    /// enemies spawned on top of each other, a hive drop landing near others, or a hopper
    /// landing on an already-occupied cell. Runs once per frame (not per substep, unlike
    /// `advanceWalkers`), over every active ground enemy including well-pulled enemies and
    /// grounded hoppers — neither of which `solveCrowd`'s substep loop above touches at all.
    ///
    /// Unlike the corridor solver, this uses purely geometric neighbors (a cell's 6 hex
    /// neighbors) rather than walking `.next`/`.previous` — deliberately, since it needs to
    /// work even where path topology is lossy (a branch junction's `.previous`) or doesn't
    /// exist in the useful direction at all (two enemies pinned on the same Gravity Well tile
    /// have nothing to do with `.next` chains).
    ///
    /// Two invariants make this safe to run unconditionally every frame: only the
    /// lower-priority ("rear") enemy of any overlapping pair ever moves, and if lateral
    /// correction alone can't fully separate them, the remainder is applied as *backward*
    /// progress only (`retreat`, below) — the one place outside the Gravity Well itself where
    /// `progress` can decrease. Together these guarantee separation can never advance anyone,
    /// let alone shove them toward the base.
    func relaxSeparation(_ movers: [Enemy]) {
        var agents: [SeparationAgent] = []
        agents.reserveCapacity(movers.count)
        for enemy in movers {
            guard enemy.active, !isFlyingType(enemy.enemyType), !enemy.isJumping, !enemy.isDroppingFromHive, enemy.speed > 0 else { continue }
            if let agent = separationAgent(for: enemy, radius: enemyVisualRadius(for: enemy.enemyType), maxOffset: maxLateralOffset(for: enemy.enemyType)) {
                agents.append(agent)
            }
        }
        guard agents.count > 1 else { return }

        for _ in 0..<CorridorTuning.separationIterations {
            var byCell: [HexCoord: [Int]] = [:]
            for (i, agent) in agents.enumerated() {
                guard let coord = agent.enemy.currentCell?.coord else { continue }
                byCell[coord, default: []].append(i)
            }

            for i in agents.indices {
                guard let coord = agents[i].enemy.currentCell?.coord else { continue }
                var neighborIndices = byCell[coord] ?? []
                for n in 0..<6 {
                    if let ids = byCell[coord.neighbor(n)] { neighborIndices.append(contentsOf: ids) }
                }

                for j in neighborIndices where j != i {
                    let rearIdx = agents[i].key >= agents[j].key ? i : j
                    let frontIdx = rearIdx == i ? j : i

                    let d = agents[rearIdx].pos - agents[frontIdx].pos
                    let r = agents[frontIdx].radius + agents[rearIdx].radius + CorridorTuning.separationGap
                    var dist = simd_length(d)
                    let dir: SIMD2<Float>
                    if dist < 1e-4 {
                        // Perfectly stacked (e.g. two enemies spawned at the same instant):
                        // split deterministically by identity, never by RNG.
                        dir = agents[rearIdx].lateral * ((agents[rearIdx].enemy.seq % 2 == 0) ? 1 : -1)
                        dist = 0
                    } else {
                        dir = d / dist
                    }
                    guard dist < r else { continue }

                    let pen = min(r - dist, CorridorTuning.maxSeparationStep) * CorridorTuning.separationStrength
                    let dLat = simd_dot(dir, agents[rearIdx].lateral) * pen
                    let dTan = simd_dot(dir, agents[rearIdx].tangent) * pen

                    let rearEnemy = agents[rearIdx].enemy
                    let maxOffset = agents[rearIdx].maxOffset
                    rearEnemy.lateralOffset = max(-maxOffset, min(maxOffset, rearEnemy.lateralOffset + dLat))
                    if dTan < 0 {
                        retreat(rearEnemy, by: -dTan)
                    }
                    if let refreshed = separationAgent(for: rearEnemy, radius: agents[rearIdx].radius, maxOffset: maxOffset) {
                        agents[rearIdx] = refreshed
                    }
                }
            }
        }
    }

    /// Moves `enemy` backward along its path by `distance` world units (always positive) —
    /// the mirror image of `advance`, used solely by `relaxSeparation` to make room when
    /// lateral correction alone isn't enough. Stops at a `.start` cell (`previous == nil`)
    /// rather than going negative — an unresolvable spawn-point overlap is simply tolerated
    /// for a frame rather than corrupting `progress`.
    private func retreat(_ enemy: Enemy, by distance: Float) {
        guard distance > 0, var cell = enemy.currentCell else { return }
        var progress = enemy.progress
        var remaining = distance
        while remaining > 0 {
            let segmentLength: Float
            if let next = cell.next {
                segmentLength = simd_distance(cell.coord.worldPosition(spacing: spacing), next.coord.worldPosition(spacing: spacing))
            } else {
                segmentLength = hexChordDistance // `cell` is the true end; no real next segment
            }
            let distanceIntoSegment = progress * segmentLength
            if remaining < distanceIntoSegment {
                progress -= remaining / segmentLength
                remaining = 0
            } else {
                remaining -= distanceIntoSegment
                guard let prev = cell.previous else {
                    progress = 0
                    remaining = 0
                    break
                }
                cell = prev
                progress = 1
            }
        }
        if cell !== enemy.currentCell { enemy.currentCell = cell }
        enemy.progress = progress
    }
}
