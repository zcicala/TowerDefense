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
